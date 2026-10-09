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

## Version 0.2.1 · October 9, 2026

The final installed build was checked on the same Mac and TV, with the built-in display and the 1080p, 60 Hz extended TV desktop connected. The wired monitor was absent during these checks.

| Check | Observation |
| --- | --- |
| Paired launch | A fresh process opened the Google Calendar-only Dashboard without opening Remote. Dashboard reported TV connected, extended desktop. |
| Google Calendar | Installed the official calendar site as a Chrome web app using the existing signed-in profile. Native Window controls moved its window to the TV and filled that display. Calendar contents were not edited. |
| Repeated calendar actions | Two Dashboard presses activated the same Google Calendar app. The native app exposed one calendar window and the browser inventory retained one calendar page. |
| Saved pairing | Opening Remote loaded installed TV apps without another PIN. This check did not send a navigation or volume command. |
| End and replay | The generated clip reached 15 seconds and paused. Play returned the timeline to zero and reported Playing. |
| Minimized Video | Window → Video restored the minimized player with playback advancing. |
| Closed Video | Closing during playback and reopening produced an empty player. Loading the generated clip again played successfully; closing it released the item again. |
| Idle profile | With Remote and Video closed, the companion hidden, and Google Calendar visible on TV, the [45-second report](evidence/resource-google-calendar-2026-10-09.json) recorded 0.0167% of one CPU core and 52.70–52.80 MiB physical footprint. Thermal category remained nominal. |
| Local checks | Swift core lifecycle checks, two diagnostics privacy tests, app compilation, optional profiler compilation, and strict local-signature verification passed. |

Thermal-pressure and sleep handlers were reviewed in source; no forced heating or sleep test was performed. The short idle sample does not certify sustained temperature, energy consumption, or AirPlay latency. The earlier 0.2.0 observations above remain dated evidence for that version.

[GitHub build and test run 37996284123](https://github.com/hananather/fire-tv-companion/actions/runs/37996284123) passed on macOS 15 and 26 for source commit `93cb7d7852aafbfc51534a155a3232414875615d`. Both runners passed the Swift core and diagnostics checks, compiled the app and optional profiler, and produced an app ZIP. The subsequent documentation commit adds this evidence link without changing the measured or tested source files.
