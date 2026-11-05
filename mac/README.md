# Murmur for Mac

A menu bar app that listens and sends what you say, as text, to your murmur
server.

- **Always**: listens in the background. Silero voice activity detection cuts
  speech into utterances; each is transcribed on the Mac.
- **Push to talk**: hold a key (Right ⌥ by default; needs the Accessibility
  permission) and talk; releasing sends it.
- **Toggle**: like push to talk, but the key toggles. One press starts
  recording, the next press stops and sends it — no holding. Uses the same key
  and the same Accessibility permission.
- **Off**: the microphone is closed.

Speech recognition is **Parakeet TDT v3** on the Neural Engine via
[FluidAudio](https://github.com/FluidInference/FluidAudio): multilingual
(German, English and 23 more), language detected automatically. The model
(~500 MB) downloads on first start. Audio never leaves the Mac; transcripts
wait in a local queue until the server takes them, so it works offline.

## Install

Download `Murmur.zip` from the [mac-latest release](https://github.com/dseif0x/murmur/releases/tag/mac-latest),
unzip, move `Murmur.app` to Applications, and right-click → Open the first
time (the app is ad-hoc signed, not notarized). In Settings: server URL
(e.g. `https://murmur.example.com`), the upload token, a device name.

Requires macOS 14 and Apple silicon.

## Build

```sh
cd mac && ./scripts/build-app.sh   # Xcode 26 / Swift 6.2
open build/Murmur.app
```
