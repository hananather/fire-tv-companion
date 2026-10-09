# Local app check · October 9, 2026

The installed 0.2.0 app was built from this source and reopened after installation on an M4 Pro MacBook Pro running macOS 26.6.2. The receiver was a 2022-generation Fire TV Omni 50-inch, model 4K50M600C. These observations cover this setup.

| Check | Observation |
| --- | --- |
| Separate desktop | macOS reported 1920 × 1080 at 60 Hz, extended, alongside the built-in and wired displays. The user confirmed the TV picture worked. |
| Saved remote pairing | Restarted app selected the paired TV and loaded installed apps without another remote PIN. |
| Remote service and volume | Wake request and volume-down/up requests succeeded. The volume requests were reversed to preserve the prior level. Physical panel wake and audible volume changes were not observed. |
| Display matching | A unique selected-TV name, including macOS's added ` (AirPlay)` suffix, matched the connected TV. A nonexistent name returned no match; the wired monitor was not selected. |
| Video window placement | Show on TV moved the player to the TV desktop; Bring back returned it to the Mac. |
| Local video | Play reported Playing on the TV desktop. The generated clip advanced from its first frame to its final frame at 14.967 seconds. This was observed in the Mac's TV-display window capture; no camera measurement of the physical panel was made. |
| Audio selection | The picker switched to built-in speakers; a separate Core Audio read confirmed the default device. Selecting the TV again restored that output. No listening or dual-speaker synchronization test was performed. |
| Dashboard launcher | Detected installed Notion Calendar and Notion. Open Calendar successfully opened the existing app. An existing calendar window was placed on the TV using native macOS window controls without editing events. |
| Background lifecycle | Closing the remote left Fire TV Companion running. Reopening the installed app restored the remote controls. |
| Build and tests | Local Swift core checks, diagnostics privacy tests, app compilation, and strict local-signature verification passed. |

The app improves repeated use through saved pairing, reusable remote sessions, bounded availability recovery, and direct access to native display and audio controls. These changes do not demonstrate lower visible AirPlay latency. Native display reconnection and other apps' window placement use macOS controls.

The build targets Apple silicon and macOS 15 or later. Compilation on a hosted macOS runner does not verify a physical television, a different Mac, or a different network. The dated [network and display baseline](evidence/airplay-baseline-2026-10-09.json) contains sanitized measurements, not device names, addresses, or pairing credentials.

[GitHub build and test run 37991542290](https://github.com/hananather/fire-tv-companion/actions/runs/37991542290) passed on macOS 15 and 26 for source commit `28399c3a6a64f3af08ca2dc73fdfec0a47ae56bb`. Both runners compiled the core tests and app, ran diagnostics privacy tests, and produced an app ZIP. Later documentation updates do not change those tested source files.
