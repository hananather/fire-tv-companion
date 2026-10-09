# AirPlay quality and lag

Start with the TV as an extended display at **1920 × 1080, 60 Hz**. This is the connected mode verified on 9 October 2026. Use the TV for reference material, a dashboard, or a video while working on the Mac. Fire TV Companion controls the TV; macOS controls AirPlay encoding, buffering, and display modes.

The verified setup was an Apple M4 Pro Mac running macOS 26.6.2 and an Amazon Fire TV Omni 50-inch television, model 4K50M600C, running Fire OS 7. The [dated baseline](evidence/airplay-baseline-2026-10-09.json) records the live display modes and a small LAN check. No visible screen latency was measured and no latency reduction is claimed.

## Choose a profile

| Use | Profile | Reason and boundary |
| --- | --- | --- |
| Work, reference pages, dashboard | Extend at 1080p, 60 Hz | Verified connected mode; keeps a separate Mac workspace. |
| Test whether a busy screen feels more responsive | Extend at 720p, 60 Hz | A reversible experiment with fewer source pixels. Text becomes less detailed. A lower setting is not proof of lower latency. |
| Put a local video on the TV desktop | Extend → Video → Show on TV | Both placement buttons and advancing test-video frames on the TV desktop passed the local app check. Audio follows the Mac's selected media output; audible sound needs a listening check. |
| Test direct video streaming | TV Video → AirPlay | A native AVPlayer capability. External media playback was not active in the observed session; confirm **AirPlay media output** and check the TV picture and sound before relying on it. |
| Need crisp text or immediate pointer response | HDMI extended display | A separate wired option when wireless delay is unacceptable. Verify the cable, input, and available modes. |
| 4K wireless desktop | Only when macOS actually offers it | The captured session's largest 16:9 pixel mode was 1920 × 1080. The TV's 4K panel and advertised receiver maximum do not establish a 4K AirPlay desktop mode. |

On the Mac, use **Control Center → Screen Mirroring → TV → Extend**. In **System Settings → Displays**, select the TV to change its resolution. A “looks like” size may differ from the pixel size; the diagnostics below record both. Apple documents [mirror, extend, and window sharing](https://support.apple.com/guide/mac-help/stream-video-and-audio-with-airplay-mchld7e543a0/26/mac/26) and [resolution controls](https://support.apple.com/guide/mac-help/change-your-displays-resolution-mchl86d72b76/mac).

The menu-bar **Dashboard** launcher opens your existing calendar and task apps or saved HTTPS pages. Place those apps with their native Window menus; the companion does not arrange other applications' windows. Close the remote when you no longer need it and reopen it from the TV menu-bar icon. The optional **Keep awake during TV session** toggle requests idle-display-sleep prevention while a TV session is active. It is off by default and does not change AirPlay's encoding or buffering.

## Change one thing at a time

Next, compare **1080p versus 720p**, with the same content, network, and TV settings. Both were listed by the live CoreGraphics API at 60 Hz. Repeat the same scrolling and pointer movements for a minute at each setting, then restore 1080p unless the improvement outweighs the loss of text detail. Changing the resolution can briefly interrupt sharing.

For stronger evidence, temporarily mirror the same visible content on the Mac and TV and film both screens in one shot. Count camera frames between an abrupt change on the Mac and the matching change on the TV. At 120 camera frames per second, one camera frame represents about 8.3 ms. Repeat at least ten transitions per setting and report the median and range. This estimates display-to-display delay; camera sampling, scanout, and the Mac display add uncertainty. It is not a pure network or click-to-photon measurement. Restore Extend afterwards.

If stutter remains, try these changes individually:

1. Pause a large upload or download and repeat the same test. Keep the Mac and TV near the access point, with a clear radio path. A 5 GHz connection is a reasonable trial where signal strength is adequate; a weak connection can still perform poorly. Apple's [AirPlay deployment guidance](https://support.apple.com/en-nz/guide/deployment/dep9151c4ace/web) explains airtime contention and obstructions for Apple TV. Applying those radio principles to a Fire TV is an inference, not a Fire TV performance guarantee.
2. If convenient, connect the TV to the same router by Ethernet and repeat. Amazon lists dual-band 802.11ac and **10/100 Mbps Ethernet** for this [Omni generation](https://developer.amazon.com/docs/device-specs/device-specifications-fire-tv-edition-smart-tv-na.html). Wired networking can avoid a wireless hop; no improvement has been measured here.
3. Inspect Picture settings while AirPlay is active. If a Game or processing-off choice exists for that source, compare it and restore the previous choice if it does not help. Amazon's [Game/ALLM instructions](https://digprjsurvey.amazon.com/csad/help/node/TKzuYf5lqC4ZrJHYAM) describe supported **HDMI inputs**. They do not establish that Game mode changes this TV's internal AirPlay path.

Keep Wi-Fi available for discovery. If a VPN is active, confirm that it permits [local-network traffic](https://support.apple.com/guide/iphone/stream-video-and-audio-from-your-iphone-iphd668e80e6/ios). Native AirPlay does not need a receiver app installed on this supported TV. Avoid changing router channels, pairing state, or system network services as routine tuning steps.

## Read a baseline without changing the setup

From the repository folder, run:

```sh
./scripts/airplay-diagnostics.sh
```

To include five small LAN pings and three TCP handshakes, substitute the TV's local address:

```sh
./scripts/airplay-diagnostics.sh --host TV_LOCAL_IPV4 --output /tmp/airplay-baseline.json
```

This optional local-address argument is not included in the output. The helper requires macOS, Python 3, and Apple Command Line Tools. It compiles a native reader, lists the current and available AirPlay modes, reads available audio endpoints and Mac radio-link values, and keeps only allowlisted numeric screen-sender statistics. It sends no remote-control commands, makes no settings changes, performs no bandwidth test, and saves no raw system logs. The implementation was run on Apple silicon with macOS 26.6.2; Intel Macs and other macOS releases have not been tested.

Interpret the numbers narrowly:

- **LAN RTT** measures an ICMP round trip. **TCP connection time** measures a new connection to the receiver's control port. Neither measures video buffering or visible delay. Missing ping replies may be filtering.
- **Wi-Fi transmit rate** describes the Mac's radio link, not usable throughput to the TV.
- **60 Hz display mode** is a display capability, not an observation of 60 delivered frames each second.
- **Sender completion metrics**, when available after a disconnect, describe session setup, duration, and reported frame counters. Their meaning and availability can change with macOS. They are not a visible-latency measurement. No completion metrics were available in the captured baseline window.

Sound output is a separate choice; see [audio routing](audio.md).
