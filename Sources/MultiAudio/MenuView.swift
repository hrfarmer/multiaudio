import CoreAudio
import MultiAudioCore
import SwiftUI

/// The panel content: floating Liquid Glass tiles, in the style of Control Center.
struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Namespace private var glass

    private static let tileRadius: CGFloat = 22
    private var tileShape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous) }

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: 10) {
                header

                if model.systemOutputIsAirPlay {
                    NoticeTile(icon: "exclamationmark.triangle.fill", tint: .orange,
                               text: "macOS is also sending sound to an AirPlay speaker, which can clash with MultiAudio.",
                               action: ("Use Mac Speakers", { model.switchSystemOutputToBuiltIn() }))
                        .glassEffectID("notice", in: glass)
                        .transition(.blurReplace)
                }

                if let output = model.pausedForOutput {
                    NoticeTile(icon: "pause.circle.fill", tint: .accentColor,
                               text: "Sound is playing directly on \(output), so MultiAudio is paused.",
                               action: ("Use MultiAudio", { withAnimation(.smooth) { model.useMultiAudio() } }))
                        .glassEffectID("paused", in: glass)
                        .transition(.blurReplace)
                }

                if let err = model.errorMessage {
                    NoticeTile(icon: "xmark.octagon.fill", tint: .red, text: err,
                               action: ("Dismiss", { withAnimation(.smooth) { model.errorMessage = nil } }))
                        .glassEffectID("error", in: glass)
                        .transition(.blurReplace)
                }

                if model.driverState == .ready {
                    DeviceSection(title: "This Mac", emptyText: "No output devices") {
                        ForEach(model.localItems) { item in
                            DeviceRow(name: item.device.name,
                                      icon: Self.icon(forTransport: item.device.transport),
                                      enabled: Binding(get: { item.enabled }, set: { model.setLocal(item.id, enabled: $0) }),
                                      volume: Binding(get: { item.volume }, set: { model.setLocalVolume(item.id, $0) }),
                                  channels: Binding(get: { item.channels }, set: { model.setLocalChannels(item.id, $0) }),
                                      status: item.error, statusIsError: item.error != nil)
                        }
                    } isEmpty: { model.localItems.isEmpty }
                    .glassEffect(.regular, in: tileShape)
                    .glassEffectID("local", in: glass)

                    DeviceSection(title: "AirPlay", emptyText: "Looking for speakers…") {
                        ForEach(model.airplayItems) { item in
                            DeviceRow(name: item.device.name,
                                      icon: Self.airplayIcon(item.device.model),
                                      enabled: Binding(get: { item.enabled }, set: { model.setAirPlay(item.id, enabled: $0) }),
                                      volume: Binding(get: { item.volume }, set: { model.setAirPlayVolume(item.id, $0) }),
                                  channels: Binding(get: { item.channels }, set: { model.setAirPlayChannels(item.id, $0) }),
                                      status: Self.statusText(item.status),
                                      statusIsError: { if case .failed = item.status { true } else { false } }(),
                                      busy: [.resolving, .connecting].contains(item.status),
                                      retry: { if case .failed = item.status { { model.retryAirPlay(item.id) } } else { nil } }())
                        }
                    } isEmpty: { model.airplayItems.isEmpty }
                    .glassEffect(.regular, in: tileShape)
                    .glassEffectID("airplay", in: glass)
                } else {
                    NoticeTile(icon: "speaker.badge.exclamationmark.fill", tint: .accentColor,
                               text: model.driverState == .missing
                                   ? "MultiAudio needs its audio driver to route sound and keep video in time. Installing asks for your password and briefly cuts sound."
                                   : "MultiAudio's audio driver needs an update. Updating asks for your password and briefly cuts sound.",
                               action: (model.driverState == .missing ? "Install Driver…" : "Update Driver…", { model.installDriver() }))
                        .glassEffectID("setup", in: glass)
                        .transition(.blurReplace)
                }

                if model.showSettings {
                    SettingsTile()
                        .glassEffect(.regular, in: tileShape)
                        .glassEffectID("settings", in: glass)
                }
            }
        }
    }

    // MARK: Header: status + settings button that morph together

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: model.isActive ? "hifispeaker.2.fill" : "hifispeaker.2")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.isActive ? Color.white : Color.primary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(model.isActive ? Color.accentColor : Color.primary.opacity(0.1)))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sound Output").font(.headline)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: tileShape)
            .glassEffectID("header", in: glass)

            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { model.showSettings.toggle() }
            } label: {
                Image(systemName: model.showSettings ? "xmark" : "gearshape.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .glassEffectID("gear", in: glass)
            .help(model.showSettings ? "Hide settings" : "Settings")
        }
    }

    private var summary: String {
        let n = model.localItems.filter(\.enabled).count + model.airplayItems.filter(\.enabled).count
        switch n {
        case 0: return "Not routing"
        case 1: return "Playing on 1 output"
        default: return "Playing on \(n) outputs"
        }
    }

    // MARK: Helpers

    static func statusText(_ s: AppModel.AirPlayStatus) -> String? {
        switch s {
        case .off, .playing: return nil
        case .resolving: return "Finding…"
        case .connecting: return "Connecting…"
        case .asleep: return "Asleep until audio plays"
        case .paused: return "Paused"
        case .failed(let m): return m
        }
    }

    static func icon(forTransport t: UInt32) -> String {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return "macmini"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        default: return "speaker.wave.2.fill"
        }
    }

    static func airplayIcon(_ model: String) -> String {
        if model.hasPrefix("AudioAccessory") { return "homepod.fill" }
        if model.hasPrefix("AppleTV") { return "appletv.fill" }
        return "tv"
    }
}

// MARK: - Section tile

struct DeviceSection<Rows: View>: View {
    let title: String
    let emptyText: String
    @ViewBuilder var rows: Rows
    var isEmpty: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            if isEmpty() {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            rows
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Device row: tap to toggle; reveals a volume slider when on

struct DeviceRow: View {
    let name: String
    let icon: String
    @Binding var enabled: Bool
    @Binding var volume: Float
    @Binding var channels: ChannelMode
    var status: String?
    var statusIsError = false
    var busy = false
    var retry: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { enabled.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(enabled ? Color.white : Color.primary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(enabled ? Color.accentColor : Color.primary.opacity(0.09)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).lineLimit(1).truncationMode(.tail)
                        if let status {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(statusIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.opacity)
                        }
                    }
                    Spacer(minLength: 4)
                    if busy {
                        ProgressView().controlSize(.small).transition(.opacity)
                    } else if let retry {
                        Button("Retry", action: retry)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
            .accessibilityAddTraits(enabled ? .isSelected : [])
            .accessibilityHint(enabled ? "Stop playing here" : "Play here")

            if enabled {
                Slider(value: Binding(get: { Double(volume) }, set: { volume = Float($0) }), in: 0...1) {
                    Text("\(name) volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
                }
                .labelsHidden()
                .controlSize(.small)
                .padding(.leading, 46)
                .padding(.trailing, 8)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity))

                Picker("\(name) channels", selection: $channels) {
                    Text("Stereo").tag(ChannelMode.stereo)
                    Text("Left").tag(ChannelMode.left)
                    Text("Right").tag(ChannelMode.right)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .padding(.leading, 46)
                .padding(.trailing, 8)
                .padding(.bottom, 4)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity))
            }
        }
    }
}

// MARK: - Notice tile (tinted glass)

struct NoticeTile: View {
    let icon: String
    let tint: Color
    let text: String
    let action: (String, () -> Void)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Button(action.0, action: action.1)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular.tint(tint.opacity(0.18)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Settings tile

struct SettingsTile: View {
    @EnvironmentObject var model: AppModel

    private func offsetStep(_ ms: Double, icon: String, help: String) -> some View {
        Button {
            let range = AppModel.offsetRangeMs
            model.syncOffsetMs = min(range.upperBound, max(range.lowerBound, model.syncOffsetMs + ms))
        } label: {
            Image(systemName: icon).font(.caption2.weight(.bold)).frame(width: 12, height: 12)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.mini)
        .buttonRepeatBehavior(.enabled)
        .help(help)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("AirPlay buffer")
                    Spacer()
                    Text("≈ \(model.airplayDelayDescription) delay")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Picker("AirPlay buffer", selection: $model.airplayBuffer) {
                    Text("Low").tag(0.15)
                    Text("Normal").tag(0.25)
                    Text("High").tag(0.5)
                    Text("Max").tag(1.0)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sync Mac outputs with AirPlay")
                    Text("Delays this Mac's outputs to line up with speakers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Sync Mac outputs with AirPlay", isOn: Binding(
                    get: { model.syncLocalToAirPlay },
                    set: { v in withAnimation(.smooth) { model.syncLocalToAirPlay = v } }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if model.syncLocalToAirPlay {
                HStack(spacing: 6) {
                    Text("Offset").font(.callout)
                    offsetStep(-1, icon: "minus", help: "1 ms earlier")
                    Slider(value: Binding(get: { model.syncOffsetMs }, set: { model.syncOffsetMs = $0.rounded() }),
                           in: AppModel.offsetRangeMs)
                        .controlSize(.small)
                    offsetStep(1, icon: "plus", help: "1 ms later")
                    Text("\(Int(model.syncOffsetMs)) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                        .contentTransition(.numericText())
                }
                .disabled(!model.anyAirPlayEnabled)
                .transition(.opacity)
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Disconnect AirPlay when idle")
                    Text("After 30 seconds of silence. Reconnects when audio plays.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Disconnect AirPlay when idle", isOn: $model.airplaySleepsWhenIdle)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            HStack {
                Text("Launch at login")
                Spacer()
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            HStack {
                Spacer()
                Button {
                    model.shutdown()
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit MultiAudio", systemImage: "power")
                }
                .buttonStyle(.glass)
                .keyboardShortcut("q")
            }
        }
        .padding(16)
    }
}
