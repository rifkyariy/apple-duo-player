import Foundation

typealias LyricLine = (time: Double, text: String)

// Synced lyrics from LRCLIB (lrclib.net): free, no key. Spotify's API has no lyrics.
enum Lyrics {
    static func fetch(title: String, artist: String, album: String, duration: Double) async -> [LyricLine] {
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
