import AppKit
import CoreAudio
import MultiAudioCore
import SwiftUI

@main
struct MultiAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .onAppear { delegate.model = model }
        } label: {
            Image(systemName: model.isActive ? "hifispeaker.2.fill" : "hifispeaker.2")
                .task { Snapshot.runIfRequested(model: model) }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MultiAudio").font(.headline)
                Spacer()
                if model.isActive {
                    Label("Routing", systemImage: "dot.radiowaves.left.and.right")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.systemOutputIsAirPlay {
                Notice(icon: "exclamationmark.triangle.fill", tint: .orange,
                       text: "macOS is sending sound to an AirPlay speaker itself. That can clash with MultiAudio.") {
                    Button("Use Mac speakers") { model.switchSystemOutputToBuiltIn() }
                        .controlSize(.small)
                }
            }

            if let err = model.errorMessage {
                Notice(icon: "xmark.octagon.fill", tint: .red, text: err) {
                    Button("Dismiss") { model.errorMessage = nil }.controlSize(.small)
                }
            }

            SectionHeader(title: "This Mac", icon: "speaker.wave.2")
            if model.localItems.isEmpty {
                Text("No output devices").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.localItems) { item in
                DeviceRow(name: item.device.name,
                          icon: icon(forTransport: item.device.transport),
                          enabled: Binding(get: { item.enabled }, set: { model.setLocal(item.id, enabled: $0) }),
                          volume: Binding(get: { item.volume }, set: { model.setLocalVolume(item.id, $0) }),
                          status: item.error)
            }

            Divider()

            SectionHeader(title: "AirPlay", icon: "airplayaudio")
            if model.airplayItems.isEmpty {
                Text("Looking for AirPlay speakers…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.airplayItems) { item in
                DeviceRow(name: item.device.name,
                          icon: airplayIcon(item.device.model),
                          enabled: Binding(get: { item.enabled }, set: { model.setAirPlay(item.id, enabled: $0) }),
                          volume: Binding(get: { item.volume }, set: { model.setAirPlayVolume(item.id, $0) }),
                          status: statusText(item.status),
                          statusIsError: { if case .failed = item.status { return true } else { return false } }(),
                          retry: { if case .failed = item.status { return { model.retryAirPlay(item.id) } } else { return nil } }())
            }

            Divider()

            HStack {
                Text("AirPlay buffer").font(.callout)
                Spacer()
                Picker("", selection: $model.airplayBuffer) {
                    Text("Low").tag(0.15)
                    Text("Normal").tag(0.25)
                    Text("High").tag(0.5)
                    Text("Max").tag(1.0)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .help("Lower means less delay; higher survives weak Wi-Fi better. Current delay ≈ \(model.airplayDelayDescription)")

            Toggle("Delay Mac outputs to match AirPlay", isOn: $model.syncLocalToAirPlay)
                .toggleStyle(.checkbox)
                .font(.callout)
            if model.syncLocalToAirPlay {
                HStack {
                    Text("Sync offset").font(.caption)
                    Slider(value: Binding(get: { model.syncOffsetMs }, set: { model.syncOffsetMs = ($0 / 10).rounded() * 10 }), in: -1000...1000)
                    Text("\(Int(model.syncOffsetMs)) ms").font(.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
                }
                .disabled(!model.anyAirPlayEnabled)
            }

            Divider()

            HStack {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Spacer()
                Button("Quit") {
                    model.shutdown()
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func statusText(_ s: AppModel.AirPlayStatus) -> String? {
        switch s {
        case .off: return nil
        case .resolving: return "Finding…"
        case .connecting: return "Connecting…"
        case .playing: return nil
        case .failed(let m): return m
        }
    }

    private func icon(forTransport t: UInt32) -> String {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return "macmini"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        default: return "speaker.wave.2"
        }
    }

    private func airplayIcon(_ model: String) -> String {
        if model.hasPrefix("AudioAccessory") { return "homepod.fill" }
        if model.hasPrefix("AppleTV") { return "appletv.fill" }
        return "tv"
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct Notice<Actions: View>: View {
    let icon: String
    let tint: Color
    let text: String
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                actions
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DeviceRow: View {
    let name: String
    let icon: String
    @Binding var enabled: Bool
    @Binding var volume: Float
    var status: String?
    var statusIsError = false
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(enabled ? .primary : .secondary)
                Text(name).lineLimit(1).truncationMode(.tail)
                Spacer()
                Toggle("", isOn: $enabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            if enabled {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(volume) }, set: { volume = Float($0) }), in: 0...1)
                        .controlSize(.small)
                    Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.leading, 26)
            }
            if let status {
                HStack(spacing: 6) {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let retry {
                        Button("Retry", action: retry).controlSize(.mini)
                    }
                }
                .padding(.leading, 26)
            }
        }
    }
}
