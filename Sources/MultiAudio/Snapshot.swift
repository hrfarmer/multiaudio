import AppKit
import SwiftUI

/// Debug aid: `MultiAudio --snapshot out.png [--dark]` renders the menu popover offscreen.
enum Snapshot {
    @MainActor
    static func runIfRequested(model: AppModel) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        let dark = args.contains("--dark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if args.contains("--demo-state") {
                // Visual only: flip flags without touching the audio router.
                if !model.localItems.isEmpty { model.localItems[model.localItems.count - 1].enabled = true }
                if model.airplayItems.count > 0 { model.airplayItems[0].enabled = true; model.airplayItems[0].status = .playing }
                if model.airplayItems.count > 2 {
                    model.airplayItems[2].enabled = true
                    model.airplayItems[2].status = .failed("Pairing failed: device requires a PIN")
                }
            }
            let view = MenuView().environmentObject(model)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = host.appearance
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                exit(0)
            }
        }
    }
}
