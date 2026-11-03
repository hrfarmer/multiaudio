import Foundation
import MultiAudioCore

// Test tool: streams a quiet sine tone to ONE AirPlay receiver.
// Usage: aptest [host] [seconds] [volume0-1]
let args = CommandLine.arguments
let host = args.count > 1 ? args[1] : "Desk-Speaker-A4CF99AE7241.local"
let seconds = args.count > 2 ? Double(args[2]) ?? 6 : 6
let volume = args.count > 3 ? Float(args[3]) ?? 0.25 : 0.25

guard host.localizedCaseInsensitiveContains("desk") || ProcessInfo.processInfo.environment["APTEST_ALLOW_ANY"] == "1" else {
    print("Refusing to test against \(host); only Desk Speaker is allowed (set APTEST_ALLOW_ANY=1 to override)")
    exit(2)
}

var phase = 0.0
let latency = Double(ProcessInfo.processInfo.environment["APTEST_LATENCY"] ?? "2") ?? 2
let toneDelay = Double(ProcessInfo.processInfo.environment["APTEST_TONE_AT"] ?? "0") ?? 0
var framesOut = 0
var toneStartPrinted = false
let streamer = AirPlayStreamer(latencySeconds: latency) { buf, frames in
    // Silence for the first `toneDelay` seconds *after the session is streaming*, then tone.
    let streaming = session.state == .streaming
    if streaming { framesOut += frames }
    let on = streaming && Double(framesOut) / 44100 > toneDelay
    if on && !toneStartPrinted { toneStartPrinted = true; print(String(format: "TONE_SENT_AT %.3f", Date().timeIntervalSince1970)) }
    for i in 0..<frames {
        let v = on ? Int16(sin(phase) * 6000) : 0
        phase += 2 * .pi * 440 / 44100
        if phase > 2 * .pi { phase -= 2 * .pi }
        buf[i * 2] = v; buf[i * 2 + 1] = v
    }
}
nonisolated(unsafe) var session: AirPlaySession! = nil
session = AirPlaySession(target: AirPlayTarget(name: "Desk Speaker", host: host, port: 7000), volume: volume)
let start = Date()
session.onStateChange = { print(String(format: "[%.2fs] state: %@", Date().timeIntervalSince(start), "\($0)")) }
streamer.add(session)
let vol2 = ProcessInfo.processInfo.environment["APTEST_VOL2"].flatMap(Float.init)
for k in 0..<Int(seconds) {
    Thread.sleep(forTimeInterval: 1)
    if k == Int(seconds) / 2, let vol2 { session.setVolume(vol2); print(String(format: "VOLUME_CHANGED_AT %.3f -> \(vol2)", Date().timeIntervalSince1970)) }
    print("  stats: \(session.stats)")
}
streamer.stopAll()
Thread.sleep(forTimeInterval: 1)
print("done, final state: \(session.state)")
