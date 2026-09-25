import Foundation

typealias LyricLine = (time: Double, text: String)

// Synced lyrics from LRCLIB (lrclib.net): free, no key. Spotify's API has no lyrics.
enum Lyrics {
    static func fetch(title: String, artist: String, album: String, duration: Double) async -> [LyricLine] {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist),
                        .init(name: "album_name", value: album), .init(name: "duration", value: String(Int(duration.rounded())))]
        var req = URLRequest(url: c.url!)
        req.setValue("DuoPlayer/0.1", forHTTPHeaderField: "User-Agent")   // LRCLIB asks clients to identify themselves
        struct R: Decodable { let syncedLyrics: String? }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let lrc = (try? JSONDecoder().decode(R.self, from: data))?.syncedLyrics else { return [] }
        return parse(lrc)
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
