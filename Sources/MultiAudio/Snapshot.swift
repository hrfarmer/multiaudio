import AppKit
import ScreenCaptureKit
import SwiftUI

/// Debug aids for UI work:
///   MultiAudio --open-panel [--demo-state] [--show-settings]
/// opens the panel at launch and writes its on-screen rect to /tmp/multiaudio-panel-rect.txt
/// (x,y,w,h in top-left screen coordinates, for `screencapture -R`).
/// `--demo-state` flips row flags visually only — no audio is routed.
@MainActor
enum DebugLaunch {
    static var isDebugLaunch: Bool {
        let a = CommandLine.arguments
        return a.contains("--open-panel") || a.contains("--write-icon-rect") || a.contains("--toggle-test")
    }

    static func runIfRequested(model: AppModel, controller: StatusItemController) {
        let args = CommandLine.arguments
        if args.contains("--toggle-test") {
            // Replays what a real icon click does while open: the outside-click monitor
            // closes first, then the icon's action runs — the panel must stay closed.
            func step(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
            func report(_ label: String) { log.notice("toggle-test \(label, privacy: .public): visible=\(controller.isOpen)") }
            step(1.0) { controller.toggle(); report("1 open") }
            step(2.0) { controller.close(); controller.toggle(); report("2 auto-close + icon click") }
            step(2.6) { report("2b after close animation") }
            step(3.5) { controller.toggle(); report("3 icon click reopens") }
            step(4.5) { controller.toggle(); report("4 icon click closes") }
            step(5.1) { report("4b settled") }
        }
        guard args.contains("--open-panel") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if args.contains("--demo-state") {
                if !model.localItems.isEmpty { model.localItems[model.localItems.count - 1].enabled = true }
                if model.airplayItems.count > 0 { model.airplayItems[0].enabled = true; model.airplayItems[0].status = .playing }
                if model.airplayItems.count > 2 {
                    model.airplayItems[2].enabled = true
                    model.airplayItems[2].status = .failed("Pairing failed: device requires a PIN")
                }
            }
            if args.contains("--show-settings") { model.showSettings = true }
            controller.open()
            if args.contains("--stress") {
                // Visual-only: expand/collapse rows, toggle settings, close/reopen.
                var t = 0.8
                func at(_ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f); t += 0.45 }
                for round in 0..<3 {
                    for i in model.localItems.indices { at { withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { model.localItems[i].enabled.toggle() } } }
                    for i in model.airplayItems.indices { at { withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { model.airplayItems[i].enabled.toggle() } } }
                    at { withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { model.showSettings.toggle() } }
                    at { controller.close() }
                    at { controller.open() }
                    at { try? "round \(round + 1)".write(toFile: "/tmp/multiaudio-toggle.txt", atomically: true, encoding: .utf8) }
                }
            }
            if args.contains("--toggle-settings") {
                // Reproduces clicking the gear button a few times.
                for (k, delay) in [1.0, 2.0, 3.0, 4.0].enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { model.showSettings.toggle() }
                        try? "toggled \(k + 1)".write(toFile: "/tmp/multiaudio-toggle.txt", atomically: true, encoding: .utf8)
                    }
                }
            }
            let at = args.firstIndex(of: "--capture-at").flatMap { Double(args[$0 + 1]) } ?? 1000
            DispatchQueue.main.asyncAfter(deadline: .now() + at / 1000) {
                let r = controller.contentScreenRect
                let screenH = NSScreen.screens.first?.frame.height ?? 0
                let s = "\(Int(r.minX)),\(Int(screenH - r.maxY)),\(Int(r.width)),\(Int(r.height))"
                try? s.write(toFile: "/tmp/multiaudio-panel-rect.txt", atomically: true, encoding: .utf8)
                if let i = args.firstIndex(of: "--capture"), i + 1 < args.count {
                    capture(rect: r.insetBy(dx: -40, dy: -40), screenHeight: screenH, to: args[i + 1])
                }
            }
        }
    }

    /// Screenshots a screen region (including the glass panel) with ScreenCaptureKit.
    /// Requires Screen Recording permission for MultiAudio; debug use only.
    static func capture(rect: NSRect, screenHeight: CGFloat, to path: String) {
        let flipped = CGRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height)
        Task {
            do {
                let image = try await SCScreenshotManager.captureImage(in: flipped)
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                try? "ok".write(toFile: path + ".status", atomically: true, encoding: .utf8)
            } catch {
                try? "\(error)".write(toFile: path + ".status", atomically: true, encoding: .utf8)
            }
        }
    }
}
