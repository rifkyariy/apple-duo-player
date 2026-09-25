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

struct Album: Identifiable {
    let uri: String, name: String, art: URL?
    var id: String { uri }
}

// App state. Spotify is the source of truth; we poll it every second and
// interpolate progress locally in between so the bar and lyrics move smoothly.
@MainActor @Observable final class Player {
    let spotify = Spotify()

    var signedIn = false
    var message: String?            // shown on the cover: no device, errors
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
    var queue: [Track] = []         // up next, from Spotify
    var devices: [SPDevice] = []

    var open = false
    var logins = 0
    var loggingIn = false           // sign-in button shows a spinner
    var tab = "Albums"              // left screen tab (here, not @State, so fold copies match)
    var showLyrics = false          // left screen: full lyrics instead of albums
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
        while !Task.isCancelled {
            var wait = 1.0
            if signedIn {
                do { try await poll() } catch { wait = handle(error) }
            }
            try? await Task.sleep(for: .seconds(wait))
        }
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
            withAnimation(.smooth(duration: 0.6)) {
                signedIn = false
                track = nil; me = nil; topArtists = []; topArtistsNote = nil   // refetched after the next sign-in (picks up new scopes)
            }
        }
    }

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
        if item.id != track?.id { await trackChanged(item) }
        if albums.isEmpty { albums = (try? await loadAlbums()) ?? [] }
        if me == nil { me = try? await spotify.get("/me") }
        if topArtists.isEmpty && topArtistsNote == nil {
            // Try recent, then all-time: new accounts often have nothing for one of the ranges.
            do {
                for range in ["medium_term", "short_term", "long_term"] where topArtists.isEmpty {
                    let r: SPTopArtists? = try await spotify.get("/me/top/artists", query: ["limit": "4", "time_range": range])
                    topArtists = r?.items.map { Album(uri: $0.uri, name: $0.name, art: $0.images?.first?.url) } ?? []
                }
                if topArtists.isEmpty { topArtistsNote = "Not enough listening history yet" }
            } catch let e as Spotify.Failure where e.status == 403 || e.status == 401 {
                topArtistsNote = "Sign out and sign in again to see top artists"   // old login lacks user-top-read
            } catch {}
        }
        if playlists.isEmpty {
            let r: SPPlaylists? = try? await spotify.get("/me/playlists", query: ["limit": "50"])
            playlists = r?.items.compactMap { $0.map { Album(uri: $0.uri, name: $0.name, art: $0.images?.first?.url) } } ?? []
        }
    }

    private func trackChanged(_ item: SPTrack) async {
        let t = Track(item)
        track = t
        let q: SPQueue? = try? await spotify.get("/me/player/queue")
        var seen = Set<String>()   // Spotify repeats the queue on loop/repeat; show each song once
        queue = (q?.queue.map(Track.init) ?? []).filter { seen.insert($0.id).inserted }
        lyrics = []
        let liked: [Bool]? = try? await spotify.get("/me/tracks/contains", query: ["ids": t.id])
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
        let r: SPDevices? = try await spotify.get("/me/player/devices")
        return r?.devices ?? []
    }

    /// Shows the error and returns how long to wait before the next poll.
    private func handle(_ error: Error) -> Double {
        guard let f = error as? Spotify.Failure else { message = error.localizedDescription; return 3 }
        if f.status == 401 { signedIn = spotify.signedIn }
        message = f.status == 403 ? "Spotify Premium is required for playback control" : f.message
        return max(f.retryAfter, 1)
    }

    // MARK: Controls (optimistic: update the UI now, the next poll corrects it)

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) {
        Task {
            do { try await spotify.call(method, path, query: query, body: body) } catch { _ = handle(error) }
        }
    }

    func togglePlay() {
        playing.toggle()
        send("PUT", playing ? "/me/player/play" : "/me/player/pause")
    }

    func next() { send("POST", "/me/player/next") }

    /// Spotify can't jump into the queue directly, so skip forward until we reach it.
    func skip(to t: Track) {
        guard let i = queue.firstIndex(of: t) else { return }
        Task {
            do { for _ in 0...i { try await spotify.call("POST", "/me/player/next") } } catch { _ = handle(error) }
        }
    }

    func prev() {
        if progress > 3 { seek(to: 0) } else { send("POST", "/me/player/previous") }
    }

    func seek(to seconds: Double) {
        progress = seconds
        send("PUT", "/me/player/seek", query: ["position_ms": String(Int(seconds * 1000))])
    }

    func play(_ album: Album) { send("PUT", "/me/player/play", body: ["context_uri": album.uri]) }

    func toggleLike() {
        guard let id = track?.id else { return }
        liked.toggle()
        send(liked ? "PUT" : "DELETE", "/me/tracks", query: ["ids": id])
    }

    func transfer(to device: SPDevice) {
        guard let id = device.id else { return }
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
