import SwiftUI

struct PlayerView: View {
    @State private var p = Player()
    @State private var booting = true
    @State private var resizing = false   // blur while the size switches

    // Grab bar under the front screen: drag down for the taller size, up to go back; click toggles.
    // One DragGesture handles both (a Button would also fire on drag release); window-background dragging
    // is paused while over it so the window doesn't move instead.
    var sizeHandle: some View {
        Capsule().fill(.black.opacity(0.35)).frame(width: 72, height: 5)
            .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 0.5))
            .frame(width: 120, height: 26)
            .background(Color.black.opacity(0.001))   // tiny alpha: macOS passes clicks through fully clear pixels
            .contentShape(Rectangle())
            .onHover { h in
                NSApp.windows.first { $0 is KeyPanel }?.isMovableByWindowBackground = !h
                if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onEnded { v in
                let dy = v.translation.height   // positive = dragged down
                if abs(dy) < 4 { setTall(!p.tall) } else if dy > 10 { setTall(true) } else if dy < -10 { setTall(false) }
            })
            .accessibilityElement().accessibilityLabel("Resize").accessibilityAddTraits(.isButton)
            .accessibilityAction { setTall(!p.tall) }
            .help(p.tall ? "Drag up for the compact size" : "Drag down for the taller size")
            .offset(x: margin + screenW + screenW / 2 - 60, y: -17)   // ~10pt under the body
    }

    /// Switch height; the window grows/shrinks downward, top edge stays put.
    func setTall(_ tall: Bool) {
        guard tall != p.tall, !resizing else { return }
        withAnimation(.easeIn(duration: 0.18)) { resizing = true }
        Task {
            try? await Task.sleep(for: .seconds(0.18))
            applySize(tall)
            try? await Task.sleep(for: .seconds(0.05))
            withAnimation(.easeOut(duration: 0.4)) { resizing = false }
        }
    }

    private func applySize(_ tall: Bool) {
        screenH = baseScreenH + (tall ? tallExtra : 0)
        p.tall = tall
        if let w = NSApp.windows.first(where: { $0 is KeyPanel }) {
            var f = w.frame
            let h = screenH + margin * 2
            f.origin.y += f.height - h; f.size.height = h
            w.setFrame(f, display: true)
        }
    }
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        Device(p: p, t: p.open ? 1 : 0)
            .animation(.timingCurve(0.45, 0, 0.2, 1, duration: 2.8), value: p.open) // fixed-length ease: a spring settles early and felt rushed; tune duration here
            .overlay(alignment: .topLeading) {
                LoginRipple(trigger: p.logins, ready: p.track != nil || p.message != nil)
                    .frame(width: screenW, height: screenH)
                    .clipShape(halfShape(right: true, radius: bodyRadius, hinge: hingeRadius))
                    .offset(x: margin + screenW, y: margin)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if booting {
                    Splash { booting = false }
                        .frame(width: screenW, height: screenH)
                        .clipShape(halfShape(right: true, radius: bodyRadius, hinge: hingeRadius))
                        .offset(x: margin + screenW, y: margin)
                }
            }
            .overlay(alignment: .bottomLeading) { sizeHandle }
            .id(p.tall)   // screenH is a plain global: rebuild everything when it changes
            .environment(\.screenBlur, resizing ? 16 : 0)   // Half blurs its screen only, not the body/bezel
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
let hingeRadius: CGFloat = 6   // folded device's left corners; shrinks to 0 as it opens (same curve everywhere)

// One half of the body. Outer corners round, hinge side flush so the two halves read as one screen when open.
// `hinge` rounds the hinge-side corners slightly (the folded device's left edge); 0 when open so the halves meet flush.
func halfShape(right: Bool, radius: CGFloat, hinge: CGFloat = 0) -> UnevenRoundedRectangle {
    right ? UnevenRoundedRectangle(topLeadingRadius: hinge, bottomLeadingRadius: hinge,
                                   bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous)
          : UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius,
                                   bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
}

private struct ScreenBlurKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var screenBlur: CGFloat { get { self[ScreenBlurKey.self] } set { self[ScreenBlurKey.self] = newValue } }
}

// Wallpaper spans the whole inner screen; each half shows its slice.
let loginGlows = [Color(red: 0.11, green: 0.73, blue: 0.33).opacity(0.35), Color(red: 0.3, green: 0.5, blue: 1).opacity(0.2)]
let loginColor = Color(red: 0.03, green: 0.04, blue: 0.05)   // sign-in: near black, the green/blue waves carry the color
// Rate limited: dim green waves on a near-black green base, so "waiting" reads calmer than sign-in.
let limitGlows = [Color(red: 0.11, green: 0.73, blue: 0.33).opacity(0.22), Color(red: 0.05, green: 0.45, blue: 0.3).opacity(0.2)]
let limitColor = Color(red: 0.01, green: 0.08, blue: 0.04)

struct Wallpaper: View {
    let color: Color
    var wave = false   // sign-in / rate-limited screens: the glow blobs drift in slow blurred waves
    var glows = loginGlows   // the two extra blobs drifting in while waving

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !wave)) { tl in   // slow drift: 30fps looks the same, costs far less than 120
            let k = wave ? tl.date.timeIntervalSinceReferenceDate * 2.2 : 0   // speed
            ZStack {
                LinearGradient(colors: [color.mix(with: .white, by: 0.15), color.mix(with: .black, by: 0.6)],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                Circle().fill(color.mix(with: .white, by: 0.35)).frame(width: 260).blur(radius: 70)
                    .offset(x: screenW * 0.55 + (wave ? 130 : 0) * sin(k * 0.5), y: -90 + (wave ? 110 : 0) * cos(k * 0.4))
                Circle().fill(color.mix(with: .black, by: 0.25)).frame(width: 300).blur(radius: 80)
                    .offset(x: -screenW * 0.5 + (wave ? 130 : 0) * cos(k * 0.35), y: 100 + (wave ? 90 : 0) * sin(k * 0.6))
                if wave {
                    Circle().fill(glows[0]).frame(width: 220).blur(radius: 60)
                        .offset(x: screenW * 0.5 + 140 * cos(k * 0.45), y: 30 + 110 * sin(k * 0.3))
                    Circle().fill(glows[1]).frame(width: 180).blur(radius: 60)
                        .offset(x: screenW * 0.5 + 120 * sin(k * 0.38 + 2), y: -40 + 100 * cos(k * 0.52 + 1))
                }
            }
        }
        .frame(width: screenW * 2, height: screenH)
    }
}

struct Half<Content: View>: View {
    let right: Bool, color: Color
    var wave = false
    var glows = loginGlows
    // Cover only: content keeps a fixed hinge-side padding; a black bezel strip covers it when closed
    // and fades to wallpaper as the book opens, so nothing shifts during the fold.
    var hingeBezel: Double? = nil
    @ViewBuilder let content: Content

    var hingeR: CGFloat { hingeRadius * (hingeBezel ?? 0) }
    @Environment(\.screenBlur) private var screenBlur

    var body: some View {
        let w = screenW - bezel, h = screenH - bezel * 2
        ZStack {
            Wallpaper(color: color, wave: wave, glows: glows)
                .allowsHitTesting(false)
                .frame(width: w, height: h, alignment: right ? .trailing : .leading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
            content.padding(right ? .leading : .trailing, hingeBezel == nil ? 0 : bezel)
        }
        .frame(width: w, height: h)
        .blur(radius: screenBlur)   // resize blur; clipped to the screen below
        .overlay(alignment: right ? .leading : .trailing) {
            if let b = hingeBezel { Rectangle().fill(.black).frame(width: bezel).opacity(b).allowsHitTesting(false) }
        }
        .clipShape(halfShape(right: right, radius: bodyRadius - bezel, hinge: max(0, hingeR - bezel)))
        .padding(right ? .trailing : .leading, bezel)
        .padding(.vertical, bezel)
        .background(.black, in: halfShape(right: right, radius: bodyRadius, hinge: hingeR))
        // 3D rim: lit from the top, shadowed at the bottom, like a polished metal edge.
        .overlay(halfShape(right: right, radius: bodyRadius, hinge: hingeR)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08), .black.opacity(0.6)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
            .allowsHitTesting(false))
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

    static let fullW = screenW * 2 + margin * 2
    static var fullH: CGFloat { screenH + margin * 2 }

    var body: some View {
        let hinge = margin + screenW
        let front = t < 0.5
        let motion = smoothstep(front ? t * 2 : (1 - t) * 2)   // 0 flat, 1 edge-on
        let quad = CoverQuad(t: t, hinge: hinge)
        let limited = p.rateLimitedUntil != nil
        let color = limited ? limitColor : !p.signedIn ? loginColor : p.color
        let wave = !p.signedIn || limited, glows = limited ? limitGlows : loginGlows
        ZStack(alignment: .topLeading) {
            place(Half(right: true, color: color, wave: wave, glows: glows, hingeBezel: 1 - smoothstep(t * 2)) { NowPlaying(p: p, t: t) }, x: hinge)
            if t > 0.001 && t < 0.999 {
                CoverEdge(t: t, hinge: hinge).allowsHitTesting(false)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.black)   // cover body; grows with perspective past the fixed screen picture
                    if front {
                        place(FoldBlur(motion: motion, hingeAtLeading: true) {
                            Half(right: true, color: color, wave: wave, glows: glows, hingeBezel: 1 - smoothstep(t * 2)) { NowPlaying(p: p, t: t) }   // not .disabled: that dims buttons, then the real screen snaps bright
                        }, x: hinge)
                    } else {
                        place(FoldBlur(motion: motion, hingeAtLeading: false) {
                            Half(right: false, color: color) { LeftScreen(p: p) }
                        }, x: hinge - screenW)
                    }
                }
                .clipShape(quad)
                .allowsHitTesting(false)
                // Copies appear mid-fold inside the fold's 2.8s transaction; without this their images play
                // the blur-in transition for the whole fold (the blurry cover).
                .transaction { $0.animation = nil }
            }
            if t >= 0.999 { place(Half(right: false, color: color) { LeftScreen(p: p) }, x: hinge - screenW).transition(.identity) }   // appear at once; don't strip animations (tabs, lyrics) inside
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
        let near = min(hingeRadius * (1 - smoothstep(t * 2)), width / 2)   // matches Half.hingeR
        let radii = [near, far, far, near]
        return Path { p in
            p.move(to: CGPoint(x: hinge, y: margin + screenH / 2))
            for i in 0..<4 { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % 4], radius: radii[i]) }
            p.closeSubpath()
        }
    }
}

// The cover's thickness: the same silhouette shifted outward (away from the hinge) and drawn behind it,
// so the visible sliver keeps the cover's perspective and rounded corners. Widest when edge-on.
struct CoverEdge: View {
    let t: Double, hinge: CGFloat
    var body: some View {
        let w = 7 * sin(t * .pi)   // gradient below is lit at the outer edge, where the sliver shows
        let outward: CGFloat = t < 0.5 ? 1 : -1
        CoverQuad(t: t, hinge: hinge)
            .fill(LinearGradient(colors: [Color(white: 0.1), Color(white: 0.25), Color(white: 0.55)],
                                 startPoint: outward > 0 ? .leading : .trailing, endPoint: outward > 0 ? .trailing : .leading))
            .overlay(CoverQuad(t: t, hinge: hinge).stroke(.white.opacity(0.25), lineWidth: 0.5))
            .offset(x: outward * w)
    }
}

// Reference law, per point at distance e (0 hinge … 1 far edge):
// blur = 72px·motion·e^1.35 (tuned up here: 60pt, e^0.8), darken = min(1, 2·motion·((e−0.2)/0.8)^1.35).
// ponytail: variable blur = blurred copy faded in by e^1.35; Metal layerEffect if banding shows.
struct FoldBlur<Content: View>: View {
    let motion: Double, hingeAtLeading: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let es = stride(from: 0.0, through: 1.0, by: 0.0625).map { $0 }
        let start: UnitPoint = hingeAtLeading ? .leading : .trailing
        let end: UnitPoint = hingeAtLeading ? .trailing : .leading
        ZStack {
            content
            // Sharpness sweeps out from the hinge as the cover lands (motion → 0), so the far edge clears last
            // instead of the whole screen snapping sharp at the end.
            content.blur(radius: 70 * motion)   // linear: sqrt jumped to ~7pt blur on the first frames of a fold
                .mask(LinearGradient(stops: es.map { .init(color: .black.opacity(smoothstep(($0 - 1 + 1.4 * motion) / 0.4)), location: $0) },
                                     startPoint: start, endPoint: end))
        }
        .overlay(LinearGradient(stops: es.map {
            .init(color: .black.opacity(min(1, 2 * motion * pow(max(0, ($0 - 0.2) / 0.8), 1.35))), location: $0)
        }, startPoint: start, endPoint: end))
    }
}

// Spotify rate limited us (429): an hourglass and a live countdown to the next try, instead of a bare error line.
struct RateLimited: View {
    let until: Date
    let retrying: Bool
    let retry: () -> Void
    @State private var flip = 0.0   // hourglass turns over every few seconds

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hourglass")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                // A plain rotation, not .symbolEffect(.rotate): that re-laid out the whole window every frame (~13% CPU).
                .rotationEffect(.degrees(flip))
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2.4))
                        withAnimation(.easeInOut(duration: 0.8)) { flip += 180 }
                    }
                }
                .frame(width: 58, height: 58)
                .background(.white.opacity(0.12), in: Circle())
            VStack(spacing: 4) {
                Text("Spotify needs a breather").font(.system(size: 15, weight: .bold))
                Text("Spotify paused requests from this app.\nYour music keeps playing.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
            }
            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(until.timeIntervalSince(ctx.date).rounded(.up)))
                    // Spotify can ask for hours (seen: ~12h), so long waits read as "11h 56m".
                    let when = left >= 3600 ? "\(left / 3600)h \(left % 3600 / 60)m" : "\(left / 60):\(String(format: "%02d", left % 60))"
                    Text(left > 0 ? "Retrying in \(when)" : "Retrying…")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.smooth, value: left)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                Button(action: retry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(retrying ? 360 : 0))
                        .animation(retrying ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: retrying)
                        .frame(width: 27, height: 27)
                        .background(.white.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(retrying)
                .help("Try again now")
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.blurReplace)
    }
}

// MARK: - Right half: now playing + side controls

struct NowPlaying: View {
    @Bindable var p: Player
    let t: Double
    @State private var closeHover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            info
            rail
        }
        .padding(.leading, 18).padding(.vertical, 14).padding(.trailing, 8)
        .contextMenu { menu }
    }

    var info: some View {
            Group {
                if !p.signedIn {
                    status("", button: "Log in with Spotify") { Task { await p.signIn() } }
                        .transition(.blurReplace)
                } else if let track = p.track {
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack { art(track).id(track.id).transition(.blurReplace) }
                        if !p.fullArt || p.tall {   // tall size has room for the title under the full cover
                            ZStack(alignment: .leading) {
                                Button { withAnimation(.smooth(duration: 0.4)) { p.openContext() } } label: {   // tracks of this album/playlist
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(track.title).font(.system(size: 17, weight: .semibold))
                                        Text(track.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                                    }
                                    .lineLimit(1)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Show \(p.contextURI?.contains(":playlist:") == true ? "playlist" : "album")")
                                .id(track.id).transition(.blurReplace)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !p.fullArt {
                            Spacer(minLength: 0)
                            do {   // always laid out so track changes (lyrics reset, then reload) never resize the cover/title
                                // Hidden while full lyrics are on the left: fades with the fold itself (t), so every copy agrees.
                                let shown = p.lyrics.isEmpty ? 0 : p.showLyrics ? 1 - smoothstep(t * 2) : 1
                                Button { withAnimation(.smooth(duration: 0.4)) { p.showLyrics = true; p.open = true } } label: {   // strip → full lyrics on the left
                                    strip.contentShape(RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                                .allowsHitTesting(shown > 0.5)
                                .help("Show lyrics")
                                .blur(radius: 10 * (1 - shown)).opacity(shown)
                                    .animation(.smooth(duration: 0.6), value: p.lyrics.isEmpty)
                                    .animation(.smooth(duration: 0.45), value: p.showLyrics)
                            }   // full lyrics on the left: hide strip but keep its space
                            seekBar
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: p.fullArt ? .center : .top)
                    .animation(.smooth(duration: 0.5), value: track.id)   // blur cross-fade on song change
                    .transition(.blurReplace)
                } else {
                    if let until = p.rateLimitedUntil { RateLimited(until: until, retrying: p.retrying) { p.retryNow() } }
                    else if let m = p.message { status(m, button: nil) {} }   // no "Loading…": the login ripple covers that moment
                    else { Color.clear }   // keeps the width so the button column stays on the edge
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder var menu: some View {
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

    // Click the cover to see it full size on this screen; click again to go back.
    func status(_ text: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            if let button {   // sign-in screen
                TimelineView(.animation) { tl in   // logo glow breathes slowly
                    let k = (sin(tl.date.timeIntervalSinceReferenceDate * 1.6) + 1) / 2
                    ZStack {
                        Circle().fill(spotifyGreen.opacity(0.18 + 0.12 * k)).frame(width: 84, height: 84).blur(radius: 14)
                        Circle().stroke(spotifyGreen.opacity(0.25 + 0.2 * k), lineWidth: 1).frame(width: 72 + 6 * k, height: 72 + 6 * k)
                        SpotifyLogo().fill(spotifyGreen).frame(width: 54, height: 54)
                    }
                    .frame(width: 88, height: 88)
                }
                VStack(spacing: 5) {
                    Text("Connect Spotify").font(.system(size: 18, weight: .heavy))
                    Text("Control playback, follow the lyrics\nand browse your library.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center).lineSpacing(1.5)
                }
                Button(action: action) {
                    HStack(spacing: 7) {
                        if p.loggingIn { ProgressView().controlSize(.small).tint(.black).frame(width: 15, height: 15) }
                        else { SpotifyLogo().fill(.black).frame(width: 15, height: 15) }
                        Text(p.loggingIn ? "Connecting…" : button).font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .frame(width: 168, height: 36)
                    .background(spotifyGreen, in: Capsule())
                    .shadow(color: spotifyGreen.opacity(0.35), radius: 10, y: 3)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .animation(.smooth(duration: 0.25), value: p.loggingIn)
                .padding(.top, 4)
                Text("Spotify Premium needed for playback control")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.38))
            } else {
                Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.white.opacity(0.6))
                Text(text).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Full cover fills the column (screen minus padding, button rail and gaps), capped by the height
    // left over (tall size keeps room for the title below).
    var artSize: CGFloat {
        guard p.fullArt else { return p.tall ? 100 : 90 }   // normal size: 100 overflows the column by a few points
        let w = screenW - bezel - 18 - 8 - 42 - 8
        return min(w, screenH - bezel * 2 - 28 - (p.tall ? 52 : 0))
    }

    func art(_ track: Track) -> some View {
        Button { withAnimation(.smooth(duration: 0.5)) { p.fullArt.toggle() } } label: {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { Art(url: track.art) { p.color } }
                .clipShape(RoundedRectangle(cornerRadius: p.fullArt ? 22 : 16, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: p.fullArt ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.3), in: Circle())
                        .padding(6)
                }
                .frame(width: artSize, height: artSize)   // explicit size so the grow/shrink animates (maxWidth: .infinity can't)
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
            // Always two lines, so the strip (and the cover/title above it) never changes height.
            Text(n < p.lyrics.count ? p.lyrics[n].text : " ").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                Circle().fill(closeHover ? Color(red: 0.55, green: 0.1, blue: 0.1) : Color(white: 0.3))   // dark red on hover
                    .overlay(Circle().stroke(.black, lineWidth: 1))
                    .frame(width: 13, height: 13)
                    .frame(width: 24, height: 24).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { closeHover = h } }
            .help("Quit")
            // Albums/lyrics need Spotify: off while signed out or rate limited (their contents can't load).
            let canBrowse = p.signedIn && p.rateLimitedUntil == nil
            glass("square.grid.2x2", on: p.open && !p.showLyrics) { p.toggleLeft(lyrics: false) }
                .disabled(!canBrowse).opacity(canBrowse ? 1 : 0.35)
                .keyboardShortcut("\\", modifiers: .command)
                .help("Albums")
            glass("quote.bubble", on: p.open && p.showLyrics) { p.toggleLeft(lyrics: true) }
                .disabled(!canBrowse).opacity(canBrowse ? 1 : 0.35)
                .keyboardShortcut("l", modifiers: .command)
                .help("Lyrics")
            Spacer(minLength: 0)
            glass("backward.fill") { p.prev() }.keyboardShortcut(.leftArrow, modifiers: [])
            glass(p.playing ? "pause.fill" : "play.fill", prominent: true) { p.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            glass("forward.fill") { p.next() }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .frame(width: 42)
        .focusEffectDisabled()   // no keyboard focus ring (accent color) around the first button
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
    var tab: String { p.tab }
    @State private var forward = true   // slide direction: new tab is to the right of the old one
    static let order = ["Albums", "Playlists", "Up next", "Profile", "Context"]
    func go(_ t: String) {
        forward = Self.order.firstIndex(of: t)! > Self.order.firstIndex(of: tab)!
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { p.tab = t }   // swipe feel
    }
    @Namespace private var tabNS
    @State private var contextScroll: Int?   // row id (offset) the context list is scrolled to

    var body: some View {
        ZStack {
            if p.showLyrics { LyricsView(p: p).transition(.blurReplace) } else { library.transition(.blurReplace) }
        }
        .animation(.smooth(duration: 0.45), value: p.showLyrics)
    }

    // Albums / Playlists / Up next, switched by a segmented tab bar.
    var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            if tab == "Context" {
                // Opened from the title: back button + album/playlist name instead of the tabs.
                HStack(spacing: 10) {
                    Button { go(p.contextBack) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.16), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                            .foregroundStyle(.white).contentShape(Circle())
                    }
                    .buttonStyle(.plain).help("Back")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(p.listURI?.contains(":playlist:") == true ? "PLAYLIST" : "ALBUM")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                        Text(p.contextName.isEmpty ? "Loading…" : p.contextName)
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .transition(.blurReplace)
            } else {
            HStack(spacing: 8) {
            // Glass pill tabs, same look as the round glass buttons.
            HStack(spacing: 2) {
                ForEach(["Albums", "Playlists", "Up next"], id: \.self) { t in
                    Button { go(t) } label: {
                        Text(t).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tab == t ? .black : .white.opacity(0.8))
                            .frame(maxWidth: .infinity).frame(height: 24)
                            .background { if tab == t { Capsule().fill(.white).matchedGeometryEffect(id: "tab", in: tabNS) } }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(.white.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
            // Profile: separate round glass button beside the tabs; white when open.
            Button { go(tab == "Profile" ? "Albums" : "Profile") } label: {
                Image(systemName: "person.fill").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(tab == "Profile" ? .white : .white.opacity(0.16), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                    .foregroundStyle(tab == "Profile" ? .black : .white)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Profile")
            }
            .transition(.blurReplace)
            }
            ZStack {
            Group {
            if tab == "Profile" { ScrollView { profile }.modifier(GlassScroller(autoHide: true)) } else {
            GeometryReader { g in
                // Tile sized so a 4×3 block (12 covers) fits the visible area exactly.
                let rows: CGFloat = p.tall ? 4 : 3
                let tile = min((g.size.width - 18 - 24) / 4, (g.size.height - 8 * (rows - 1)) / rows)
                ScrollView {
                    switch tab {
                    case "Albums": grid(p.albums, tile)
                    case "Playlists": grid(p.playlists, tile)
                    case "Context": contextList(listRowH(g.size.height))
                    default: upNext(listRowH(g.size.height))
                    }
                }
                .scrollPosition(id: $contextScroll, anchor: .top)
                .onChange(of: p.contextTracks.count) {   // list loaded: start at the song that's playing
                    contextScroll = p.contextTracks.firstIndex { $0.id == p.track?.id } ?? 0
                }
                .frame(height: listHeight(g.size.height, tile: tile, rows: rows))
                .padding(.trailing, 18)
                .modifier(GlassScroller())
                .padding(.top, tab == "Context" || tab == "Up next" ? listTop : 0)   // song lists start level with the grid; leftover (< 1 row) goes below
                .frame(width: g.size.width, height: g.size.height, alignment: tab == "Context" || tab == "Up next" ? .top : .bottom)
            }
            .padding(.bottom, 6)
            }
            }
            .id(tab)
            .transition(.push(from: forward ? .trailing : .leading))
            }
            .clipped()
        }
        .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 14)
    }

    // Header (avatar, name, followers, sign out), then a ranked list of top artists.
    var profile: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Art(url: p.me?.images?.first?.url) {
                    Image(systemName: "person.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.12))
                }
                .frame(width: 56, height: 56).clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.me?.display_name ?? "Spotify user").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    if let n = p.me?.followers?.total {
                        Text("\(n) follower\(n == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Button("Sign out") { p.signOut() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.16), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Top artists").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                if let note = p.topArtistsNote {
                    Text(note).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                ForEach(Array(p.topArtists.prefix(p.tall ? 3 : 2).enumerated()), id: \.offset) { i, a in   // what fits without scrolling
                    Button { p.play(a) } label: {
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(.system(size: 12, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.5)).frame(width: 14)
                            Art(url: a.art) { Color.white.opacity(0.1) }
                                .frame(width: 34, height: 34).clipShape(Circle())
                            Text(a.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 4).padding(.trailing, 12)
    }

    // Whole rows only, no half-cut row peeking at the bottom (song lists: see listRowH);
    // the album/playlist grid shows `rows` rows of tiles (3, or 4 at the tall size).
    let listTop: CGFloat = 12   // song lists start where the album grid starts under the tabs

    func listHeight(_ h: CGFloat, tile: CGFloat, rows: CGFloat) -> CGFloat {
        tab == "Context" || tab == "Up next" ? h - listTop : tile * rows + 8 * (rows - 1)
    }

    // Song lists fill the same area as the grid (top and bottom edges match) with a fixed 4pt gap:
    // the nearest whole number of ~36pt rows, each row stretched/squeezed a few points to fit exactly
    // (normal size: 5 rows of ~34pt, tall: 6 of ~38pt).
    func listRowH(_ h: CGFloat) -> CGFloat {
        let avail = h - listTop, n = max(1, ((avail + 4) / 40).rounded())
        return (avail - (n - 1) * 4) / n
    }

    // Mosaic: a 2×2 cover with four small ones beside it (side alternates), then plain rows of four; repeat.
    func grid(_ items: [Album], _ tile: CGFloat) -> some View {
        // Cycle fills the view exactly: big (2 rows) + 1 plain row, or + 2 plain rows when tall.
        let cycle = p.tall ? 3 : 2
        var blocks: [(big: Bool, left: Bool, items: ArraySlice<Album>)] = []
        var i = 0
        while i < items.count {
            let big = blocks.count % cycle == 0, n = big ? 5 : 4
            blocks.append((big, (blocks.count / cycle) % 2 == 0, items[i..<min(i + n, items.count)])); i += n
        }
        return LazyVStack(spacing: 8) {
            ForEach(blocks.indices, id: \.self) { b in
                let it = Array(blocks[b].items)
                if blocks[b].big {
                    HStack(spacing: 8) {
                        let big = album(it[0]).frame(width: tile * 2 + 8)
                        let small = VStack(spacing: 8) {
                            ForEach(0..<2) { r in
                                HStack(spacing: 8) {
                                    ForEach(0..<2) { c in
                                        let j = 1 + r * 2 + c
                                        if j < it.count { album(it[j]).frame(width: tile) } else { Color.clear.frame(width: tile, height: tile) }
                                    }
                                }
                            }
                        }
                        if blocks[b].left { big; small } else { small; big }
                    }
                } else {
                    HStack(spacing: 8) {
                        ForEach(0..<4) { c in
                            if c < it.count { album(it[c]).frame(width: tile) } else { Color.clear.frame(width: tile, height: tile) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Tracks of the album/playlist now playing (opened by tapping the title); current song highlighted.
    func contextList(_ rowH: CGFloat) -> some View {
        LazyVStack(spacing: 4) {
            if p.contextUnreadable, let uri = p.listURI {
                VStack(spacing: 10) {
                    let playlist = uri.contains(":playlist:")
                    Text(playlist ? "Spotify doesn't share this playlist's songs with this app, but it can still play it."
                                  : "Couldn't load this album's songs right now, but it can still play.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                    Button { p.play(Album(uri: uri, name: p.contextName, art: nil)) } label: {
                        Label(playlist ? "Play playlist" : "Play album", systemImage: "play.fill").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black).padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.white, in: Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 24).padding(.horizontal, 12)
            }
            ForEach(Array(p.contextTracks.enumerated()), id: \.offset) { _, t in
                Button { p.play(t, inContext: p.listURI) } label: {
                    row(t).padding(.horizontal, 8).frame(height: rowH)   // every row padded alike; current one gets a pill
                        .background(t.id == p.track?.id ? Color.white.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Play Now") { p.play(t, inContext: p.listURI) }
                }
            }
        }
        .scrollTargetLayout()
    }

    func upNext(_ rowH: CGFloat) -> some View {
        VStack(spacing: 4) {
            if p.queue.isEmpty {
                Text("Nothing queued").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            }
            ForEach(Array(p.queue.enumerated()), id: \.offset) { _, t in
                Button { p.skip(to: t) } label: { row(t).padding(.horizontal, 8).frame(height: rowH) }   // same rows as the album list
                    .buttonStyle(.plain)
            }
        }
    }

    func row(_ t: Track) -> some View {
        HStack(spacing: 10) {
            Art(url: t.art) { Color.white.opacity(0.1) }
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
        // Albums and playlists open their song list; pick a song there to play it in that album/playlist.
        Button { withAnimation(.smooth(duration: 0.4)) { p.openContext(a.uri, name: a.name) } } label: {
            Color.clear.aspectRatio(1, contentMode: .fit)   // square tile: whole cover visible
                .overlay { Art(url: a.art) { Color.white.opacity(0.1) } }
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
    @State private var manual = false      // user is reading by scrolling: all lines sharp, no auto-follow
    @State private var idle: Task<Void, Never>?

    var body: some View {
        if p.lyrics.isEmpty {
            Text("No lyrics for this song").font(.system(size: 18, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { lyrics }
    }

    var lyrics: some View {
        let cur = p.line ?? -1
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(p.lyrics.enumerated()), id: \.offset) { i, l in
                        Text(l.text)
                            .font(.system(size: i == cur ? 22 : 18, weight: .bold))
                            .foregroundStyle(.white.opacity(i == cur ? 1 : i < cur ? 0.3 : 0.5))
                            .blur(radius: manual ? 0 : min(4, max(0, Double(abs(i - cur)) - 2) * 1.5))   // soften lines far from the current one
                            .animation(.smooth(duration: 0.4), value: manual)
                            .id(i)
                            .onTapGesture { p.seek(to: l.time) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 100)
            }
            .modifier(GlassScroller(autoHide: true))
            .onAppear { proxy.scrollTo(cur, anchor: .center) }
            .onChange(of: cur) { if !manual { withAnimation(.smooth) { proxy.scrollTo(cur, anchor: .center) } } }
            // Manual scroll: go sharp; 3s after the user stops, blur back and return to the current line.
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { idle?.cancel(); manual = true }
                if phase == .idle && manual {
                    idle = Task {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        manual = false
                        withAnimation(.smooth) { proxy.scrollTo(p.line ?? -1, anchor: .center) }
                    }
                }
            }
        }
        .padding(.leading, 22).padding(.trailing, 14)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                     .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        // Darken the top and bottom edges of the screen behind the faded lines.
        .background(LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.25),
                                           .init(color: .clear, location: 0.75), .init(color: .black.opacity(0.45), location: 1)],
                                   startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
    }
}

// Thin glass scroll thumb, same capsule look as the tabs; replaces the system scroller. Hidden when nothing scrolls.
struct GlassScroller: ViewModifier {
    var autoHide = false                          // only visible while scrolling
    @State private var s: [CGFloat] = [0, 0, 0]   // offset, content, visible height
    @State private var active = false

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: [CGFloat].self) { [$0.contentOffset.y, $0.contentSize.height, $0.containerSize.height] } action: { s = $1 }
            .onScrollPhaseChange { _, phase in
                withAnimation(phase == .idle || phase == .animating ? .smooth(duration: 0.6).delay(0.8) : .smooth(duration: 0.2)) { active = phase == .interacting || phase == .decelerating }   // not on auto-follow scrolls
            }
            .overlay(alignment: .topTrailing) {
                let (y, total, box) = (s[0], s[1], s[2])
                if total > box + 1 {
                    let thumb = max(30, box * box / total)
                    let top = (box - thumb) * min(1, max(0, y / (total - box)))
                    Capsule().fill(.white.opacity(0.16))
                        .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 6)
                        .overlay(alignment: .top) {
                            Capsule().fill(.white.opacity(0.7)).frame(width: 4, height: thumb).offset(y: top)
                        }
                        .frame(height: box)
                        .opacity(!autoHide || active ? 1 : 0)
                }
            }
    }
}

// Cover image with an in-memory cache. The fold draws extra copies of each screen; AsyncImage would
// reload in every copy and flash the placeholder, this shows a cached image on the first frame.
@MainActor let artCache = NSCache<NSURL, NSImage>()
struct Art<P: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: P
    @State private var loaded: NSImage?

    var body: some View {
        let img = loaded ?? url.flatMap { artCache.object(forKey: $0 as NSURL) }
        ZStack {   // fresh downloads blur in; cached images appear instantly (no transition, no flicker in fold copies)
            if let img { Image(nsImage: img).resizable().scaledToFill().transition(.blurReplace) } else { placeholder.transition(.opacity) }
        }
        .task(id: url) {
            guard let url, artCache.object(forKey: url as NSURL) == nil,
                  let (data, _) = try? await URLSession.shared.data(from: url), let i = NSImage(data: data) else { return }
            artCache.setObject(i, forKey: url as NSURL)
            withAnimation(.smooth(duration: 0.6)) { loaded = i }
        }
    }
}

// Boot splash on the cover, like an iPhone starting up: black, the Apple logo fades in,
// then a ripple opens from the center and reveals the player.
struct Splash: View {
    let done: () -> Void
    @State private var logo = false
    @State private var ripple: CGFloat = 0   // 0 closed … 1 fully open

    var body: some View {
        let d = hypot(screenW, screenH) * 2.2 * ripple   // hole diameter; grows from the bottom-left corner
        ZStack {
            Color.black
            Image(systemName: "apple.logo").font(.system(size: 54)).foregroundStyle(.white)
                .opacity(logo ? 1 : 0).blur(radius: logo ? 0 : 8).scaleEffect(logo ? 1 : 0.92)
        }
        .mask {
            Rectangle().overlay(Circle().frame(width: d, height: d).blur(radius: 12).blendMode(.destinationOut)
                .position(x: 0, y: screenH))
                .compositingGroup()
        }
        .overlay {
            Circle().stroke(.white.opacity(0.5 * (1 - ripple)), lineWidth: 2).frame(width: d, height: d).blur(radius: 1.5)
                .position(x: 0, y: screenH)
        }
        .allowsHitTesting(ripple < 0.5)
        .task {
            try? await Task.sleep(for: .seconds(0.3))
            withAnimation(.easeOut(duration: 0.9)) { logo = true }
            try? await Task.sleep(for: .seconds(1.9))
            withAnimation(.easeOut(duration: 0.35)) { logo = false }
            withAnimation(.timingCurve(0.5, 0, 0.2, 1, duration: 1.1)) { ripple = 1 }
            try? await Task.sleep(for: .seconds(1.15))
            done()
        }
    }
}

let spotifyGreen = Color(red: 0.114, green: 0.725, blue: 0.329)   // #1DB954

// Spotify icon from its official SVG path (24×24 viewBox), scaled to the frame.
struct SpotifyLogo: Shape {
    static let d = "M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12 12-5.4 12-12S18.66 0 12 0zm5.521 17.34c-.24.359-.66.48-1.021.24-2.82-1.74-6.36-2.101-10.561-1.141-.418.122-.779-.179-.899-.539-.12-.421.18-.78.54-.9 4.56-1.021 8.52-.6 11.64 1.32.42.18.479.659.301 1.02zm1.44-3.3c-.301.42-.841.6-1.262.3-3.239-1.98-8.159-2.58-11.939-1.38-.479.12-1.02-.12-1.14-.6-.12-.48.12-1.021.6-1.141C9.6 9.9 15 10.561 18.72 12.84c.361.181.54.78.241 1.2zm.12-3.36C15.24 8.4 8.82 8.16 5.16 9.301c-.6.179-1.2-.181-1.38-.721-.18-.601.18-1.2.72-1.381 4.26-1.26 11.28-1.02 15.721 1.621.539.3.719 1.02.419 1.56-.299.421-1.02.599-1.559.3z"
    static let path = svgPath(d)

    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 24
        return Self.path.applying(CGAffineTransform(scaleX: k, y: k).translatedBy(x: rect.minX / k, y: rect.minY / k))
    }
}

/// Minimal SVG path parser: M m C c S s L l H h V v Z z (all this icon needs).
/// ponytail: no arcs (A) or quadratics (Q/T); add them if another icon needs them.
func svgPath(_ d: String) -> Path {
    var nums: [Double] = [], cmds: [(Character, [Double])] = []
    var i = d.startIndex
    func flushNum(_ t: inout String) { if let v = Double(t) { nums.append(v) }; t = "" }
    var tok = ""
    var cmd: Character?
    while i < d.endIndex {
        let c = d[i]
        if c.isLetter && c != "e" {
            flushNum(&tok); if let cmd { cmds.append((cmd, nums)) }; nums = []; cmd = c
        } else if c == "-" && !tok.isEmpty && tok.last != "e" {
            flushNum(&tok); tok = "-"
        } else if c == "." && tok.contains(".") {
            flushNum(&tok); tok = "."
        } else if c == " " || c == "," {
            flushNum(&tok)
        } else { tok.append(c) }
        i = d.index(after: i)
    }
    flushNum(&tok); if let cmd { cmds.append((cmd, nums)) }

    var p = Path(), cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint?
    for (c, a) in cmds {
        let rel = c.isLowercase
        func pt(_ j: Int) -> CGPoint { CGPoint(x: a[j] + (rel ? cur.x : 0), y: a[j + 1] + (rel ? cur.y : 0)) }
        switch c.uppercased().first! {
        case "M":
            for j in stride(from: 0, to: a.count, by: 2) {
                let q = pt(j); if j == 0 { p.move(to: q); start = q } else { p.addLine(to: q) }; cur = q
            }
            lastCtrl = nil
        case "L":
            for j in stride(from: 0, to: a.count, by: 2) { cur = pt(j); p.addLine(to: cur) }
            lastCtrl = nil
        case "H": for v in a { cur.x = v + (rel ? cur.x : 0); p.addLine(to: cur) }; lastCtrl = nil
        case "V": for v in a { cur.y = v + (rel ? cur.y : 0); p.addLine(to: cur) }; lastCtrl = nil
        case "C":
            for j in stride(from: 0, to: a.count, by: 6) {
                let c1 = pt(j), c2 = pt(j + 2), e = pt(j + 4)
                p.addCurve(to: e, control1: c1, control2: c2); lastCtrl = c2; cur = e
            }
        case "S":
            for j in stride(from: 0, to: a.count, by: 4) {
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(j), e = pt(j + 2)
                p.addCurve(to: e, control1: c1, control2: c2); lastCtrl = c2; cur = e
            }
        case "Z": p.closeSubpath(); cur = start; lastCtrl = nil
        default: break
        }
    }
    return p
}

// Sign-in success: black ripple sweeps in from the bottom-left corner, covers the load,
// then fades away once the player has something to show (or after 0.6s).
struct LoginRipple: View {
    let trigger: Int
    let ready: Bool
    @State private var grow: CGFloat = 0
    @State private var shown = false

    var body: some View {
        let d = hypot(screenW, screenH) * 2.2 * grow
        ZStack {
            Circle().fill(.black).frame(width: d, height: d).position(x: 0, y: screenH)
            Circle().stroke(.white.opacity(0.35 * (1 - grow)), lineWidth: 2).frame(width: d, height: d).position(x: 0, y: screenH)
        }
        .frame(width: screenW, height: screenH)
        .opacity(shown ? 1 : 0).blur(radius: shown ? 0 : 14)
        .onChange(of: trigger) { play() }   // only on a new login; .task would replay whenever the view is rebuilt (resize)
    }

    func play() {
        Task {
            grow = 0; shown = true
            withAnimation(.timingCurve(0.5, 0, 0.2, 1, duration: 0.9)) { grow = 1 }
            try? await Task.sleep(for: .seconds(0.9))
            for _ in 0..<6 where !ready { try? await Task.sleep(for: .seconds(0.1)) }   // wait at most 0.6s for the song
            withAnimation(.easeOut(duration: 0.35)) { shown = false }
        }
    }
}
