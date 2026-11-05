# MultiAudio

A menu-bar app that plays your Mac's audio on several outputs at once, including
multiple AirPlay speakers, with a volume slider for each one.

## How it works

- **Capture:** a Core Audio process tap (macOS 14.2+) records all system audio except
  MultiAudio's own, and mutes it at its normal output.
- **Mac outputs** (built-in speakers, displays, USB, Bluetooth): each enabled device gets
  its own output unit, ring buffer and software gain.
- **AirPlay:** MultiAudio contains its own AirPlay 2 sender (`Sources/MultiAudioCore/AirPlay`).
  For each speaker it does transient pairing (SRP-6a, PIN 3939), encrypted RTSP control,
  uncompressed ALAC over ChaCha20-Poly1305 RTP, NTP timing and sync packets. It also replies
  to requests the speaker sends on its event channel; without those replies HomePods drop
  the session after about 30 s.
  All speakers share one RTP timeline, so they play in sync with each other.
  macOS's own multi-speaker AirPlay can't be used here: it only gives its speaker list
  to apps holding entitlements Apple reserves for itself.
- **Sync:** Mac outputs are delayed to line up with AirPlay. The speakers delay audio by
  about 2 × the buffer setting + 65 ms. The Sync offset slider fine-tunes the delay.

- **Video sync (optional):** the MultiAudio virtual output device (`Driver/`) is a Core Audio
  plug-in that reports MultiAudio's current delay as its latency. With it as the system
  output, video players delay their picture to match. It discards its own audio; the tap
  still captures what apps play, so MultiAudio only keeps it selected while an output is on,
  and hands the system output back otherwise. Its volume and mute controls act as a master
  volume across all outputs, so the volume keys work.

## UI

The menu-bar panel is a borderless window made of Liquid Glass tiles (SwiftUI `glassEffect`
in a `GlassEffectContainer`), so it can animate when opening and closing. It closes on Escape, a click elsewhere or a click on the icon,
and follows Reduce Motion.

## Requirements

- macOS 27.
- Each speaker must allow your Mac to connect. For HomePods and Apple TVs that means:
  Home app → Home Settings → Speakers & TV → Allow Speaker & TV Access →
  **Anyone on the Same Network** (or Everyone).
- Devices that require an on-screen PIN aren't supported yet; they show a pairing error.
- Leave macOS's own output on a non-AirPlay device (the app warns you and has a button for
  this). Otherwise macOS keeps its own AirPlay session open and it clashes with MultiAudio.

## Build

```sh
scripts/make-signing-identity.sh   # once: stable local signing, so permissions persist
scripts/build-app.sh --install     # builds and copies to /Applications/MultiAudio.app
```

Video sync is installed from Settings in the app. It needs an admin password, briefly cuts
all audio and restarts MultiAudio. `scripts/build-driver.sh --install` and `--uninstall` do
the same from a terminal; restart MultiAudio afterwards.

On first use, macOS asks for **Local Network** (to find speakers) and
**System Audio Recording** (to capture audio) permission.

## Testing tools

- `swift run aptest <host> [seconds] [volume]` streams a quiet 440 Hz tone to a single
  receiver. It only accepts Desk Speaker unless `APTEST_ALLOW_ANY=1` is set.
- Set `AIRPLAY_DEBUG=1` for protocol logging.
- `MultiAudio.app/Contents/MacOS/MultiAudio --open-panel [--demo-state] [--show-settings] [--stress] [--capture out.png] [--capture-at ms]`
  opens the panel at launch and can screenshot it with ScreenCaptureKit.
  `--demo-state` only changes what's shown; no audio is routed.
