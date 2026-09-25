import SwiftUI

struct PlayerView: View {
    @State private var p = Player()
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        Device(p: p, t: p.open ? 1 : 0)
            .animation(.smooth(duration: 2.0), value: p.open) // no-bounce spring: slower than the reference 1.4s, eases in and out
            .frame(width: screenW * 2 + margin * 2, height: screenH + margin * 2)
            .task { await p.run() }
            .onReceive(tick) { _ in
                guard p.playing, !p.seeking else { return }
                p.progress = min(p.progress + 0.25, p.duration)
            }
    }
}

// MARK: - Device shell (iPhone Duo look)

let bezel: CGFloat = 5
let bodyRadius: CGFloat = 40

// One half of the body. Outer corners round, hinge side flush so the two halves read as one screen when open.
func halfShape(right: Bool, radius: CGFloat) -> UnevenRoundedRectangle {
    right ? UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous)
          : UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius,
                                   bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
}

// Wallpaper spans the whole inner screen; each half shows its slice.
struct Wallpaper: View {
    let color: Color
    var body: some View {
        ZStack {
            LinearGradient(colors: [color.mix(with: .white, by: 0.15), color.mix(with: .black, by: 0.6)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            Circle().fill(color.mix(with: .white, by: 0.35)).frame(width: 260).blur(radius: 70)
                .offset(x: screenW * 0.55, y: -90)
            Circle().fill(color.mix(with: .black, by: 0.25)).frame(width: 300).blur(radius: 80)
                .offset(x: -screenW * 0.5, y: 100)
        }
        .frame(width: screenW * 2, height: screenH)
    }
}

struct Half<Content: View>: View {
    let right: Bool, color: Color
    // Cover only: content keeps a fixed hinge-side padding; a black bezel strip covers it when closed
    // and fades to wallpaper as the book opens, so nothing shifts during the fold.
    var hingeBezel: Double? = nil
    @ViewBuilder let content: Content

    var body: some View {
        let w = screenW - bezel, h = screenH - bezel * 2
        ZStack {
            Wallpaper(color: color)
                .allowsHitTesting(false)
                .frame(width: w, height: h, alignment: right ? .trailing : .leading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
            content.padding(right ? .leading : .trailing, hingeBezel == nil ? 0 : bezel)
        }
        .frame(width: w, height: h)
        .overlay(alignment: right ? .leading : .trailing) {
            if let b = hingeBezel { Rectangle().fill(.black).frame(width: bezel).opacity(b).allowsHitTesting(false) }
        }
        .clipShape(halfShape(right: right, radius: bodyRadius - bezel))
        .padding(right ? .trailing : .leading, bezel)
        .padding(.vertical, bezel)
        .background(.black, in: halfShape(right: right, radius: bodyRadius))
    }
}

// MARK: - Fold
// Ported from chuspeeism/iphone-duo (main.js):
// - Only the cover turns (0°→180° around the hinge); screen pictures stay fixed as seen from the front,
//   the moving cover just clips them (front-view projection).
// - 0–90°: outer screen blurs/darkens away from the hinge. 90–180°: inner left half blurs/darkens
//   toward its far edge and sharpens as it lands flat.
struct Device: View, Animatable {
    let p: Player
    var t: Double
    nonisolated var animatableData: Double { get { t } set { t = newValue } }

    static let fullW = screenW * 2 + margin * 2, fullH = screenH + margin * 2

    var body: some View {
        let hinge = margin + screenW
        let front = t < 0.5
        let motion = smoothstep(front ? t * 2 : (1 - t) * 2)   // 0 flat, 1 edge-on
        let quad = CoverQuad(t: t, hinge: hinge)
        let color = p.color
        ZStack(alignment: .topLeading) {
            place(Half(right: true, color: color, hingeBezel: 1 - smoothstep(t * 2)) { NowPlaying(p: p, t: t) }, x: hinge)
            if t > 0.001 && t < 0.999 {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.black)   // cover body; grows with perspective past the fixed screen picture
                    if front {
                        place(FoldBlur(motion: motion, hingeAtLeading: true) {
                            Half(right: true, color: color, hingeBezel: 1 - smoothstep(t * 2)) { NowPlaying(p: p, t: t) }.disabled(true)
                        }, x: hinge)
                    } else {
                        place(FoldBlur(motion: motion, hingeAtLeading: false) {
                            Half(right: false, color: color) { LeftScreen(p: p) }.disabled(true)
                        }, x: hinge - screenW)
                    }
                }
                .clipShape(quad)
                .allowsHitTesting(false)
            }
            if t >= 0.999 { place(Half(right: false, color: color) { LeftScreen(p: p) }, x: hinge - screenW) }
        }
        .frame(width: Self.fullW, height: Self.fullH, alignment: .topLeading)
    }

    func place(_ v: some View, x: CGFloat) -> some View {
        v.frame(width: screenW, height: screenH)
            .offset(x: x, y: margin)
            .frame(width: Self.fullW, height: Self.fullH, alignment: .topLeading)
    }
}

func smoothstep(_ x: Double) -> Double { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }

// Silhouette of the turning cover seen from the front, with the body's rounded corners.
// Eye at 5 screen widths, like the reference camera.
struct CoverQuad: Shape {
    let t: Double, hinge: CGFloat

    func path(in rect: CGRect) -> Path {
        let d = 5 * screenW
        let scale = d / (d - screenW * sin(t * .pi))
        let farX = hinge + screenW * cos(t * .pi) * scale
        let dy = screenH / 2 * (scale - 1)
        let width = abs(farX - hinge)
        guard width > 0.5 else { return Path() }
        let pts = [CGPoint(x: hinge, y: margin), CGPoint(x: farX, y: margin - dy),
                   CGPoint(x: farX, y: margin + screenH + dy), CGPoint(x: hinge, y: margin + screenH)]
        let far = min(bodyRadius * scale, width / 2)
        let radii = [min(4, width / 2), far, far, min(4, width / 2)]
        return Path { p in
            p.move(to: CGPoint(x: hinge, y: margin + screenH / 2))
            for i in 0..<4 { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % 4], radius: radii[i]) }
            p.closeSubpath()
        }
    }
}

// Reference law, per point at distance e (0 hinge … 1 far edge):
// blur = 72px·motion·e^1.35 (tuned up here: 60pt, e^0.8), darken = min(1, 2·motion·((e−0.2)/0.8)^1.35).
// ponytail: variable blur = blurred copy faded in by e^1.35; Metal layerEffect if banding shows.
struct FoldBlur<Content: View>: View {
    let motion: Double, hingeAtLeading: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let es = stride(from: 0.0, through: 1.0, by: 0.125).map { $0 }
        let start: UnitPoint = hingeAtLeading ? .leading : .trailing
        let end: UnitPoint = hingeAtLeading ? .trailing : .leading
        ZStack {
            content
            content.blur(radius: 60 * motion)
                .mask(LinearGradient(stops: es.map { .init(color: .black.opacity(pow($0, 0.8)), location: $0) },
                                     startPoint: start, endPoint: end))
        }
        .overlay(LinearGradient(stops: es.map {
            .init(color: .black.opacity(min(1, 2 * motion * pow(max(0, ($0 - 0.2) / 0.8), 1.35))), location: $0)
        }, startPoint: start, endPoint: end))
    }
}

// MARK: - Right half: now playing + side controls

struct NowPlaying: View {
    @Bindable var p: Player
    let t: Double

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if !p.signedIn {
                    status("Connect your Spotify account", button: "Sign in with Spotify") { Task { await p.signIn() } }
                } else if let track = p.track {
                    VStack(alignment: .leading, spacing: 10) {
                        art(track)
                        if !p.fullArt {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title).font(.system(size: 17, weight: .semibold))
                                Text(track.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                            }
                            .lineLimit(1)
                            Spacer(minLength: 0)
                            if !p.lyrics.isEmpty { strip }
                            seekBar
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: p.fullArt ? .center : .top)
                } else {
                    status(p.message ?? "Loading…", button: nil) {}
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            rail
        }
        .padding(.leading, 18).padding(.vertical, 14).padding(.trailing, 8)
        .contextMenu {
            if p.track != nil {
                Button(p.liked ? "Remove from Liked Songs" : "Save to Liked Songs") { p.toggleLike() }
            }
            Menu("Play on") {
                ForEach(p.devices, id: \.name) { d in
                    Button((d.is_active ? "✓ " : "") + d.name) { p.transfer(to: d) }
                }
            }
            if p.signedIn { Button("Sign out") { p.signOut() } }
        }
    }

    // Click the cover to see it full size on this screen; click again to go back.
    func status(_ text: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.white.opacity(0.6))
            Text(text).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
            if let button {
                Button(button, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(red: 0.11, green: 0.73, blue: 0.33), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func art(_ track: Track) -> some View {
        Button { withAnimation(.smooth(duration: 0.5)) { p.fullArt.toggle() } } label: {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { AsyncImage(url: track.art) { $0.resizable().scaledToFill() } placeholder: { p.color } }
                .clipShape(RoundedRectangle(cornerRadius: p.fullArt ? 22 : 16, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: p.fullArt ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.3), in: Circle())
                        .padding(6)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: p.fullArt ? .infinity : 100)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .help(p.fullArt ? "Show player" : "Show full cover")
    }

    var strip: some View {
        let i = p.line
        return VStack(alignment: .leading, spacing: 2) {
            Text(i.map { p.lyrics[$0].text } ?? "♪").font(.system(size: 13, weight: .semibold))
            let n = (i ?? -1) + 1
            if n < p.lyrics.count {
                Text(p.lyrics[n].text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .allowsHitTesting(false)
    }

    var seekBar: some View {
        VStack(spacing: 3) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: g.size.width * p.progress / p.duration)
                }
                .frame(height: 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged {
                        p.seeking = true
                        p.progress = min(max($0.location.x / g.size.width, 0), 1) * p.duration
                    }
                    .onEnded { _ in p.seeking = false; p.seek(to: p.progress) })
            }
            .frame(height: 12)
            HStack {
                Text(time(p.progress))
                Spacer()
                Text("-" + time(p.duration - p.progress))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    func time(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    // Duo puts the controls in a column under the camera, on the hardware side.
    var rail: some View {
        VStack(spacing: 8) {
            Button { NSApp.terminate(nil) } label: {
                Circle().fill(Color(white: 0.3))
                    .overlay(Circle().stroke(.black, lineWidth: 1))
                    .frame(width: 13, height: 13)
                    .frame(width: 24, height: 24).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Quit")
            glass("square.grid.2x2", on: p.open && !p.showLyrics) { p.toggleLeft(lyrics: false) }
                .keyboardShortcut("\\", modifiers: .command)
                .help("Albums")
            glass("quote.bubble", on: p.open && p.showLyrics) { p.toggleLeft(lyrics: true) }
                .keyboardShortcut("l", modifiers: .command)
                .help("Lyrics")
            Spacer(minLength: 0)
            glass("backward.fill") { p.prev() }.keyboardShortcut(.leftArrow, modifiers: [])
            glass(p.playing ? "pause.fill" : "play.fill", prominent: true) { p.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            glass("forward.fill") { p.next() }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .frame(width: 42)
    }

    func glass(_ icon: String, prominent: Bool = false, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: prominent ? 16 : 13, weight: .semibold))
                .frame(width: prominent ? 40 : 32, height: prominent ? 40 : 32)
                .background(prominent || on ? .white : .white.opacity(0.16), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                .foregroundStyle(prominent || on ? .black : .white)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Left half: widgets

struct LeftScreen: View {
    let p: Player

    var body: some View {
        if p.showLyrics { LyricsView(p: p) } else { albums }
    }

    // Four saved albums in a row, "Up next" below.
    var albums: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(0..<4) { i in
                    if i < p.albums.count { album(p.albums[i]) } else { Color.clear.aspectRatio(1, contentMode: .fit) }
                }
            }
            Text("Up next").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            ScrollView {
                VStack(spacing: 6) {
                    if p.queue.isEmpty {
                        Text("Nothing queued").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(p.queue.enumerated()), id: \.offset) { _, t in
                        Button { p.skip(to: t) } label: { row(t) }.buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 14)
    }

    func row(_ t: Track) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: t.art) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text(t.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    func album(_ a: Album) -> some View {
        Button { p.play(a) } label: {
            Color.clear.aspectRatio(1, contentMode: .fit)   // square tile: whole cover visible
                .overlay { AsyncImage(url: a.art) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) } }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(a.name)
    }
}

struct LyricsView: View {
    let p: Player

    var body: some View {
        let cur = p.line ?? -1
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if p.lyrics.isEmpty {
                        Text("No lyrics for this song").font(.system(size: 18, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    }
                    ForEach(Array(p.lyrics.enumerated()), id: \.offset) { i, l in
                        Text(l.text)
                            .font(.system(size: i == cur ? 22 : 18, weight: .bold))
                            .foregroundStyle(.white.opacity(i == cur ? 1 : i < cur ? 0.3 : 0.5))
                            .id(i)
                            .onTapGesture { p.seek(to: l.time) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 100)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(cur, anchor: .center) }
            .onChange(of: cur) { withAnimation(.smooth) { proxy.scrollTo(cur, anchor: .center) } }
        }
        .padding(.leading, 22).padding(.trailing, 14)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                     .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}
