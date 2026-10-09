# Fire TV Companion

A Mac menu-bar app for controlling an Amazon Fire TV, opening existing calendar and task apps, and playing local video on an AirPlay desktop.

The first working setup used an M4 Pro MacBook Pro and a 50-inch Fire TV Omni purchased in 2022. macOS reported a **1920 × 1080, 60 Hz extended AirPlay display**, alongside the built-in screen and a wired Dell display. Remote pairing, installed-app discovery, Home commands, and volume commands were accepted by that TV.

macOS provides the native AirPlay desktop. The companion's local remote uses the TV's community-documented Lightning interface; its Dashboard launcher opens your existing apps and browser pages.

## Install

Use an Apple-silicon Mac with macOS 15 or later, Apple's Command Line Tools, and an AirPlay-capable Fire TV television on the same local network.

```sh
xcode-select --install
git clone https://github.com/hananather/fire-tv-companion.git
cd fire-tv-companion
./install.sh
```

The installer builds the app locally, places it in `~/Applications`, and opens it. Subsequent launches do not need the source folder or compiler. Builds are locally signed; this project does not currently ship a notarized installer.

## First connection

1. Switch the TV on and enable **Settings → Display & Audio → AirPlay & HomeKit → AirPlay**.
2. Open Fire TV Companion, allow Local Network access, and choose your TV. Pair its remote using the code shown on the TV.
3. Connect the Mac's AirPlay display through **Screen Mirroring** or **System Settings → Displays → + → your TV**. Choose **Use as Extended Display**.
4. If the TV appears in the app but is missing from Displays, open the app's video player, choose the TV through its native AirPlay picker, and complete the separate AirPlay pairing. Then check Displays again. This resolved discovery on the tested setup.

Remote pairing and AirPlay pairing are separate. The companion saves its remote pairing privately in `~/Library/Application Support/Fire TV Companion/pairing.json`. Use macOS Screen Mirroring to connect or reconnect the TV display.

## Daily use

The TV icon in the menu bar opens **Remote**, **Dashboard**, **Video**, **Display settings**, and **Sound settings**. Closing the remote window leaves the app running in the menu bar; **Quit** exits it. Remote keyboard navigation uses arrows, Return, and Space only while the remote pad has focus. The app assigns no Fn shortcut.

**Dashboard** opens installed calendar and task apps, including Notion Calendar or Apple Calendar and Notion, Reminders, or Linear. You can save two optional HTTPS page links, which open in your default browser's existing signed-in session. App choices and links stay in this Mac's preferences. In each opened app, use its native **Window → Move to your TV** and **Fill** controls, or **Move & Resize → Left / Right** for a side-by-side layout. The launcher keeps your existing data in its original apps; window placement and reconnection remain native macOS actions.

**Video** opens a local file in the **TV Video** window. Press **Play** to start it. With the selected TV connected as an extended display, **Show on TV** moves this app's video window there, and **Bring back** returns it to the Mac. Both placement controls and advancing video frames on the TV desktop passed the local app check. The separate native AirPlay picker offers AVPlayer media routing, which was not verified as active in this session.

**Keep awake during TV session** is an explicit menu-bar toggle, off by default. While enabled, it asks macOS to prevent idle display sleep when the selected TV display or the player's TV session is active. Turning it off, ending that session, or quitting releases the request.

To start a new app process without opening the remote window:

```sh
open -a "$HOME/Applications/Fire TV Companion.app" --args --background
```

The remote provides navigation, Home, Back, Menu, play/pause, volume, installed-app launching, and text entry into the TV's active input. The wake action starts the TV's remote service; physical panel wake depends on the TV's firmware and state.

See [display tuning](docs/tuning.md) for measured conditions and lag tests, and [audio configurations](docs/audio.md) for speaker choices.

## Evidence and limits

The end-to-end connection was observed on **macOS 26.6.2, M4 Pro, Fire TV Omni model 4K50M600C** on October 9, 2026. Other Macs and televisions require their own connection test. Native AirPlay support varies by Fire TV model; a Fire TV Stick does not provide the same native display setup.

The TV's advertised 4K media capability does not establish a 4K Mac desktop. The tested AirPlay display exposed 1920 × 1080 as its largest 16:9 pixel mode. LAN round-trip measurements also do not establish input-to-picture latency. No measured lag-reduction percentage is claimed.

An independent iPhone AirPlay session can replace the TV's Mac output. Protected video services may require their native TV apps. The remote interface is community documented and can change with firmware.

## Build and test

```sh
./build.sh --test
./build.sh
```

The app is written in Swift and uses macOS frameworks. It has no package-manager dependencies. The build script contains an isolated workaround for a duplicate SwiftBridging module map left by some Command Line Tools upgrades; it does not edit developer tools.

Automated checks cover the local connection core, sanitized diagnostics, and compilation. They do not operate a physical TV. The [dated baseline](docs/evidence/airplay-baseline-2026-10-09.json) records display and network conditions; the [local app check](docs/verification.md) records the later UI checks and their limits. The bundled test clip is a generated color-bar animation and quiet tone, with no user media.

## Sources

- [Apple: AirPlay video, mirroring, and extended displays](https://support.apple.com/guide/mac-help/stream-video-and-audio-with-airplay-mchld7e543a0/26/mac/26)
- [Amazon: AirPlay on Fire TV televisions](https://digprjsurvey.amazon.co.uk/csad/help/node/GFAK8J5CYN5T76ET)
- [FireTVRest: local remote protocol](https://github.com/SLC-Josh/FireTVRest)
- [HMS FireTV: maintained Lightning implementation](https://github.com/hms-homelab/hms-firetv)

MIT licensed. Copyright 2026 Hanan Ather.
