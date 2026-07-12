# WizCinema

WizCinema is a native macOS movie-ambience app. It captures system audio with
Apple's Core Audio tap API, analyzes it locally, and makes compatible lights
respond gently. It supports WiZ directly and can also discover compatible
mixed-brand devices through a local Home Assistant hub. It does not need
BlackHole, Loopback, a Hue bridge, or a cloud API for WiZ.

## Requirements

- macOS 15 or later (the Core Audio tap itself was introduced in macOS 14.2)
- WiZ lights already paired in the WiZ app and on the same Wi-Fi as the Mac
- In WiZ: **Settings → Security → Allow local communication** switched on
- A non-guest Wi-Fi network that allows UDP port `38899` to the lights

### Mixed-brand devices with Home Assistant

For the broadest device coverage, install Home Assistant on your own local
network and add your Matter, Zigbee, HomeKit-compatible, Sonos, TV, receiver,
shade, fan, and vendor-integrated devices there. In WizCinema, enter the local
Home Assistant URL and a **Long-Lived Access Token**. The token is saved only
in this Mac's Keychain, never in the project, logs, or UserDefaults.

WizCinema discovers lights, media players, safe window treatments, fans, and
switches that Home Assistant exposes. Only selected colour-capable lights
receive continuous soundtrack-driven colour/brightness updates. The app
deliberately never automates locks, garages, doors, gates, alarms, cameras,
water, cooking appliances, or HVAC. Speakers, window shades, and fans can be
given a one-time, explicit cinema setting in the app; they are never driven
rapidly by soundtrack volume. Generic switches remain observe-only because a
switch may represent an unknown appliance.

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

To validate audio capture without changing any lights, start a film (or another
audio source) and run this from Terminal:

```sh
dist/WizCinema.app/Contents/MacOS/WizCinema --audio-probe
```

It listens for five seconds, reports the detected energy/frequency mix, and
does not send any WiZ commands. If it reports no samples, grant System Audio
Recording permission and try again.

For a temporary whole-pipeline check, `--sync-probe` discovers every reachable
WiZ bulb, saves each readable state, reacts to audio for five seconds, then
sends the saved states back. It is intended for troubleshooting only because it
briefly changes those lights:

```sh
dist/WizCinema.app/Contents/MacOS/WizCinema --sync-probe
```

## Use

1. Select **Discover**. WiZ bulbs on this Mac's Wi-Fi appear after a few
   seconds. If broadcast discovery is blocked, enter a bulb's IP address.
2. Tick the bulbs you want to use, then choose a palette and brightness range.
3. Press **Start cinema sync** and play a film. The app sends at most ten
   coalesced updates per second to each light; it avoids flashes and never
   power-cycles the bulbs in quiet scenes.
4. Press **Stop and restore lights** when finished. WizCinema restores the
   pre-session state it read at Start.

To add Home Assistant devices, use the **Home Assistant — mixed-brand devices**
section: enter the hub URL and token, choose **Connect**, then select the
colour-capable lights you want to join live ambience. For a speaker, safe
window shade, or fan, select it, choose its matching role, set the desired
level, and press **Apply selected cinema settings**. This is a single explicit
action, not an automatic soundtrack command. Non-light devices begin
unselected.

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
- **Home Assistant cannot connect:** use its local URL (for example
  `http://homeassistant.local:8123`), ensure the Mac can reach it, and create a
  new Long-Lived Access Token in the Home Assistant profile page. HTTP is
  accepted only for a user-selected local hub; prefer HTTPS for remote access.

WiZ's built-in phone/tablet **Music Sync** is a simpler fallback. It listens
through the phone microphone, so it does not offer direct Mac-audio capture and
is not ideal with headphones.

## Privacy

All audio analysis happens in memory on this Mac. WizCinema does not save,
record, upload, or transmit audio. The only network traffic is local UDP control
messages to the WiZ light addresses you choose.
