import SwiftUI

struct Track: Equatable {
    let id: String, title: String, artist: String, album: String
    let art: URL?, duration: Double
}

extension Track {
    init(_ t: SPTrack) {
        self.init(id: t.id, title: t.name, artist: t.artists.map(\.name).joined(separator: ", "),
                  album: t.album.name, art: t.album.images.first?.url,
                  duration: Double(t.duration_ms) / 1000)
    }
}

struct Album: Identifiable, Codable {
    let uri: String, name: String, art: URL?
    var id: String { uri }
}

// Library/profile saved to disk: shown instantly on launch, refreshed from Spotify only when stale,
// so relaunches don't re-request everything (that got us rate limited).
struct LibraryCache: Codable {
    var albums: [Album], playlists: [Album], topArtists: [Album], me: SPMe?, savedAt: Date
    static let url = URL.cachesDirectory.appending(path: "DuoPlayer/library.json")
    static let maxAge: TimeInterval = 6 * 3600

    static func load(from url: URL = url) -> LibraryCache? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } }
    func save(to url: URL = url) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url)
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}

// App state. Spotify is the source of truth; we poll it sparingly (see pollInterval) and
// interpolate progress locally in between so the bar and lyrics move smoothly.
@MainActor @Observable final class Player {
    let spotify = Spotify()

    var signedIn = false
    var message: String?            // shown on the cover: no device, errors
    var rateLimitedUntil: Date?     // Spotify said 429: the cover shows a countdown until the next try
    var track: Track?
    var playing = false
    var progress = 0.0
    var liked = false
    var color = Color(red: 0.35, green: 0.33, blue: 0.5)   // wallpaper, from the album art
    var lyrics: [LyricLine] = []
    var albums: [Album] = []
    var playlists: [Album] = []
    var me: SPMe?
    var topArtistsNote: String?   // why top artists are missing
    var topArtists: [Album] = []   // uri/name/art; playing the uri plays the artist
    var queue: [Track] = []         // up next as shown: repeats removed
    private var rawQueue: [Track] = []   // Spotify's real queue, repeats kept: skip(to:) counts "next" presses in this
    var devices: [SPDevice] = []

    var open = false { didSet { refreshQueueIfShown() } }
    var contextURI: String?         // what's playing from: playlist/album (Spotify context), else the track's album
    var contextName = ""
    var listURI: String?            // what the open list shows (the poll keeps rewriting contextURI)
    var albumURI: String?           // current song's album: fallback when a playlist can't be read
    var contextTracks: [Track] = []
    var contextBack = "Albums"      // tab the back button returns to
    var tall = false                // extra album row of height; default is the normal size
    var logins = 0
    var loggingIn = false           // sign-in button shows a spinner
    var tab = "Albums" { didSet { refreshQueueIfShown() } }   // left screen tab (here, not @State, so fold copies match)
    var showLyrics = false { didSet { refreshQueueIfShown() } }   // left screen: full lyrics instead of albums
    var fullArt = false             // first screen: album cover only
    var seeking = false             // user is dragging the seek bar; don't let polls fight it

    var duration: Double { track?.duration ?? 1 }
    var line: Int? { Lyrics.index(lyrics, at: progress) }

    // Rail buttons: open the book on that screen, or close it if it's already showing.
    func toggleLeft(lyrics: Bool) {
        if open && showLyrics == lyrics { open = false } else { showLyrics = lyrics; open = true }
    }

    // MARK: Loop

    func run() async {
        signedIn = spotify.signedIn
        if signedIn, let c = LibraryCache.load() {
            albums = c.albums; playlists = c.playlists; topArtists = c.topArtists; me = c.me; librarySavedAt = c.savedAt
        }
        watchScreenSleep()
        while !Task.isCancelled {
            // A Retry-After from before (e.g. SwiftUI restarted this task) still holds: no request until it passes.
            if let until = rateLimitedUntil { await nap(until: until) }
            if Task.isCancelled { break }
            // Screen asleep or locked: nobody is looking, so don't ask Spotify at all until it wakes.
            if screenAsleep { await nap(until: Date() + 5); continue }
            var wait = pollInterval
            if signedIn {
                defer { retrying = false }
                do {
                    try await poll()
                    if rateLimitedUntil != nil { withAnimation(.smooth(duration: 1)) { rateLimitedUntil = nil } }
                    wait = pollInterval   // from the fresh state (song position, playing/paused)
                } catch { wait = handle(error) }
            }
            if rateLimitedUntil == nil { await nap(until: Date() + wait) }
        }
    }

    // Spotify counts calls per rolling 30s window, so "now playing" is polled sparingly and the app fakes
    // the live feel: progress/lyrics tick locally, buttons update at once, and we poll exactly when it matters.
    private var pollInterval: Double {
        Self.pollInterval(hasTrack: track != nil, playing: playing, remaining: duration - progress)
    }

    nonisolated static func pollInterval(hasTrack: Bool, playing: Bool, remaining: Double) -> Double {
        guard hasTrack else { return 10 }              // nothing playing: "Open Spotify on a device"
        guard playing else { return 30 }               // paused: only another device can change anything
        return max(1, min(10, remaining + 0.8))        // poll right as the song should end, so the next one shows on time
    }

    /// Poll about a second after a playback action (play, skip, seek…) to confirm what Spotify did.
    private func pollSoon() { pollAt = Date() + 1 }
    private var pollAt: Date?

    private var screenAsleep = false
    private func watchScreenSleep() {
        let ws = NSWorkspace.shared.notificationCenter, dist = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, Bool)] = [
            (ws, NSWorkspace.screensDidSleepNotification, true), (ws, NSWorkspace.screensDidWakeNotification, false),
            (dist, Notification.Name("com.apple.screenIsLocked"), true), (dist, Notification.Name("com.apple.screenIsUnlocked"), false)]
        for (center, name, asleep) in events {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenAsleep = asleep
                    if !asleep { self?.retryRequested = true }   // woke up: refresh now
                }
            }
        }
    }

    /// Sleeps in short steps so the retry button, a playback action (pollSoon) or waking the screen can cut it short.
    /// Stops on cancellation too: Task.sleep throws at once then, so without the check this would spin.
    private func nap(until: Date) async {
        while !Task.isCancelled && !retryRequested {
            if Date() >= min(until, pollAt ?? until) { break }
            try? await Task.sleep(for: .seconds(0.25))
        }
        retryRequested = false
        pollAt = nil
    }

    private var retryRequested = false
    var retrying = false   // retry button spins until Spotify answers

    /// Rate-limit screen's retry button: poll once now instead of waiting out Retry-After.
    func retryNow() {
        guard !retrying else { return }
        retrying = true
        retryRequested = true
    }

    // Button spins while we authorize and load everything (song, cover, library) behind the sign-in screen;
    // only then the black ripple covers it and the ready player is revealed.
    func signIn() async {
        loggingIn = true
        defer { loggingIn = false }
        do {
            try await spotify.login()
            message = nil
            try? await poll()   // fills track, lyrics, albums, playlists, profile while the sign-in screen stays up
            if let url = track?.art, artCache.object(forKey: url as NSURL) == nil,
               let (data, _) = try? await URLSession.shared.data(from: url), let img = NSImage(data: data) {
                artCache.setObject(img, forKey: url as NSURL)   // cover shows instantly on reveal
            }
            logins += 1   // plays the login ripple (not on launch, where signedIn also flips to true)
            try? await Task.sleep(for: .seconds(0.9))   // let the black ripple cover the sign-in screen first
            signedIn = true
        } catch { _ = handle(error) }
    }

    // Fold back to one screen first (with the player still showing), then blur over to the sign-in screen.
    func signOut() {
        let wasOpen = open
        open = false
        Task {
            if wasOpen { try? await Task.sleep(for: .seconds(2.8)) }   // fold duration
            spotify.logout()
            LibraryCache.clear(); librarySavedAt = .distantPast
            withAnimation(.smooth(duration: 0.6)) {
                signedIn = false
                track = nil; me = nil; topArtists = []; topArtistsNote = nil   // refetched after the next sign-in (picks up new scopes)
            }
        }
    }

    private var libraryRetry = Date.distantPast
    private var librarySavedAt = Date.distantPast

    private func poll() async throws {
        guard let s: SPPlayback = try await spotify.get("/me/player"), let item = s.item else {
            if track != nil || message == nil { devices = (try? await loadDevices()) ?? [] }
            track = nil
            playing = false
            message = "Open Spotify on a device to start"
            return
        }
        message = nil
        playing = s.is_playing
        if !seeking { progress = Double(s.progress_ms ?? 0) / 1000 }
        albumURI = item.album.uri
        contextURI = s.context.map(\.uri).flatMap { $0.contains(":playlist:") || $0.contains(":album:") ? $0 : nil } ?? item.album.uri
        if item.id != track?.id { await trackChanged(item) }
        // Library/profile: fetched only when missing or the saved copy is stale, and at most once a minute
        // (retrying every poll kept Spotify rate limiting us). Failures keep what's already shown.
        let stale = Date() > librarySavedAt + LibraryCache.maxAge
        if Date() >= libraryRetry, stale || albums.isEmpty || me == nil || playlists.isEmpty || (topArtists.isEmpty && topArtistsNote == nil) {
            libraryRetry = Date() + 60
            var ok = true
            if stale || albums.isEmpty {
                if let a = try? await loadAlbums() { albums = a } else { ok = false }
            }
            if stale || me == nil {
                if let m: SPMe = try? await spotify.get("/me") { me = m } else { ok = false }
            }
            if stale || (topArtists.isEmpty && topArtistsNote == nil) {
                // Try recent, then all-time: new accounts often have nothing for one of the ranges.
                do {
                    var found: [Album] = []
                    for range in ["medium_term", "short_term", "long_term"] where found.isEmpty {
                        let r: SPTopArtists? = try await spotify.get("/me/top/artists", query: ["limit": "4", "time_range": range])
                        found = r?.items.map { Album(uri: $0.uri, name: $0.name, art: $0.images?.first?.url) } ?? []
                    }
                    if found.isEmpty { topArtistsNote = "Not enough listening history yet" } else { topArtists = found }
                } catch let e as Spotify.Failure where e.status == 403 || e.status == 401 {
                    topArtistsNote = "Sign out and sign in again to see top artists"   // old login lacks user-top-read
                } catch { ok = false }
            }
            if stale || playlists.isEmpty {
                if let r: SPPlaylists = try? await spotify.get("/me/playlists", query: ["limit": "50"]) {
                    playlists = r.items.compactMap { $0.map { Album(uri: $0.uri, name: $0.name, art: $0.images?.first?.url) } }
                } else { ok = false }
            }
            if ok {
                librarySavedAt = Date()
                LibraryCache(albums: albums, playlists: playlists, topArtists: topArtists, me: me, savedAt: librarySavedAt).save()
            }
        }
    }

    private func trackChanged(_ item: SPTrack) async {
        let t = Track(item)
        track = t
        queueStale = true; refreshQueueIfShown()   // only fetched while Up next is on screen
        lyrics = []
        let liked: [Bool]? = try? await spotify.get("/me/tracks/contains", query: ["ids": t.id], cacheFor: 3600)
        self.liked = liked?.first ?? false
        if let art = t.art, let c = await averageColor(art) { withAnimation(.smooth(duration: 1)) { color = c } }
        let lines = await Lyrics.fetch(title: t.title, artist: item.artists.first?.name ?? "", album: t.album, duration: t.duration)
        if track?.id == t.id { lyrics = lines }
        devices = (try? await loadDevices()) ?? devices
    }

    private func loadAlbums() async throws -> [Album] {
        let r: SPSavedAlbums? = try await spotify.get("/me/albums", query: ["limit": "50"])
        return r?.items.map { Album(uri: $0.album.uri, name: $0.album.name, art: $0.album.images.first?.url) } ?? []
    }

    private func loadDevices() async throws -> [SPDevice] {
        let r: SPDevices? = try await spotify.get("/me/player/devices", cacheFor: 300)
        return r?.devices ?? []
    }

    /// Shows the error and returns how long to wait before the next poll.
    private func handle(_ error: Error) -> Double {
        guard let f = error as? Spotify.Failure else { message = error.localizedDescription; return 3 }
        if f.status == 401 { signedIn = spotify.signedIn }
        withAnimation(.smooth(duration: 1)) {   // wallpaper cross-fades to/from the green waiting screen
            rateLimitedUntil = f.status == 429 ? Date() + max(f.retryAfter, 1) : nil
            if rateLimitedUntil != nil { open = false }
        }   // albums/lyrics are disabled while limited: fold the book shut
        message = f.status == 403 ? "Spotify Premium is required for playback control" : f.message
        return max(f.retryAfter, 1)
    }

    // MARK: Controls (optimistic: update the UI now, the next poll corrects it)

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) {
        Task {
            do {
                try await spotify.call(method, path, query: query, body: body)
                if path.hasPrefix("/me/player") { pollSoon() }   // confirm the new state; likes etc. don't change playback
            } catch { _ = handle(error) }
        }
    }

    // The queue changes with every song but is only seen on the Up next tab: fetch it when it's shown, not per song.
    private var queueStale = true
    private func refreshQueueIfShown() {
        guard queueStale, open, tab == "Up next", !showLyrics, rateLimitedUntil == nil else { return }
        queueStale = false
        Task { await loadQueue() }
    }

    /// Reads Spotify's queue into rawQueue (real order) and queue (shown, repeats removed).
    @discardableResult
    func loadQueue() async -> [Track] {
        let q: SPQueue? = try? await spotify.get("/me/player/queue")
        setQueue(q?.queue.map(Track.init) ?? [])
        queueStale = false
        return rawQueue
    }

    private func setQueue(_ real: [Track]) {
        rawQueue = real
        var seen = Set<String>()
        queue = real.filter { seen.insert($0.id).inserted }
    }

    func togglePlay() {
        playing.toggle()
        send("PUT", playing ? "/me/player/play" : "/me/player/pause")
    }

    func next() { send("POST", "/me/player/next") }

    /// Spotify can't jump into the queue directly, so skip forward until we reach it.
    func skip(to t: Track) {
        // Up next is just the current song again (repeat one): "next" would leave the repeat and jump
        // somewhere else, so restart the song instead.
        if t.id == track?.id { seek(to: 0); return }
        Task {
            // Count "next" presses in Spotify's real queue, read fresh (the shown list drops repeats and may be ahead of Spotify).
            guard let i = await loadQueue().firstIndex(where: { $0.id == t.id }) else { return }
            do { for _ in 0...i { try await spotify.call("POST", "/me/player/next") }; pollSoon() } catch { _ = handle(error) }
        }
    }

    func prev() {
        if progress > 3 { seek(to: 0) } else { send("POST", "/me/player/previous") }
    }

    func seek(to seconds: Double) {
        progress = seconds
        send("PUT", "/me/player/seek", query: ["position_ms": String(Int(seconds * 1000))])
    }

    // Title tapped: list the tracks of the playlist/album it's playing from, on the left screen.
    func openContext() {
        guard let uri = contextURI else { return }
        let id = String(uri.split(separator: ":").last ?? "")
        if tab != "Context" { contextBack = tab }
        tab = "Context"; showLyrics = false; open = true
        contextName = ""; contextTracks = []; listURI = uri
        Task {
            if uri.contains(":playlist:"), let r: SPPlaylistFull = try? await spotify.get("/playlists/\(id)", cacheFor: 3600) {
                contextName = r.name
                contextTracks = r.tracks.items.compactMap { $0.track.map(Track.init) }
                return
            }
            // Album context, or a playlist Spotify won't share with dev-mode apps (e.g. its own mixes): show the song's album.
            let albumURI = uri.contains(":album:") ? uri : (self.albumURI ?? uri)
            listURI = albumURI
            let albumID = String(albumURI.split(separator: ":").last ?? "")
            if let a: SPAlbumFull = try? await spotify.get("/albums/\(albumID)", cacheFor: 3600) {
                contextName = a.name
                contextTracks = a.tracks.items.map {
                    Track(id: $0.id, title: $0.name, artist: $0.artists.map(\.name).joined(separator: ", "), album: a.name,
                          art: a.images.first?.url, duration: Double($0.duration_ms) / 1000)
                }
            } else if let t = track {
                // Placeholder until Spotify answers again: the song we already know, instead of an empty error.
                contextName = t.album
                contextTracks = [t]
            } else { contextName = "Couldn't load this list" }
        }
    }

    func play(_ t: Track, inContext uri: String?) {
        var body: [String: Any] = ["offset": ["uri": "spotify:track:\(t.id)"]]
        if let uri { body["context_uri"] = uri } else { body = ["uris": ["spotify:track:\(t.id)"]] }
        send("PUT", "/me/player/play", body: body)
    }

    func play(_ album: Album) { send("PUT", "/me/player/play", body: ["context_uri": album.uri]) }

    func toggleLike() {
        guard let id = track?.id else { return }
        liked.toggle()
        spotify.forget("/me/tracks/contains")
        send(liked ? "PUT" : "DELETE", "/me/tracks", query: ["ids": id])
    }

    func transfer(to device: SPDevice) {
        guard let id = device.id else { return }
        spotify.forget("/me/player/devices")   // the ✓ moves to the new device
        send("PUT", "/me/player", body: ["device_ids": [id], "play": true])
    }
}

/// Average color of the album art, darkened a little so white text stays readable.
func averageColor(_ url: URL) async -> Color? {
    guard let (data, _) = try? await URLSession.shared.data(from: url),
          let cg = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    var px = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Color(red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255)
        .mix(with: .black, by: 0.15)
}
