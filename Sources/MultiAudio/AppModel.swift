import CoreAudio
import Foundation
import MultiAudioCore
import ServiceManagement
import SwiftUI
import os

let log = Logger(subsystem: "dev.aychar.multiaudio", category: "app")

@MainActor
final class AppModel: ObservableObject {
    struct LocalItem: Identifiable, Equatable {
        let id: String
        var device: OutputDeviceInfo
        var enabled: Bool
        var volume: Float
        var error: String?
    }

    enum AirPlayStatus: Equatable {
        case off, resolving, connecting, playing
        case failed(String)
    }

    struct AirPlayItem: Identifiable, Equatable {
        var id: String { device.name }
        var device: DiscoveredAirPlayDevice
        var enabled: Bool
        var volume: Float
        var status: AirPlayStatus
    }

    @Published var localItems: [LocalItem] = []
    @Published var airplayItems: [AirPlayItem] = []
    @Published var errorMessage: String?
    /// Whether the settings tile is expanded in the panel.
    @Published var showSettings = false
    @Published var systemOutputIsAirPlay = false
    @Published var syncLocalToAirPlay: Bool {
        didSet { defaults.set(syncLocalToAirPlay, forKey: "syncLocalToAirPlay"); updateLocalDelay() }
    }
    /// Fine-tune for local delay when syncing, in milliseconds.
    @Published var syncOffsetMs: Double {
        didSet { defaults.set(syncOffsetMs, forKey: "syncOffsetMs"); updateLocalDelay() }
    }
    /// Receiver latency setting in seconds (Low/Normal/High).
    @Published var airplayBuffer: Double {
        didSet {
            defaults.set(airplayBuffer, forKey: "airplayBuffer")
            router.airplayBufferSeconds = airplayBuffer
            updateLocalDelay()
        }
    }
    var airplayDelayDescription: String { String(format: "%.1f s", router.airplayDelay) }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private let router = AudioRouter()
    private let browser = AirPlayBrowser()
    private let defaults = UserDefaults.standard
    private var listeners: [() -> Void] = []

    static let defaultAirPlayOffsetMs = 0.0

    var isActive: Bool {
        localItems.contains { $0.enabled } || airplayItems.contains { $0.enabled }
    }

    init() {
        syncLocalToAirPlay = defaults.object(forKey: "syncLocalToAirPlay") as? Bool ?? true
        syncOffsetMs = defaults.object(forKey: "syncOffsetMs") as? Double ?? AppModel.defaultAirPlayOffsetMs
        airplayBuffer = defaults.object(forKey: "airplayBuffer") as? Double ?? 0.25
        router.airplayBufferSeconds = airplayBuffer
        router.onError = { [weak self] msg in Task { @MainActor in self?.errorMessage = msg } }

        refreshLocalDevices()
        let sys = AudioObjectID(kAudioObjectSystemObject)
        listeners.append(CA_listen(sys, kAudioHardwarePropertyDevices) { [weak self] in self?.refreshLocalDevices() })
        listeners.append(CA_listen(sys, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.checkSystemOutput() })
        checkSystemOutput()

        browser.onChange = { [weak self] devices in
            Task { @MainActor in self?.updateAirPlay(devices) }
        }
        browser.onLog = { log.notice("\($0, privacy: .public)") }
        browser.start()
        log.notice("model started, \(self.localItems.count) local devices")
    }

    // MARK: Local devices

    func refreshLocalDevices() {
        let devices = OutputDeviceInfo.currentOutputs()
        var items: [LocalItem] = []
        for d in devices {
            if let existing = localItems.first(where: { $0.id == d.id }) {
                var e = existing
                e.device = d
                items.append(e)
            } else {
                let enabled = defaults.bool(forKey: "local.enabled.\(d.id)")
                let volume = defaults.object(forKey: "local.volume.\(d.id)") as? Float ?? 1.0
                items.append(LocalItem(id: d.id, device: d, enabled: false, volume: volume))
                if enabled { pendingLocalRestore.insert(d.id) }
            }
        }
        // Devices that disappeared: stop routing to them.
        for gone in localItems where !devices.contains(where: { $0.id == gone.id }) && gone.enabled {
            router.disableLocal(gone.id)
        }
        localItems = items
        restorePendingLocal()
    }

    /// Saved outputs are only re-enabled once `beginRestoring()` is called, so the menu-bar
    /// icon exists before the capture tap starts (which can block on a permission check).
    private var restoreReady = false

    func beginRestoring() {
        restoreReady = true
        restorePendingLocal()
        updateAirPlay(airplayItems.map(\.device))
    }

    private func restorePendingLocal() {
        guard restoreReady else { return }
        for id in pendingLocalRestore where localItems.contains(where: { $0.id == id }) {
            pendingLocalRestore.remove(id)
            setLocal(id, enabled: true)
        }
    }

    private var pendingLocalRestore = Set<String>()

    func setLocal(_ id: String, enabled: Bool) {
        guard let i = localItems.firstIndex(where: { $0.id == id }) else { return }
        defaults.set(enabled, forKey: "local.enabled.\(id)")
        localItems[i].error = nil
        if enabled {
            do {
                try router.enableLocal(localItems[i].device, volume: localItems[i].volume)
                log.notice("local \(id, privacy: .public) enabled, capturing=\(self.router.isCapturing)")
                localItems[i].enabled = true
                errorMessage = nil
            } catch {
                localItems[i].enabled = false
                localItems[i].error = "\(error)"
                log.error("local \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                errorMessage = "\(error)"
            }
        } else {
            router.disableLocal(id)
            localItems[i].enabled = false
        }
        updateLocalDelay()
    }

    func setLocalVolume(_ id: String, _ v: Float) {
        guard let i = localItems.firstIndex(where: { $0.id == id }) else { return }
        localItems[i].volume = v
        defaults.set(v, forKey: "local.volume.\(id)")
        router.setLocalVolume(id, v)
    }

    // MARK: AirPlay

    private func updateAirPlay(_ devices: [DiscoveredAirPlayDevice]) {
        var items: [AirPlayItem] = []
        for d in devices {
            if let existing = airplayItems.first(where: { $0.id == d.name }) {
                var e = existing
                e.device = d
                items.append(e)
            } else {
                let volume = defaults.object(forKey: "airplay.volume.\(d.name)") as? Float ?? 0.5
                items.append(AirPlayItem(device: d, enabled: false, volume: volume, status: .off))
            }
        }
        // Keep enabled devices around even if Bonjour briefly drops them.
        for old in airplayItems where old.enabled && !items.contains(where: { $0.id == old.id }) {
            items.append(old)
        }
        let restore = !restoreReady ? [] : items.filter { !$0.enabled && defaults.bool(forKey: "airplay.enabled.\($0.id)") && !restoredAirPlay.contains($0.id) }
        airplayItems = items
        for r in restore {
            restoredAirPlay.insert(r.id)
            setAirPlay(r.id, enabled: true)
        }
    }

    private var restoredAirPlay = Set<String>()

    func setAirPlay(_ name: String, enabled: Bool) {
        guard let i = airplayItems.firstIndex(where: { $0.id == name }) else { return }
        defaults.set(enabled, forKey: "airplay.enabled.\(name)")
        if !enabled {
            router.disableAirPlay(name)
            airplayItems[i].enabled = false
            airplayItems[i].status = .off
            updateLocalDelay()
            return
        }
        airplayItems[i].enabled = true
        airplayItems[i].status = .resolving
        let device = airplayItems[i].device
        let volume = airplayItems[i].volume
        updateLocalDelay()
        Task {
            do {
                let target = try await AirPlayBrowser.resolve(device)
                guard let j = airplayItems.firstIndex(where: { $0.id == name }), airplayItems[j].enabled else { return }
                try router.enableAirPlay(target, volume: volume) { [weak self] state in
                    self?.airplayStateChanged(name, state)
                }
                log.notice("airplay \(name, privacy: .public) resolved \(target.host, privacy: .public), capturing=\(self.router.isCapturing)")
            } catch {
                airplayStateChanged(name, .failed("\(error)"))
            }
        }
    }

    private func airplayStateChanged(_ name: String, _ state: AirPlaySessionState) {
        log.notice("airplay \(name, privacy: .public): \(String(describing: state), privacy: .public)")
        guard let i = airplayItems.firstIndex(where: { $0.id == name }), airplayItems[i].enabled else { return }
        switch state {
        case .idle: airplayItems[i].status = .off
        case .connecting: airplayItems[i].status = .connecting
        case .streaming: airplayItems[i].status = .playing
        case .failed(let msg):
            airplayItems[i].status = .failed(msg)
            scheduleAirPlayRetry(name)
        }
        if case .playing = airplayItems[i].status { retryAttempts[name] = 0 }
    }

    /// Reconnects dropped AirPlay sessions with backoff (3 s, 6 s, … up to 60 s).
    private var retryAttempts: [String: Int] = [:]
    private func scheduleAirPlayRetry(_ name: String) {
        let attempt = (retryAttempts[name] ?? 0) + 1
        retryAttempts[name] = attempt
        let delay = min(60.0, 3.0 * pow(2.0, Double(attempt - 1)))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let item = self.airplayItems.first(where: { $0.id == name }),
                  item.enabled, case .failed = item.status else { return }
            log.notice("retrying \(name, privacy: .public) (attempt \(attempt))")
            self.router.disableAirPlay(name)
            self.setAirPlay(name, enabled: true)
        }
    }

    func retryAirPlay(_ name: String) {
        retryAttempts[name] = 0
        router.disableAirPlay(name)
        setAirPlay(name, enabled: true)
    }

    func setAirPlayVolume(_ name: String, _ v: Float) {
        guard let i = airplayItems.firstIndex(where: { $0.id == name }) else { return }
        airplayItems[i].volume = v
        defaults.set(v, forKey: "airplay.volume.\(name)")
        router.setAirPlayVolume(name, v)
    }

    // MARK: Sync / misc

    var anyAirPlayEnabled: Bool { airplayItems.contains { $0.enabled } }

    private func updateLocalDelay() {
        if syncLocalToAirPlay && anyAirPlayEnabled {
            router.localDelay = max(0, router.airplayDelay + syncOffsetMs / 1000)
        } else {
            router.localDelay = 0
        }
    }

    func checkSystemOutput() {
        let dev = CA_defaultOutput()
        systemOutputIsAirPlay = CA_transport(dev) == kAudioDeviceTransportTypeAirPlay
    }

    /// Points the system output at a built-in device so macOS's own AirPlay session
    /// doesn't fight ours for the same speaker.
    func switchSystemOutputToBuiltIn() {
        if let builtIn = OutputDeviceInfo.currentOutputs().first(where: { $0.isBuiltIn }) ?? OutputDeviceInfo.currentOutputs().first {
            CA_setDefaultOutput(builtIn.deviceID)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func shutdown() {
        router.stopAll()
    }
}
