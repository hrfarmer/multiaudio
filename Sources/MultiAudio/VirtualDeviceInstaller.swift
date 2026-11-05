import AppKit
import Foundation

/// Installs the virtual output device that's bundled in the app. It has to live in a system
/// folder and coreaudiod has to restart to load it, so this needs an admin password.
enum VirtualDeviceInstaller {
    enum State { case missing, outdated, ready }
    struct Cancelled: Error {}

    private static let name = "MultiAudioDevice.driver"
    private static let systemFolder = "/Library/Audio/Plug-Ins/HAL"
    private static var installedPath: String { "\(systemFolder)/\(name)" }
    private static var bundledPath: String? { Bundle.main.path(forResource: "MultiAudioDevice", ofType: "driver") }

    private static func version(at path: String) -> String? {
        // Not Bundle(path:): it reports no Info.plist for the copy nested in the app.
        NSDictionary(contentsOfFile: "\(path)/Contents/Info.plist")?["CFBundleVersion"] as? String
    }

    static var state: State {
        guard let installed = version(at: installedPath) else { return .missing }
        guard let bundledPath, let bundled = version(at: bundledPath) else { return .ready }
        return installed == bundled ? .ready : .outdated
    }

    static func install() async throws {
        guard let bundledPath else { throw NSError(domain: "MultiAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "This build doesn't include the audio driver."]) }
        let installed = shellQuoted(installedPath)
        try await runAsAdmin("""
            mkdir -p \(shellQuoted(systemFolder)) && rm -rf \(installed) && \
            cp -R \(shellQuoted(bundledPath)) \(installed) && chown -R root:wheel \(installed) && killall coreaudiod
            """)
    }

    /// Restarting coreaudiod invalidates every audio object this process holds, so start over.
    /// `exit` rather than a normal quit: tearing down through a restarting coreaudiod can stall.
    static func relaunch() -> Never {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 2; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? reopen.run()
        exit(0)
    }

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runAsAdmin(_ command: String) async throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        try await Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return }
            if error[NSAppleScript.errorNumber] as? Int == -128 { throw Cancelled() }
            let message = error[NSAppleScript.errorMessage] as? String ?? "The installer failed."
            throw NSError(domain: "MultiAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }.value
    }
}
