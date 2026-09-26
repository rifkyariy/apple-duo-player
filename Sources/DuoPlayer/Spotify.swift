import os
import Foundation
import AppKit
import Network
import CryptoKit

// Spotify Web API client. Auth is Authorization Code + PKCE: no client secret, no server.
// The refresh token lives in the Keychain; the access token only in memory.
private let log = Logger(subsystem: "DuoPlayer", category: "spotify")

@MainActor final class Spotify {
    // Loopback redirect: Spotify always accepts it for desktop apps. Add it to the app's Redirect URIs.
    static let port: NWEndpoint.Port = 8898
    static let redirect = "http://127.0.0.1:8898/callback"
    static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing user-library-read user-library-modify playlist-read-private user-top-read"

    // Each builder uses their own Spotify app, so rate limits aren't shared: build.sh writes the ID into
    // Info.plist (SpotifyClientID). SPOTIFY_CLIENT_ID at launch overrides it. Client IDs are public (PKCE needs no secret).
    let clientID = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"]
        ?? Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? ""

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
        guard !clientID.isEmpty else {
            throw Failure(status: 0, message: "No Spotify client ID. Build with ./build.sh (see README).")
        }
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

    // Browser page shown after Spotify redirects back: dark card, Spotify logo, then tries to close itself.
    static let callbackPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Duo Player · Connected</title>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
    :root{color-scheme:dark}
    body{margin:0;min-height:100vh;display:grid;place-items:center;background:radial-gradient(circle at 30% 20%,#1f3a2a,#0b0b0c 60%);
    font:15px -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;color:#fff}
    .card{padding:40px 44px;border-radius:28px;background:rgba(255,255,255,.06);border:.5px solid rgba(255,255,255,.18);
    backdrop-filter:blur(30px);text-align:center;max-width:320px;animation:in .6s cubic-bezier(.2,.8,.2,1)}
    svg{width:64px;height:64px;filter:drop-shadow(0 0 24px rgba(29,185,84,.55))}
    h1{font-size:22px;margin:18px 0 6px}
    p{margin:0;color:rgba(255,255,255,.62);line-height:1.45}
    .ok{display:inline-flex;gap:6px;align-items:center;margin-top:22px;padding:8px 14px;border-radius:99px;
    background:#1DB954;color:#000;font-weight:700;font-size:13px}
    @keyframes in{from{opacity:0;transform:translateY(8px) scale(.98);filter:blur(6px)}}
    </style></head><body><div class="card">
    <svg viewBox="0 0 24 24"><path fill="#1DB954" d="\(SpotifyLogo.d)"/></svg>
    <h1>You're connected</h1>
    <p>Duo Player is now linked to Spotify.<br>You can close this tab and head back to the player.</p>
    <div class="ok">✓ Signed in</div>
    </div><script>setTimeout(()=>window.close(),2500)</script></body></html>
    """

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
                    let html = Self.callbackPage
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
        if http.statusCode >= 400 {   // path + status only (never the token); read with: log show --predicate 'subsystem == "DuoPlayer"'
            // Plus any X-RateLimit-* headers, when Spotify sends them (most endpoints don't).
            let limits = http.allHeaderFields.compactMap { k, v in (k as? String)?.lowercased().hasPrefix("x-ratelimit") == true ? "\(k)=\(v)" : nil }.joined(separator: " ")
            log.error("\(method, privacy: .public) \(path, privacy: .public) -> \(http.statusCode) retry-after=\(http.value(forHTTPHeaderField: "Retry-After") ?? "-", privacy: .public) \(limits, privacy: .public)")
        }
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

    /// cacheFor > 0 answers repeats from memory for that many seconds: /me/* endpoints get 429s after only
    /// a handful of calls, so anything that rarely changes shouldn't be re-asked.
    func get<T: Decodable>(_ path: String, query: [String: String] = [:], cacheFor: TimeInterval = 0) async throws -> T? {
        let key = path + "?" + query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        if cacheFor > 0, let hit = cache[key], hit.until > Date() { return try JSONDecoder().decode(T.self, from: hit.data) }
        guard let data = try await call("GET", path, query: query) else { return nil }
        if cacheFor > 0 { cache[key] = (Date() + cacheFor, data) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Drops cached answers for a path (after a change we made, e.g. liking a song).
    func forget(_ path: String) { cache = cache.filter { !$0.key.hasPrefix(path + "?") } }
    private var cache: [String: (until: Date, data: Data)] = [:]   // ponytail: in-memory, unbounded; entries are small and few
}

// MARK: - Response shapes (only the fields we use)

struct SPImage: Codable { let url: URL }
struct SPNamed: Decodable { let name: String }
struct SPAlbum: Decodable { let name: String; let uri: String; let images: [SPImage] }
struct SPTrack: Decodable { let id: String; let name: String; let duration_ms: Int; let artists: [SPNamed]; let album: SPAlbum }
struct SPDevice: Decodable, Identifiable {
    let id: String?; let name: String; let is_active: Bool
}
struct SPPlayback: Decodable {
    struct Context: Decodable { let uri: String; let type: String }
    let is_playing: Bool; let progress_ms: Int?; let item: SPTrack?; let device: SPDevice?; let context: Context?
}
struct SPSimpleTrack: Decodable { let id: String; let name: String; let duration_ms: Int; let artists: [SPNamed] }
struct SPAlbumFull: Decodable { struct T: Decodable { let items: [SPSimpleTrack] }; let name: String; let images: [SPImage]; let tracks: T }
struct SPPlaylistFull: Decodable {
    struct T: Decodable { struct I: Decodable { let track: SPTrack? }; let items: [I] }
    let name: String; let tracks: T
}
struct SPSavedAlbums: Decodable { struct Item: Decodable { let album: SPAlbum }; let items: [Item] }
struct SPPlaylists: Decodable { struct Item: Decodable { let name: String; let uri: String; let images: [SPImage]? }; let items: [Item?] }
struct SPMe: Codable { struct F: Codable { let total: Int }; let display_name: String?; let images: [SPImage]?; let followers: F? }
struct SPTopArtists: Decodable { struct A: Decodable { let name: String; let uri: String; let images: [SPImage]? }; let items: [A] }
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
