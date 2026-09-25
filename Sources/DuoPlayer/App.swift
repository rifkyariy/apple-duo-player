import SwiftUI
import AppKit

let screenW: CGFloat = 300
let screenH: CGFloat = 280
let margin: CGFloat = 40

@main
struct DuoPlayerApp: App {
    @NSApplicationDelegateAdaptor var delegate: AppDelegate
    var body: some Scene { Settings { EmptyView() } }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: KeyPanel!

    func applicationDidFinishLaunching(_ note: Notification) {
        // ponytail: panel is always 2W wide; transparent left half passes clicks through, so no frame resizing on fold.
        let size = NSSize(width: screenW * 2 + margin * 2, height: screenH + margin * 2)
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.level = .floating
        panel.hidesOnDeactivate = false     // stay visible while using other apps
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PlayerView())
        if let f = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 20, y: f.maxY - size.height - 20))
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)   // show in the Dock and Cmd-Tab
        NSApp.activate()
    }
}
