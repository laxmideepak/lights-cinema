# WizCinema

WizCinema is a native macOS movie-ambience app. It captures system audio,
infers soundtrack moods locally (dialogue, suspense, ambience, and action),
then makes compatible lights follow the film with gentle cinematic
transitions. It supports direct local WiZ and LIFX control. It does not need
BlackHole, Loopback, or a cloud API to control either of those brands.

The audio-only conductor uses a compact spectral filter bank, onset/flux
tracking, adaptive loudness, and a temporal scene window. It has deliberate
events for **stingers**, **pulses**, **crescendos**, **dialogue lines**, and
**releases**. The scene-confidence value is an honest quality measurement of
signal strength, category separation, and temporal stability; it is not a
claim that the app can see the film or identify its exact plot beat.

## Requirements

- macOS 15 or later (the Core Audio tap itself was introduced in macOS 14.2)
- WiZ or LIFX lights on the same Wi-Fi as the Mac
- In WiZ: **Settings → Security → Allow local communication** switched on
- A non-guest Wi-Fi network that allows UDP port `38899` to the lights

Different Wi-Fi light brands use incompatible local protocols; no application
can safely control every device merely because it is on the same network.
Cinema Lights uses documented local providers instead of guessing at private
APIs or operating arbitrary network devices:

- **WiZ:** automatic UDP discovery and direct local control.
- **LIFX:** automatic UDP discovery and direct local control.
- **Philips Hue:** automatic official bridge discovery. The bridge is shown as
  detected; its required physical-button pairing/control workflow is not yet
  enabled in this build.
- **Nanoleaf, Govee, Kasa/Tapo and other brands:** not presented as compatible
  until a documented local control and pairing path can be implemented and
  tested.

The app never uses Home Assistant as a hidden bridge, does not control locks,
cameras, appliances, or other non-light devices, and never bypasses a brand's
pairing or local-control setting.

The app works with headphones because it reads the Mac's outgoing system audio,
not a microphone. Protected/DRM playback apps may decline to provide audio;
if the meters remain flat, try a local video or another player first.

## Build and run

```sh
cd "/Users/deepakchowdary/Documents/New project"
chmod +x scripts/build-app.sh
scripts/build-app.sh
open dist/WizCinema.app
```

At first start, macOS asks for **System Audio Recording** permission. Allow it.
WizCinema never captures, sees, or records your screen. If it was denied,
enable WizCinema under **System Settings → Privacy & Security → Screen & System
Audio Recording**, then quit and reopen the app.

To validate audio capture without changing any lights, start a film (or another
audio source) and run this from Terminal:

```sh
dist/WizCinema.app/Contents/MacOS/WizCinema --audio-probe
```

It listens for five seconds, reports the detected energy/frequency mix, and
does not send any light commands. If it reports no samples, grant System Audio
Recording permission and try again.

For a temporary whole-pipeline check, `--sync-probe` discovers every reachable
WiZ bulb, saves each readable state, reacts to audio for five seconds, then
sends the saved states back. It is intended for troubleshooting only because it
briefly changes those lights:

```sh
dist/WizCinema.app/Contents/MacOS/WizCinema --sync-probe
```

## Use

1. Select **Discover**. WiZ and LIFX lights on this Mac's Wi-Fi appear after a
   few seconds. A Hue bridge is shown separately as detected, pending its
   physical pairing workflow. If WiZ broadcast discovery is blocked, enter its IP address.
2. Tick the WiZ or LIFX lights you want to use, then choose a palette and brightness range.
3. Set **Cinema depth**, then press **Start cinema sync** and play a film. The
   app derives local soundtrack moods and events from bass, dialogue-range
   midtones, treble, loudness, dynamics, builds, impacts, and releases. The UI
   shows an inference-confidence score for signal quality. It sends coalesced
   updates with a bounded smoothing filter, avoiding flashes and sudden jumps.
4. Press **Stop and restore lights** when finished. WizCinema restores the
   pre-session state it read at Start.

The conservative defaults (8–65% brightness and medium responsiveness) are
intended for movie watching. Increase sensitivity for music-style reactions.

## Troubleshooting

- **No light found:** confirm the Mac and lights use the same non-guest LAN;
  turn on WiZ local communication where relevant; disable client isolation;
  allow WiZ UDP 38899 and LIFX UDP 56700 across a VLAN; or use the WiZ manual
  IP field. DHCP reservations help if IPs change often.
- **Permission/capture error:** grant System Audio Recording to the app, quit
  and reopen it. The packaged `.app` is important: launching the bare command
  line binary makes privacy permission management less clear on recent macOS.
- **Meters move but bulbs do not:** rediscover them; check the brand's local
  control setting and Wi-Fi signal. Local light control treats your LAN as the
  trust boundary, so keep the network private.
- **Meters never move for one service:** the player may be protecting its
  audio. This is a limitation imposed by that service, not a WiZ issue.

WiZ's built-in phone/tablet **Music Sync** is a simpler fallback. It listens
through the phone microphone, so it does not offer direct Mac-audio capture and
is not ideal with headphones.

## Privacy

All soundtrack analysis happens in memory on this Mac. WizCinema does not see,
save, record, upload, or transmit your screen or audio. WiZ and LIFX control
traffic is local UDP sent only to the lights you choose. Hue bridge discovery
only asks Hue's official discovery endpoint for a local bridge address; it
never sends soundtrack data.
