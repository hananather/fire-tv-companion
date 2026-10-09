# Keep the companion idle between actions

The companion uses native Mac windows and macOS AirPlay. macOS owns the display stream; the companion has no desktop-capture or encoder loop. Google Calendar, its browser, and video services have separate resource costs.

Version 0.2.1 opens the Google Calendar Dashboard launcher after pairing and loads remote controls only when requested. Its idle behavior is:

- TV discovery runs for up to 15 seconds when the paired remote is opened, or 30 seconds during first setup. It stops when the app loses focus, is hidden, is minimized, or closes. Retry starts another search. There is no recurring discovery or health-check timer.
- `--background` starts the menu-bar controls without creating the remote window, enumerating audio outputs, querying installed TV apps, or browsing for receivers. Opening Remote performs that work when needed.
- Closing Video pauses playback and releases its media item, player, observations, file access, and closed window controller. Reopening starts with no video selected. The player stays paused after a clip ends.
- Keep awake is off by default. An enabled request is released on Mac sleep or serious/critical thermal pressure, and can resume when conditions permit. It does not control the cooling system or the native AirPlay service.
- The app uses event notifications, reusable remote sessions, and bounded command recovery. The unused WebKit link was removed. Resource profiling is an optional command-line tool, outside the running app.

These changes follow Apple's guidance to [return to idle and suspend unnecessary work](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html). They do not establish a particular temperature reduction or battery-life gain.

## Observed idle use · October 9, 2026

Each sample lasted approximately 45 seconds on an M4 Pro MacBook Pro with 48 GB memory and macOS 26.6.2. The TV desktop reported 1920 × 1080 at 60 Hz; the built-in display reported 120 Hz. The Mac used battery power with Low Power Mode off.

| Sample | Companion CPU, one-core scale | Physical footprint | Resident memory | Thermal category |
| --- | ---: | ---: | ---: | --- |
| [0.2.0 baseline](evidence/resource-baseline-2026-10-09.json), Remote and Dashboard open | 0.0424% | 35.80–35.92 MiB | 101.41–101.56 MiB | Nominal |
| [Intermediate 0.2.1](evidence/resource-after-2026-10-09.json), hidden before the Google Calendar-only change | 0.0112% | 27.55–27.67 MiB | 92.78–92.98 MiB | Nominal |
| [Final 0.2.1](evidence/resource-google-calendar-2026-10-09.json), hidden after Remote and Video checks, Google Calendar on TV | 0.0167% | 52.70–52.80 MiB | 145.81–146.05 MiB | Nominal |

The final sample recorded ten companion readings, no package idle wakeups, and no active companion keep-awake assertion. Source-file hashes in that report identify the measured build inputs. The app had already opened and closed its video player; framework caches can remain in process memory after playback resources are released.

These are observations of different app states and workloads, not a controlled before/after comparison. They support low companion activity during this idle interval. They do not prove lower heat, battery use, or visible latency. Google Calendar shares Chrome processes with other pages, so the browser totals do not isolate the calendar's cost. Shared AirPlay and WindowServer CPU counters were unavailable; their cost is not included in the companion figure.

## Measure without running a permanent monitor

Build the passive helper once, then take a bounded sample after the compiler has finished:

```sh
./scripts/resource-profile.sh --build-helper /tmp/fire-tv-resource-profiler
/tmp/fire-tv-resource-profiler --duration 45 --interval 5 --scenario dashboard --output /tmp/fire-tv-resources.json
```

The helper reads allowlisted process counters, memory, thermal categories, display dimensions, power-source status, and assertion counts. It makes no network requests, changes no settings, and saves no process paths, arguments, credentials, or calendar contents. Missing permissions produce unavailable fields. It exits after sampling.

CPU percentages are reported on a one-core scale: 100% means one CPU occupied for the interval. Resident memory includes shared pages; physical footprint is macOS's task-accounted memory. Apple's [thermal-state categories](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum) are status categories, not temperatures. This helper measures neither watts nor GPU utilization.

## Daily use

Keep one existing Google Calendar window on the TV and close the companion's unused windows. Dashboard focuses a running Google Calendar web app rather than opening another page. Its browser fallback offers **Return to browser** after the first open; **Open new calendar page** remains explicit. Pause or close a video when you return to your calendar. Closing the companion's remote does not disconnect the native AirPlay desktop. Use the TV icon to reopen controls.

The tested TV desktop remains 1080p at 60 Hz. Lower-resolution and wired alternatives are described in [display tuning](tuning.md); no resolution or system-wide power mode is silently changed by the companion. macOS's [Low Power Mode](https://support.apple.com/en-us/101613) is an optional Mac-wide choice when lower power consumption takes priority over maximum performance.
