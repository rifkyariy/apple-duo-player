import SwiftUI
import AVFoundation

// Front camera, mirrored on the left screen (tall size's camera button), like the Duo's inner selfie view.
// One shared capture session; it runs only while a camera screen is on screen. The fold animation draws
// extra copies of the left screen, so views count themselves in and out and the last one out stops it.
@MainActor @Observable final class Camera {
    static let shared = Camera()
    enum State { case idle, starting, running, denied, unavailable }
    private(set) var state = State.idle

    // ponytail: every session change (setup, start, stop, preview layers) happens on the main thread. Starting it on a
    // background queue crashed ("collection mutated while enumerated") when a preview layer attached at the same moment,
    // e.g. right after the permission prompt. Costs a short hitch when the camera opens; a serial queue for all of it if that bites.
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var configured = false
    private var viewers = 0

    func viewerAppeared() {
        viewers += 1
        if viewers == 1 { Task { await start() } }
    }

    func viewerLeft() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        session.stopRunning()
        if state == .running || state == .starting { state = .idle }
    }

    private func start() async {
        state = .starting
        guard await AVCaptureDevice.requestAccess(for: .video) else { state = .denied; return }
        if !configured {
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video)   // Macs without a "front" one: whatever camera exists
            guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                state = .unavailable; return
            }
            session.beginConfiguration()
            session.sessionPreset = .high
            session.addInput(input)
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            session.commitConfiguration()
            configured = true
        }
        guard viewers > 0 else { state = .idle; return }   // left again while asking for permission
        session.startRunning()
        state = .running
    }
}

extension Camera {
    /// Takes one photo, mirrored like the preview (what you saw is what you get). The flip and downscale happen once,
    /// off the main thread, into a plain bitmap: drawing a full-size, lazily flipped photo on every render froze the UI.
    func capture() async -> NSImage? {
        guard state == .running else { return nil }
        let cg: CGImage? = await withCheckedContinuation { c in
            let d = PhotoDelegate { c.resume(returning: $0) }
            photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: d)
            PhotoDelegate.inFlight = d   // the output doesn't retain its delegate
        }
        return cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    nonisolated(unsafe) static var inFlight: PhotoDelegate?
    let done: (CGImage?) -> Void
    init(done: @escaping (CGImage?) -> Void) { self.done = done }
    func photoOutput(_ o: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        done(photo.fileDataRepresentation().flatMap(Self.mirroredThumbnail))
        PhotoDelegate.inFlight = nil
    }

    // Max 1600 px on the long side (the print's photo is 1080 px at most), flipped left-right.
    static func mirroredThumbnail(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        ctx.translateBy(x: CGFloat(img.width), y: 0); ctx.scaleBy(x: -1, y: 1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }
}

struct CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: Camera.shared.session)
        layer.videoGravity = .resizeAspectFill
        if let c = layer.connection, c.isVideoMirroringSupported {   // a mirror, like every selfie camera
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        v.layer = layer
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

// The whole left screen: live camera edge to edge, a back button, and a message if it can't run.
// Shutter → 3-2-1 → flash → a booth print of the photo with the song (or album) playing, then Retake / Save / Copy.
struct CameraScreen: View {
    let p: Player
    private var cam: Camera { Camera.shared }
    @State private var count: Int?          // countdown number on screen
    @State private var flash = false
    @State private var photo: NSImage?      // taken: showing the print
    @State private var albumMode = false    // print the album instead of the song
    @State private var lyric: String?       // the line sung when the shutter fired
    @State private var shotTrack: Track?    // the song playing then (the print keeps it after the song changes)
    @State private var showLyric = true     // print it over the photo
    @State private var lyricStyle = LyricStyle.selected
    @State private var art: NSImage?        // cover for the print's caption
    @State private var note: String?        // "Saved to Downloads" / "Copied"
    @State private var frames: [NSImage] = []   // the print in each lyric style, as swiped through
    @State private var drag: CGFloat = 0
    @Namespace private var tabs

    var body: some View {
        ZStack {
            // The print lies on a dark surface so its shadow reads (on pure black it vanished).
            if photo != nil { RadialGradient(colors: [Color(white: 0.24), Color(white: 0.1)], center: .center, startRadius: 10, endRadius: 260) }
            else { Color.black }
            if let photo {
                result(photo).transition(.blurReplace)
            } else {
                switch cam.state {
                case .denied:
                    message("Camera access is off", "Allow Duo Player in System Settings → Privacy & Security → Camera.", button: "Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                case .unavailable:
                    message("No camera found", "Connect a camera, or close another app that's using it.", button: nil) {}
                default:
                    CameraPreview().opacity(cam.state == .running ? 1 : 0)
                        .animation(.smooth(duration: 0.5), value: cam.state == .running)
                    if cam.state == .starting { ProgressView().controlSize(.small).tint(.white) }
                    if let count {
                        Text("\(count)").font(.system(size: 88, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 12).id(count).transition(.scale(scale: 1.6).combined(with: .opacity))
                    }
                    VStack(spacing: 12) {
                        // Live line, frozen on the held one once the shutter is pressed (the countdown shows what you'll get).
                        if let line = count != nil ? lyric : p.lyricNow {
                            Text(line).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                .multilineTextAlignment(.center).lineLimit(2)
                                .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
                                .padding(.horizontal, 18).id(line).transition(.blurReplace)
                        }
                        shutter
                    }
                    .animation(.smooth(duration: 0.4), value: count != nil ? lyric : p.lyricNow)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 16)
                }
            }
            Color.white.opacity(flash ? 1 : 0).allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            Button { withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { p.tab = p.contextBack } } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.35), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.5))
                    .foregroundStyle(.white).contentShape(Circle())
            }
            .buttonStyle(.plain).help("Back").padding(14)
        }
        .onAppear { cam.viewerAppeared() }
        .onDisappear { cam.viewerLeft() }
    }

    var shutter: some View {
        Button { Task { await shoot() } } label: {
            Circle().fill(.white).frame(width: 36, height: 36)
                .padding(3).overlay(Circle().stroke(.white, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(cam.state != .running || count != nil)
        .opacity(cam.state == .running && count == nil ? 1 : 0.4)
        .keyboardShortcut(.return, modifiers: [])
        .help("Take photo")
    }

    func shoot() async {
        lyric = p.lyricNow; showLyric = true   // held from the click, not from the flash 3 s later
        shotTrack = p.track
        for n in [3, 2, 1] {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { count = n }
            try? await Task.sleep(for: .seconds(0.8))
        }
        // Real flash timing: the LED pre-flashes, then fires the main burst; the photo is taken on the main burst.
        withAnimation(.easeOut(duration: 0.1)) { count = nil }
        p.flashTick += 1
        try? await Task.sleep(for: .seconds(FlashLED.preToMain))
        withAnimation(.linear(duration: 0.02)) { flash = true }   // screen flash with the main burst: instant on
        async let shot = cam.capture()
        if let url = shotTrack?.art { art = await loadImage(url) }
        withAnimation(.easeOut(duration: 0.35)) { flash = false }
        let taken = await shot
        try? await Task.sleep(for: .seconds(0.45))   // let the flash finish fading before the result takes over
        withAnimation(.smooth(duration: 0.5)) { photo = taken }
    }

    var booth: BoothPrint? {
        photo.map { BoothPrint(photo: $0, title: albumMode ? (shotTrack?.album ?? "") : (shotTrack?.title ?? "Nothing playing"),
                               subtitle: shotTrack?.artist ?? "", label: albumMode ? "NOW PLAYING FROM" : "NOW PLAYING", art: art,
                               lyric: showLyric ? lyric : nil, style: lyricStyle) }
    }

    func result(_ photo: NSImage) -> some View {
        VStack(spacing: 10) {
            // Top bar, beside the back button: Song | Album tabs, and a round lyrics toggle (the library's glass style).
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach([false, true], id: \.self) { album in
                        Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { albumMode = album } } label: {
                            Text(album ? "Album" : "Song").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(albumMode == album ? .black : .white.opacity(0.8))
                                .frame(maxWidth: .infinity).frame(height: 24)
                                .background { if albumMode == album { Capsule().fill(.white).matchedGeometryEffect(id: "pill", in: tabs) } }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(.white.opacity(0.16), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
                if lyric != nil {
                    Button { withAnimation(.smooth(duration: 0.25)) { showLyric.toggle() } } label: {
                        Image(systemName: "quote.bubble").font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(showLyric ? .white : .white.opacity(0.16), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                            .foregroundStyle(showLyric ? .black : .white)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(showLyric ? "Hide lyrics on the photo" : "Show lyrics on the photo")
                }
            }
            .padding(.leading, 38)   // clear of the back button
            carousel
                .task(id: "\(albumMode)\(showLyric)\(art != nil)") {
                    // Every style pre-rendered so swiping never waits, but gently: 2× previews (3× only for Save/Copy),
                    // after the result's entrance, one per step with a pause, so animations keep running.
                    try? await Task.sleep(for: .seconds(frames.isEmpty ? 0.55 : 0))
                    var out: [NSImage] = []
                    for st in showLyric && lyric != nil ? LyricStyle.allCases : [lyricStyle] {
                        guard !Task.isCancelled else { return }
                        if let img = render(st, scale: 2) { out.append(img) }
                        try? await Task.sleep(for: .seconds(0.03))
                    }
                    withAnimation(.smooth(duration: 0.3)) { frames = out }
                }
            HStack(spacing: 6) {
                action("Retake", "arrow.counterclockwise") { withAnimation(.smooth(duration: 0.4)) { self.photo = nil } }
                action("Save", "arrow.down.to.line") {
                    if let url = save() { show("Saved to Downloads"); NSWorkspace.shared.activateFileViewerSelecting([url]) } else { show("Couldn't save") }
                }
                action("Copy", "doc.on.doc") { show(copy() ? "Copied" : "Couldn't copy") }
            }
            .overlay(alignment: .top) {
                if let note { Text(note).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).offset(y: -18).transition(.opacity) }
            }
        }
        .padding(.top, 14).padding(.horizontal, 14).padding(.bottom, 12)
    }

    // Swipe the print sideways to change the lyric style (Instagram-filter style): it follows the drag, snaps to
    // the nearest frame, and the dots + name underneath say which one. Clicking a dot jumps there.
    var carousel: some View {
        let styles = LyricStyle.allCases, swipeable = frames.count > 1
        let index = styles.firstIndex(of: lyricStyle) ?? 0
        return VStack(spacing: 7) {
            GeometryReader { g in
              ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { _, img in
                        Image(nsImage: img).resizable().scaledToFit()
                            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)    // contact: the paper's edge on the surface
                            .shadow(color: .black.opacity(0.55), radius: 16, y: 10)   // cast: soft, below, like a print on a table
                            .frame(width: g.size.width, height: g.size.height)
                    }
                }
                .offset(x: -CGFloat(swipeable ? index : 0) * g.size.width + drag)
                // The off-screen frames reach over the right screen: clipping only hides them, so they take no clicks;
                // a fixed layer the size of the visible box catches the swipe instead.
                .allowsHitTesting(false)
                Color.clear.frame(width: g.size.width, height: g.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 6)
                    .onChanged { v in
                        guard swipeable else { return }
                        let edge = (index == 0 && v.translation.width > 0) || (index == styles.count - 1 && v.translation.width < 0)
                        drag = edge ? v.translation.width / 3 : v.translation.width   // rubber band past the ends
                    }
                    .onEnded { v in
                        var i = index
                        if swipeable && v.predictedEndTranslation.width < -g.size.width / 4 { i = min(i + 1, styles.count - 1) }
                        if swipeable && v.predictedEndTranslation.width > g.size.width / 4 { i = max(i - 1, 0) }
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { lyricStyle = styles[i]; drag = 0 }
                    })
              }
            }
            .clipped()
            // Dragging the window's background moves the window: pause that over the print so the drag swipes instead.
            .onHover { h in NSApp.windows.first { $0 is KeyPanel }?.isMovableByWindowBackground = !h }
            .onDisappear { NSApp.windows.first { $0 is KeyPanel }?.isMovableByWindowBackground = true }
            if swipeable {
                HStack(spacing: 6) {
                    ForEach(styles.indices, id: \.self) { i in
                        Circle().fill(.white.opacity(i == index ? 0.95 : 0.3)).frame(width: 6, height: 6)
                            .padding(3).contentShape(Circle())
                            .onTapGesture { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { lyricStyle = styles[i] } }
                    }
                }
                Text(lyricStyle.rawValue).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.opacity).animation(.smooth, value: lyricStyle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func action(_ title: String, _ icon: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(.white.opacity(0.16), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    func show(_ text: String) {
        withAnimation(.smooth(duration: 0.2)) { note = text }
        Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation(.smooth(duration: 0.4)) { if note == text { note = nil } } }
    }

    // Full-resolution PNG of the print (3×: 1080×1350 px). No 3D effects in the print, so it stays sharp.
    var png: Data? { png(lyricStyle) }

    func render(_ style: LyricStyle, scale: CGFloat) -> NSImage? {
        guard var booth else { return nil }
        booth.style = style
        let r = ImageRenderer(content: booth)
        r.scale = scale
        return r.cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    func png(_ style: LyricStyle) -> Data? {
        guard var booth else { return nil }
        booth.style = style
        let r = ImageRenderer(content: booth)
        r.scale = 3
        return r.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    func save() -> URL? {
        guard let png else { return nil }
        let name = "Duo Booth \(Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())).png"
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let url = URL.downloadsDirectory.appending(path: name)
        return (try? png.write(to: url)) != nil ? url : nil
    }

    func copy() -> Bool {
        guard let png else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setData(png, forType: .png)
    }

    func loadImage(_ url: URL) async -> NSImage? {
        if let hit = artCache.object(forKey: url as NSURL) { return hit }
        guard let (d, _) = try? await URLSession.shared.data(from: url), let i = NSImage(data: d) else { return nil }
        artCache.setObject(i, forKey: url as NSURL)
        return i
    }

    func message(_ title: String, _ body: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash").font(.system(size: 26)).foregroundStyle(.white.opacity(0.7))
            Text(title).font(.system(size: 14, weight: .bold))
            Text(body).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            if let button {
                Button(button, action: action).buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white.opacity(0.16), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
            }
        }
        .foregroundStyle(.white).padding(24)
    }
}

struct SelectionRenderer: TextRenderer {
    let color: Color

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let lines = layout.map(\.typographicBounds.rect)
        for r in lines { ctx.fill(Path(r.insetBy(dx: -2, dy: -1)), with: .color(color.opacity(0.42))) }
        for line in layout { ctx.draw(line) }
        guard let first = lines.first, let last = lines.last else { return }
        let bar: CGFloat = 2.5, dot: CGFloat = 9
        // start: bar down the first letter, dot on top; end: bar after the last word, dot below
        ctx.fill(Path(CGRect(x: first.minX - 2 - bar / 2, y: first.minY - 1, width: bar, height: first.height + 2)), with: .color(color))
        ctx.fill(Path(ellipseIn: CGRect(x: first.minX - 2 - dot / 2, y: first.minY - 1 - dot + 1, width: dot, height: dot)), with: .color(color))
        ctx.fill(Path(CGRect(x: last.maxX + 2 - bar / 2, y: last.minY - 1, width: bar, height: last.height + 2)), with: .color(color))
        ctx.fill(Path(ellipseIn: CGRect(x: last.maxX + 2 - dot / 2, y: last.maxY + 1 - 1, width: dot, height: dot)), with: .color(color))
    }
}

enum LyricStyle: String, CaseIterable { case selected = "Selected", marker = "Marker", poem = "Poem" }

// A photo booth print: white paper, the photo, and a caption strip with the song (or album) playing and the date.
struct BoothPrint: View {
    let photo: NSImage, title: String, subtitle: String, label: String, art: NSImage?
    var lyric: String? = nil   // printed over the bottom of the photo
    var style = LyricStyle.selected
    var date = Date()

    // iPhone text selection: translucent blue highlight behind each line, grab handles at the first letter and
    // right after the last word. Drawn by a TextRenderer, which knows where each wrapped line actually sits.
    func selectedArt(_ line: String) -> some View {
        Text(line)
            .font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
            .lineSpacing(5).lineLimit(3).minimumScaleFactor(0.7)
            .textRenderer(SelectionRenderer(color: Color(red: 0.04, green: 0.52, blue: 1)))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.bottom, 28).padding(.top, 60)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom))
    }

    // Highlighter: black bold text on a fluorescent green marker swipe, a little crooked, like a line marked in a notebook.
    func markerArt(_ line: String) -> some View {
        var a = AttributedString(" \(line) ")
        a.backgroundColor = Color(red: 0.55, green: 1, blue: 0.35).opacity(0.9)
        return Text(a)
            .font(.system(size: 21, weight: .heavy)).foregroundStyle(.black.opacity(0.88))
            .lineSpacing(5).lineLimit(3).minimumScaleFactor(0.7)
            .rotationEffect(.degrees(-2.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.bottom, 26).padding(.top, 50)
    }

    // The line as a poem fragment: italic serif, a soft glow, a big faded quote mark behind, and a small credit.
    func lyricArt(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(line)
                .font(.system(size: 23, weight: .medium, design: .serif)).italic()
                .tracking(-0.3).lineSpacing(1)
                .foregroundStyle(.white)
                .lineLimit(3).minimumScaleFactor(0.65)
                .shadow(color: .white.opacity(0.35), radius: 8)   // glow
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            HStack(spacing: 6) {
                Rectangle().fill(.white.opacity(0.7)).frame(width: 14, height: 1)
                Text(title.uppercased()).font(.system(size: 6.5, weight: .semibold)).tracking(1.8).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            Text("“").font(.system(size: 110, weight: .bold, design: .serif))
                .foregroundStyle(.white.opacity(0.22)).offset(x: -10, y: -58)
        }
        .padding(.horizontal, 22).padding(.bottom, 20).padding(.top, 70)
        .background(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.25), location: 0.4),
                                           .init(color: .black.opacity(0.65), location: 1)], startPoint: .top, endPoint: .bottom))
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { Image(nsImage: photo).resizable().scaledToFill() }
                .clipped()
                .overlay(alignment: .bottom) {
                    if let lyric {
                        switch style {
                        case .selected: selectedArt(lyric)
                        case .marker: markerArt(lyric)
                        case .poem: lyricArt(lyric)
                        }
                    }
                }
                .clipped()   // glow stays on the photo, never on the paper
            HStack(spacing: 12) {
                Group {
                    if let art { Image(nsImage: art).resizable().scaledToFill() } else { Color.black.opacity(0.08) }
                }
                .frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 9, weight: .bold)).tracking(1.6).foregroundStyle(.black.opacity(0.45))
                    Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(.black.opacity(0.88)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.black.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            HStack {
                HStack(spacing: 4) {   // Spotify's full logo: the mark and the wordmark
                    SpotifyLogo().fill(spotifyGreen).frame(width: 13, height: 13)
                    Text("Spotify").font(.system(size: 11, weight: .bold)).tracking(-0.3).foregroundStyle(.black.opacity(0.85))
                }
                Spacer()
                Text(date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())).font(.system(size: 9).monospacedDigit())
            }
            .foregroundStyle(.black.opacity(0.35)).padding(.top, 12)
        }
        .padding(18)
        .frame(width: 360)
        .background(Color(red: 0.98, green: 0.975, blue: 0.965))   // booth paper, a touch warm
    }
}
