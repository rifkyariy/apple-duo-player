import Foundation
import CryptoKit

typealias LyricLine = (time: Double, text: String)

// Synced lyrics from LRCLIB (lrclib.net): free, no key. Spotify's API has no lyrics.
enum Lyrics {
    // Lyrics you supplied yourself (pasted or imported .lrc), one file per Spotify track ID. Checked before LRCLIB.
    static let folder = URL.applicationSupportDirectory.appending(path: "DuoPlayer/Lyrics")
    static func localURL(_ id: String) -> URL { folder.appending(path: id + ".lrc") }

    /// Saves user-supplied LRC for a track; returns the parsed lines, or [] if it has no timed lines.
    static func saveLocal(_ lrc: String, id: String) -> [LyricLine] {
        let lines = parse(lrc)
        guard !lines.isEmpty else { return [] }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? lrc.write(to: localURL(id), atomically: true, encoding: .utf8)
        return lines
    }

    static func fetch(id: String, title: String, artist: String, album: String, duration: Double) async -> [LyricLine] {
        if let mine = try? String(contentsOf: localURL(id), encoding: .utf8) { return parse(mine) }
        struct R: Decodable { let syncedLyrics: String?; let duration: Double?; let trackName: String? }
        func get<T: Decodable>(_ path: String, _ q: [String: String]) async -> T? {
            var c = URLComponents(string: "https://lrclib.net/api/" + path)!
            c.queryItems = q.map { .init(name: $0.key, value: $0.value) }
            var req = URLRequest(url: c.url!)
            req.setValue("DuoPlayer/0.1", forHTTPHeaderField: "User-Agent")   // LRCLIB asks clients to identify themselves
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        // 1. Exact match.
        let exact: R? = await get("get", ["track_name": title, "artist_name": artist, "album_name": album,
                                          "duration": String(Int(duration.rounded()))])
        if let lrc = exact?.syncedLyrics { return parse(lrc) }
        // 2. Fuzzy search, title cleaned of " - Remastered", "(feat. …)" etc; closest length within 10s wins.
        let clean = title.components(separatedBy: " - ")[0]
            .replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
        // A remix/live/acoustic/edit is a different recording: the hit must carry the same tag (e.g. "bunt", "remix").
        let words = { (s: String) in Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)) }
        let tag = words(title).subtracting(words(clean))
        let versioned = !tag.isDisjoint(with: ["remix", "mix", "edit", "live", "acoustic", "version", "vip", "bootleg", "flip", "rework", "cover", "instrumental", "sped", "slowed"])
        let need = versioned ? tag.subtracting(["feat", "ft", "with"]) : []
        for q in [["track_name": versioned ? title : clean, "artist_name": artist], ["q": clean + " " + artist]] {
            let hits: [R] = (await get("search", q) ?? []).filter { need.isSubset(of: words($0.trackName ?? "")) }
            if let best = hits.filter({ $0.syncedLyrics != nil && abs(($0.duration ?? duration) - duration) < 10 })
                .min(by: { abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration) }) {
                return parse(best.syncedLyrics!)
            }
        }
        return []
    }

    // MARK: Publishing your lyrics to LRCLIB (https://lrclib.net/docs#publish-a-new-lyrics)

    struct PublishError: LocalizedError { let errorDescription: String? }

    /// Uploads the lyrics saved for a track. Only the timed lines go up (the file's own [id:]/[album:] tags are
    /// dropped: the Spotify details are what apps match on), plus a plain-text copy built from them.
    static func publish(id: String, title: String, artist: String, album: String, duration: Double) async throws {
        guard let raw = try? String(contentsOf: localURL(id), encoding: .utf8) else { throw PublishError(errorDescription: "No lyrics saved for this song.") }
        let timed = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: #"^\[\d+:\d+(\.\d+)?\]"#, options: .regularExpression) != nil }
        guard !timed.isEmpty else { throw PublishError(errorDescription: "These lyrics have no timed lines.") }
        let plain = parse(raw).map(\.text).filter { $0 != "♪" }.joined(separator: "\n")

        // 1. Challenge → 2. proof of work (nonce such that SHA-256(prefix + nonce) ≤ target, as in LRCGET) → 3. publish.
        struct Challenge: Decodable { let prefix: String; let target: String }
        let challenge: Challenge = try await post("request-challenge", body: nil, token: nil)
        let nonce = try await Task.detached(priority: .userInitiated) { try solve(challenge.prefix, challenge.target) }.value
        let body: [String: Any] = ["trackName": title, "artistName": artist, "albumName": album, "duration": duration.rounded(),
                                   "plainLyrics": plain, "syncedLyrics": timed.joined(separator: "\n")]
        let _: Empty = try await post("publish", body: body, token: "\(challenge.prefix):\(nonce)")
    }

    struct Empty: Decodable {}
    struct ErrorBody: Decodable { let message: String? }

    static func solve(_ prefix: String, _ target: String) throws -> Int {
        let goal = stride(from: 0, to: target.count, by: 2).compactMap {
            UInt8(target[target.index(target.startIndex, offsetBy: $0)..<target.index(target.startIndex, offsetBy: $0 + 2)], radix: 16)
        }
        for nonce in 0..<Int.max {
            try Task.checkCancellation()
            let hash = Array(SHA256.hash(data: Data((prefix + String(nonce)).utf8)))
            if !hash.lexicographicallyPrecedes(goal) && hash != goal { continue }   // need hash ≤ target, byte by byte
            return nonce
        }
        throw PublishError(errorDescription: "Couldn't solve LRCLIB's challenge.")
    }

    private static func post<T: Decodable>(_ path: String, body: [String: Any]?, token: String?) async throws -> T {
        var req = URLRequest(url: URL(string: "https://lrclib.net/api/" + path)!)
        req.httpMethod = "POST"
        req.setValue("DuoPlayer/0.1 (https://github.com/rifkyariy/apple-duo-player)", forHTTPHeaderField: "User-Agent")
        if let token { req.setValue(token, forHTTPHeaderField: "X-Publish-Token") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw PublishError(errorDescription: (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message ?? "LRCLIB answered \(code).")
        }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? (Empty() as! T)
    }

    /// "[mm:ss.xx] text" lines → sorted (seconds, text). Blank lines become "♪".
    static func parse(_ lrc: String) -> [LyricLine] {
        lrc.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let stamp = line[line.index(after: line.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let m = Double(stamp[0]), let s = Double(stamp[1]) else { return nil }
            let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return (m * 60 + s, text.isEmpty ? "♪" : text)
        }
        .sorted { $0.time < $1.time }
    }

    /// Index of the line being sung at `time`, or nil before the first line.
    static func index(_ lines: [LyricLine], at time: Double) -> Int? {
        lines.lastIndex { $0.time <= time }
    }
}
