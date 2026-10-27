# Crescendo: maintainer notes

A background macOS app (no Dock or menu bar icon) that catches the volume keys while an Audient
iD14 MKII is the default output, and sets the interface's own monitor volume over USB. Objective-C
in one file, no Xcode project. Read this before changing anything.

## Files

- `Crescendo.m`: the whole app. USB control, key handling, volume bar, volume memory, login item.
- `make-icon.m`: draws the app icon (a knob with 16 lit steps); `build.sh` runs it.
- `Info.plist`: bundle ID `com.kolderkat.crescendo`; the version lives here.
- `build.sh`: builds `build/Crescendo.app` (universal arm64 + x86_64) and `build/Crescendo-<version>.dmg`.
  `SIGN_IDENTITY` picks the certificate (default ad-hoc).
- `install.sh`: `build.sh`, then replaces `/Applications/Crescendo.app` and starts it.

## How it talks to the iD14

- Protocol from the Linux projects MixiD, BiD (`docs/PROTOCOL.md`) and Monix. Monitor section is
  unit `0x36`: volume = selector `0x12`, int16 in 1/256 dB, `0x8000` = off; mute = selector `0x04`,
  1 byte. Class requests: `0x21` SET, `0xa1` GET, `bRequest 0x01`, `wIndex = unit << 8 | interface`.
- Requests go through IOKit `DeviceRequest` without opening the device, to the spare DFU/vendor
  interface (class `0xfe`/`0xff`, interface 4 on this unit). macOS's audio driver keeps the audio
  interfaces, so playback never stops.
- Matching needs vendor `0x2708` **and** product `0x0008`; IOUSBHostDevice matching ignores a vendor ID
  alone.
- Monitor volume and mute can be read back (`GET` works); BiD says most other units are write-only.

## Behaviour and why

- **Volume keys cover −80 to −20 dB in 16 steps of 3.75 dB** (`kFloorDb`, `kCeilingDb`, `kSteps`).
  The first version used −60 to 0 dB; Siebe listens around −45 to −66 dB, so the bottom step was
  too loud. Above −20 dB is the knob's job: volume up never pulls a louder knob setting down.
- **Every key press reads the level first,** then steps from there, so the knob is never overwritten.
- **Volume memory:** the level is polled every 2 s and saved in user defaults. On a USB arrival it
  is written back at +2, +4 and +6 s (the iD14 starts at its own level, and the iD app may change it
  after); nothing is saved while that restore runs. BiD warns that heavy control traffic during a
  sample-rate change can freeze the iD14's controls until a replug; one read per 2 s has been fine.
- **Waits for Accessibility instead of quitting:** an exit-and-restart loop opened a new permission
  prompt every time, and a pile of system prompts can block mouse clicks.

## Lessons learned (don't repeat these)

- **The event tap callback must stay fast.** macOS times a slow tap out and hands the key to its own
  volume bar. A SwiftUI Liquid Glass bar with the `.materialize` transition was tried on
  2026-10-27: drawing it from the tap callback took up to 12 s (the glass waits on the window server,
  which waits on the tap), so the native bar kept appearing. Moving the tap to its own thread still
  showed seconds of latency, and the attempt was reverted to the AppKit bar. If you try glass again:
  tap on its own thread, only `dispatch_async` from the callback, let key-up events pass through,
  and measure tap latency (below) before shipping.
- **Accessibility permission is tied to the code signature.** Ad-hoc signing loses it on every
  rebuild; sign with a real certificate. Changing the bundle ID also means a new permission and an
  empty saved volume.
- **Removing an app from the Accessibility list asks for Touch ID or a password.** If that prompt is
  hidden behind a window, clicks elsewhere stop working until it's answered (Esc cancels).
- The bar draws itself (`CALayer` fill, 0.06 s) because `NSProgressIndicator`'s fill animation is
  slow and can't be tuned.

## Checking it

- `Crescendo --read` (inside the app bundle) prints the monitor volume and mute; it only reads.
- Tap latency: `CGGetEventTapList` lists every tap with `avgUsecLatency` / `maxUsecLatency`. A healthy
  Crescendo tap stays far below a millisecond.
- There's no test suite. The step math (`nextLevel`) was checked with a throwaway harness that
  `#include`s `Crescendo.m` with `main` renamed; do the same after changing the range.

## Releasing

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
2. `SIGN_IDENTITY="Apple Development: …" ./install.sh` and try it on the real iD14.
3. Commit (`Crescendo x.y.z: <what changed>`), push `main`.
4. `gh release create vx.y.z build/Crescendo-x.y.z.dmg -R SiebeCooreman/crescendo --title "Crescendo x.y.z" --notes "…"`.

Builds aren't notarised, so users need **Privacy & Security → Open Anyway** on first launch.
Notarising needs a Developer ID certificate (paid Apple Developer Program).
