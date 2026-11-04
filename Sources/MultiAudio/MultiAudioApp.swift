import AppKit
import SwiftUI

@main
struct MultiAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // The UI lives in a status-item panel (see StatusItemController).
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        let controller = StatusItemController(model: model)
        self.model = model
        self.controller = controller
        DebugLaunch.runIfRequested(model: model, controller: controller)
        // Let the status item appear first, then bring back saved outputs.
        // (Debug UI launches never re-enable outputs, so tests don't route real audio.)
        if !DebugLaunch.isDebugLaunch { DispatchQueue.main.async { model.beginRestoring() } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}
