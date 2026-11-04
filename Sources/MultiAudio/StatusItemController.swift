import AppKit
import Combine
import SwiftUI

/// Drives the open/close animation of the panel's SwiftUI content.
@MainActor
final class PanelPresentation: ObservableObject {
    @Published var isShown = false
}

/// Borderless, transparent panel: all visible chrome is Liquid Glass drawn by SwiftUI.
final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the menu-bar icon and the floating glass panel under it.
/// A custom panel (rather than MenuBarExtra) lets us animate both opening and closing.
@MainActor
final class StatusItemController: NSObject {
    /// Transparent margin around the content so glass shadows aren't clipped.
    static let margin: CGFloat = 24
    static let contentWidth: CGFloat = 330
    /// Gap between the menu bar and the top of the content.
    static let gap: CGFloat = 6

    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: GlassPanel
    private let presentation = PanelPresentation()
    private var contentHeight: CGFloat = 300
    private var monitors: [Any] = []
    private var shrinkWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var closing = false

    var isOpen: Bool { panel.isVisible && !closing }

    init(model: AppModel) {
        self.model = model
        panel = GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: true)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the glass draws its own
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let root = PanelRoot(presentation: presentation) { [weak self] size in
            self?.contentSizeChanged(size)
        }
        .environmentObject(model)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        // Don't make the hosting view the window's contentView: then SwiftUI resizes the
        // window itself on every animation frame, fighting our top-anchored layout until
        // AppKit throws for too many constraint passes. A plain container keeps window
        // sizing entirely in layoutPanel().
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        container.wantsLayer = true
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("MultiAudio")
        }
        updateIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            // For debug click tests: where the icon is (top-left screen coordinates).
            guard let self, CommandLine.arguments.contains("--write-icon-rect") else { return }
            let r = self.statusItemScreenRect
            let h = NSScreen.screens.first?.frame.height ?? 0
            try? "\(r.midX),\(h - r.midY)".write(toFile: "/tmp/multiaudio-icon.txt", atomically: true, encoding: .utf8)
        }
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        let name = model.isActive ? "hifispeaker.2.fill" : "hifispeaker.2"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "MultiAudio")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// When the panel last started closing; a click on the icon right after an
    /// auto-close (e.g. from the same click) must not reopen it.
    private var lastCloseTime = Date.distantPast

    @objc func toggle() {
        if panel.isVisible {
            // Open, or mid close animation: the icon click means "go away".
            close()
        } else if Date().timeIntervalSince(lastCloseTime) > 0.3 {
            open()
        }
    }

    // MARK: Open / close

    func open() {
        log.notice("panel open")
        shrinkWork?.cancel()
        closing = false
        layoutPanel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        statusItem.button?.highlight(true)

        // Start from the collapsed state, then spring open on the next runloop turn.
        presentation.isShown = false
        DispatchQueue.main.async { [self] in
            withAnimation(Self.openAnimation) { presentation.isShown = true }
        }
        installMonitors()
    }

    func close() {
        guard panel.isVisible, !closing else { return }
        closing = true
        lastCloseTime = Date()
        log.notice("panel close")
        removeMonitors()
        statusItem.button?.highlight(false)
        withAnimation(Self.closeAnimation) {
            presentation.isShown = false
        } completion: { [weak self] in
            guard let self, self.closing else { return }
            self.panel.orderOut(nil)
            self.closing = false
        }
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var openAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.84)
    }
    static var closeAnimation: Animation { .easeIn(duration: reduceMotion ? 0.12 : 0.16) }

    private func installMonitors() {
        removeMonitors()
        // Clicks in other apps close the panel, like a menu.
        // The menu-bar icon is drawn outside our process on recent macOS, so clicks on it can
        // arrive here too; leave those to toggle() so the icon closes rather than reopens.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, !self.statusItemScreenRect.insetBy(dx: -2, dy: -2).contains(location) else { return }
                self.close()
            }
        }) { monitors.append(m) }
        // Escape closes it too.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    // MARK: Layout

    /// Called from SwiftUI's geometry callback, i.e. *during* a layout pass. Resizing the
    /// window synchronously here re-enters AppKit's constraint update and can loop until
    /// AppKit throws, so changes are coalesced and applied after the pass.
    private var pendingHeight: CGFloat?
    private func contentSizeChanged(_ size: CGSize) {
        let newHeight = ceil(size.height)
        let alreadyScheduled = pendingHeight != nil
        pendingHeight = newHeight
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [weak self] in self?.applyPendingHeight() }
    }

    private func applyPendingHeight() {
        guard let newHeight = pendingHeight else { return }
        pendingHeight = nil
        guard abs(newHeight - contentHeight) > 0.5 else { return }
        shrinkWork?.cancel()
        if newHeight > contentHeight || !panel.isVisible {
            contentHeight = newHeight
            layoutPanel()
        } else {
            // Let collapse animations finish before the window shrinks and clips them.
            let work = DispatchWorkItem { [weak self] in
                self?.contentHeight = newHeight
                self?.layoutPanel()
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    /// Positions the panel under the status item, top-anchored, kept on screen.
    private func layoutPanel() {
        let m = Self.margin
        let width = Self.contentWidth + m * 2
        let height = contentHeight + m * 2

        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var x = buttonRect.midX - width / 2
        x = min(max(x, visible.minX - m + 8), visible.maxX - width + m - 8)
        let top = buttonRect.minY - Self.gap + m
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
    }

    private var statusItemScreenRect: NSRect {
        guard let button = statusItem.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Screen rect of the visible content (used by debug screenshots).
    var contentScreenRect: NSRect { panel.frame.insetBy(dx: Self.margin, dy: Self.margin) }
}

/// Root view inside the panel: applies the open/close animation and reports size.
struct PanelRoot: View {
    @ObservedObject var presentation: PanelPresentation
    var onSize: (CGSize) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = presentation.isShown
        let still = shown || reduceMotion
        MenuView()
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: StatusItemController.contentWidth)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { onSize($0) }
            // Subtle "drop from the menu bar": slight scale from the top, lift and fade.
            .scaleEffect(still ? 1 : 0.94, anchor: .top)
            .offset(y: still ? 0 : -8)
            .opacity(shown ? 1 : 0)
            .padding(StatusItemController.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
