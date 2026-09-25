import Foundation
import AppKit
import Network
import CryptoKit

// Spotify Web API client. Auth is Authorization Code + PKCE: no client secret, no server.
// The refresh token lives in the Keychain; the access token only in memory.
@MainActor final class Spotify {
    // Loopback redirect: Spotify always accepts it for desktop apps. Add it to the app's Redirect URIs.
    static let port: NWEndpoint.Port = 8898
    static let redirect = "http://127.0.0.1:8898/callback"
    static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing user-library-read user-library-modify"

    // Client IDs are public (PKCE needs no secret). SPOTIFY_CLIENT_ID overrides it for a different app.
    let clientID = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"] ?? "65d4ea2285b047059f3b7bb393e3d212"

    private var accessToken: String?
    private var expiry = Date.distantPast

    var signedIn: Bool { Keychain.get("refresh") != nil }

    struct Failure: LocalizedError {
        let status: Int, message: String
        var retryAfter: Double = 0
        var errorDescription: String? { message }
    }

    // MARK: Auth

    func login() async throws {
        let verifier = Data((0..<64).map { _ in UInt8.random(in: 0...255) }).base64URL
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
        ]
        let state = UUID().uuidString
        c.queryItems?.append(.init(name: "state", value: state))
        NSWorkspace.shared.open(c.url!)
        let query = try await Self.awaitCallback()
        guard query["state"] == state, let code = query["code"] else {
            throw Failure(status: 0, message: query["error"] == "access_denied" ? "Spotify sign-in was cancelled." : "Spotify sign-in failed.")
        }
        try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                         "client_id": clientID, "code_verifier": verifier])
    }

    func logout() {
        Keychain.delete("refresh")
        accessToken = nil
    }

    /// Waits for the browser to hit http://127.0.0.1:8898/callback?... and returns its query items.
    /// ponytail: one-shot HTTP read, no timeout; the user can click Sign in again to restart.
    private static func awaitCallback() async throws -> [String: String] {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: port)
        return try await withCheckedThrowingContinuation { cont in
            let once = Once()
            listener.newConnectionHandler = { conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    guard target.hasPrefix("/callback"), !once.done else { conn.cancel(); return }
                    once.done = true
                    let html = "<html><body style='font:16px -apple-system;text-align:center;padding:60px'>Signed in. You can close this tab.</body></html>"
                    let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    listener.cancel()
                    let items = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
                    cont.resume(returning: Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a }))
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let e) = state, !once.done { once.done = true; cont.resume(throwing: e) }
            }
            listener.start(queue: .main)
        }
    }

    private func token(_ form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            if form["grant_type"] == "refresh_token" { logout() }   // revoked: sign in again
            throw Failure(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, message: "Spotify sign-in failed.")
        }
        struct Token: Decodable { let access_token: String; let expires_in: Double; let refresh_token: String? }
        let t = try JSONDecoder().decode(Token.self, from: data)
        accessToken = t.access_token
        expiry = Date().addingTimeInterval(t.expires_in - 60)
        if let r = t.refresh_token { Keychain.set("refresh", r) }
    }

    private func validToken() async throws -> String {
        if let a = accessToken, Date() < expiry { return a }
        guard let r = Keychain.get("refresh") else { throw Failure(status: 401, message: "Not signed in.") }
        try await token(["grant_type": "refresh_token", "refresh_token": r, "client_id": clientID])
        return accessToken!
    }

    // MARK: API

    /// Returns nil for 204 No Content (e.g. /me/player with no active device).
    @discardableResult
    func call(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil,
              retried: Bool = false) async throws -> Data? {
        var c = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if !query.isEmpty { c.queryItems = query.map { .init(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        switch http.statusCode {
        case 204: return nil
        case 200..<300: return data
        case 401 where !retried:
            accessToken = nil
            return try await call(method, path, query: query, body: body, retried: true)
        case 429:
            var f = Failure(status: 429, message: "Spotify is rate limiting; slowing down.")
            f.retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            throw f
        default:
            struct E: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }
            let msg = (try? JSONDecoder().decode(E.self, from: data))?.error.message ?? "Spotify error \(http.statusCode)."
            throw Failure(status: http.statusCode, message: msg)
        }
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T? {
        guard let data = try await call("GET", path, query: query) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Response shapes (only the fields we use)

struct SPImage: Decodable { let url: URL }
struct SPNamed: Decodable { let name: String }
struct SPAlbum: Decodable { let name: String; let uri: String; let images: [SPImage] }
struct SPTrack: Decodable { let id: String; let name: String; let duration_ms: Int; let artists: [SPNamed]; let album: SPAlbum }
struct SPDevice: Decodable, Identifiable {
    let id: String?; let name: String; let is_active: Bool
}
struct SPPlayback: Decodable { let is_playing: Bool; let progress_ms: Int?; let item: SPTrack?; let device: SPDevice? }
struct SPSavedAlbums: Decodable { struct Item: Decodable { let album: SPAlbum }; let items: [Item] }
struct SPDevices: Decodable { let devices: [SPDevice] }
struct SPQueue: Decodable { let queue: [SPTrack] }

// MARK: - Helpers

// ponytail: @unchecked is fine; every NWListener/NWConnection handler here runs on the main queue.
final class Once: @unchecked Sendable { var done = false }

enum Keychain {
    private static func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "DuoPlayer", kSecAttrAccount: key]
    }
    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ key: String, _ value: String) {
        delete(key)
        var q = query(key)
        q[kSecValueData] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
    static func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? self
    }
}
