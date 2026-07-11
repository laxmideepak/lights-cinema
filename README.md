# WizCinema

WizCinema is a small native macOS app that makes WiZ lights respond gently to
the sound playing on your Mac. It captures system audio with Apple's Core Audio
tap API, analyzes it locally, and sends low-latency WiZ commands over your
home Wi-Fi. It does not need BlackHole, Loopback, a Hue bridge, or a cloud API.

## Requirements

- macOS 15 or later (the Core Audio tap itself was introduced in macOS 14.2)
- WiZ lights already paired in the WiZ app and on the same Wi-Fi as the Mac
- In WiZ: **Settings → Security → Allow local communication** switched on
- A non-guest Wi-Fi network that allows UDP port `38899` to the lights

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
If it was denied, enable WizCinema under **System Settings → Privacy & Security
→ Screen & System Audio Recording**, then quit and reopen the app.

## Use

1. Select **Discover**. WiZ bulbs on this Mac's Wi-Fi appear after a few
   seconds. If broadcast discovery is blocked, enter a bulb's IP address.
2. Tick the bulbs you want to use, then choose a palette and brightness range.
3. Press **Start cinema sync** and play a film. The app sends at most ten
   coalesced updates per second to each light; it avoids flashes and never
   power-cycles the bulbs in quiet scenes.
4. Press **Stop and restore lights** when finished. WizCinema restores the
   pre-session state it read at Start.

The conservative defaults (8–65% brightness and medium responsiveness) are
intended for movie watching. Increase sensitivity for music-style reactions.

## Troubleshooting

- **No light found:** confirm the Mac and lights use the same non-guest LAN;
  turn on WiZ local communication; disable client isolation; allow UDP 38899
  across a VLAN; or use the manual IP field. DHCP reservations help if IPs
  change often.
- **Permission/capture error:** grant System Audio Recording to the app, quit
  and reopen it. The packaged `.app` is important: launching the bare command
  line binary makes privacy permission management less clear on recent macOS.
- **Meters move but bulbs do not:** rediscover them; check the WiZ security
  toggle and Wi-Fi signal. WiZ local control treats your LAN as the trust
  boundary, so keep the network private.
- **Meters never move for one service:** the player may be protecting its
  audio. This is a limitation imposed by that service, not a WiZ issue.

WiZ's built-in phone/tablet **Music Sync** is a simpler fallback. It listens
through the phone microphone, so it does not offer direct Mac-audio capture and
is not ideal with headphones.

## Privacy

All audio analysis happens in memory on this Mac. WizCinema does not save,
record, upload, or transmit audio. The only network traffic is local UDP control
messages to the WiZ light addresses you choose.
