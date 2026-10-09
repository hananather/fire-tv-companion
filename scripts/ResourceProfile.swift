import Darwin
import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import IOKit.ps

// Passive, bounded sampling. Process names are classified in memory; paths,
// arguments, assertion reasons, and power-source names never enter the report.
struct ResourceReading {
    let cpuTicks: UInt64
    let residentBytes: UInt64
    let footprintBytes: UInt64
    let idleWakeups: UInt64
    let interruptWakeups: UInt64
    let startTicks: UInt64
}

struct TrackedProcess {
    let pid: Int32
    let group: String
    let first: ResourceReading
    let firstTime: Double
    var last: ResourceReading
    var lastTime: Double
    var residents: [UInt64]
    var footprints: [UInt64]
    var readings: Int
}

func processGroup(_ name: String) -> String? {
    switch name {
    case "Fire TV Companion": return "companion"
    case "AirPlayXPCHelper": return "airplay_service"
    case "WindowServer": return "window_server"
    case "VTEncoderXPCService": return "video_encoder_service"
    case "VTDecoderXPCService": return "video_decoder_service"
    case "Calendar", "calaccessd": return "calendar"
    default:
        if name == "Notion Calendar" || name.hasPrefix("Notion Calendar Helper") { return "calendar" }
        if name == "Safari" || name.hasPrefix("com.apple.Safari") || name == "Safari Web Content" ||
            name == "Google Chrome" || name.hasPrefix("Google Chrome Helper") ||
            name == "Microsoft Edge" || name.hasPrefix("Microsoft Edge Helper") ||
            name == "firefox" || name == "Firefox" || name.hasPrefix("FirefoxCP") { return "browser" }
        return nil
    }
}

func monitoredProcesses() -> [Int32: String] {
    let capacity = max(1024, Int(proc_listallpids(nil, 0)) + 256)
    var pids = [Int32](repeating: 0, count: capacity)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    var result: [Int32: String] = [:]
    for pid in pids.prefix(min(max(0, Int(count)), capacity)) where pid > 0 {
        var name = [CChar](repeating: 0, count: 1024)
        let length = name.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0, let group = processGroup(String(cString: name)) else { continue }
        result[pid] = group
    }
    // libproc may refuse even the name of another user's process. ps's ucomm
    // field exposes only the short executable name, with no path or arguments.
    // Keep these two shared system services visible as unavailable, rather than
    // silently omitting them when their resource counters cannot be read.
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-A", "-o", "pid=", "-o", "ucomm="]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    if (try? process.run()) != nil {
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let lines = String(data: data, encoding: .utf8), process.terminationStatus == 0 {
            for line in lines.split(separator: "\n") {
                let columns = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
                guard columns.count == 2, let pid = Int32(columns[0]) else { continue }
                let name = columns[1].trimmingCharacters(in: .whitespaces)
                if name == "WindowServer" { result[pid] = "window_server" }
                if name == "AirPlayXPCHelper" { result[pid] = "airplay_service" }
            }
        }
    }
    return result
}

func usage(_ pid: Int32) -> ResourceReading? {
    var value = rusage_info_v2()
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
        }
    }
    guard status == 0 else { return nil }
    return ResourceReading(cpuTicks: value.ri_user_time + value.ri_system_time,
        residentBytes: value.ri_resident_size, footprintBytes: value.ri_phys_footprint,
        idleWakeups: value.ri_pkg_idle_wkups, interruptWakeups: value.ri_interrupt_wkups,
        startTicks: value.ri_proc_start_abstime)
}

func rounded(_ value: Double) -> Double { (value * 100_000).rounded() / 100_000 }
func counterDelta(_ end: UInt64, _ start: UInt64) -> UInt64 { end >= start ? end - start : 0 }
func memorySummary(_ bytes: [UInt64]) -> [String: Any] {
    let mib = 1024.0 * 1024.0
    return ["minimum_mib": rounded(Double(bytes.min() ?? 0) / mib),
        "maximum_mib": rounded(Double(bytes.max() ?? 0) / mib),
        "mean_mib": rounded(bytes.reduce(0.0) { $0 + Double($1) } / Double(max(1, bytes.count)) / mib),
        "last_mib": rounded(Double(bytes.last ?? 0) / mib)]
}

func thermalState() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

func displayState() -> [[String: Any]] {
    var identifiers = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(UInt32(identifiers.count), &identifiers, &count) == .success else { return [] }
    return identifiers.prefix(Int(count)).compactMap { identifier -> [String: Any]? in
        guard let mode = CGDisplayCopyDisplayMode(identifier) else { return nil }
        return ["built_in": CGDisplayIsBuiltin(identifier) != 0, "mirroring": CGDisplayIsInMirrorSet(identifier) != 0,
            "logical_width": mode.width, "logical_height": mode.height,
            "pixel_width": mode.pixelWidth, "pixel_height": mode.pixelHeight, "reported_refresh_hz": mode.refreshRate]
    }.sorted {
        let a = ($0["pixel_width"] as? Int ?? 0) * ($0["pixel_height"] as? Int ?? 0)
        let b = ($1["pixel_width"] as? Int ?? 0) * ($1["pixel_height"] as? Int ?? 0)
        return a < b
    }
}

func companionAppState(_ monitored: [Int32: String]) -> [[String: Any]] {
    monitored.filter { $0.value == "companion" }.keys.sorted().compactMap { pid in
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return ["pid": pid, "hidden": app.isHidden, "active": app.isActive, "terminated": app.isTerminated]
    }
}

func powerState() -> [String: Any] {
    var result: [String: Any] = ["low_power_mode_enabled": ProcessInfo.processInfo.isLowPowerModeEnabled]
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return result }
    if let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? {
        result["power_source"] = source == kIOPSACPowerValue ? "ac" : (source == kIOPSBatteryPowerValue ? "battery" : "other")
    }
    if let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
               let maximum = description[kIOPSMaxCapacityKey] as? NSNumber, maximum.doubleValue > 0 {
                result["battery_percent"] = rounded(current.doubleValue * 100 / maximum.doubleValue)
            }
            if let charging = description[kIOPSIsChargingKey] as? Bool { result["battery_charging"] = charging }
        }
    }
    return result
}

let assertionTypes: Set<String> = ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep",
    "PreventSystemSleep", "BackgroundTask", "UserIsActive", "ExternalMedia", "NetworkClientActive",
    "ApplePushServiceTask", "DisplayWake", "InternalPreventDisplaySleep"]

func assertionState(_ monitored: [Int32: String]) -> [String: Any] {
    var result: [String: Any] = [:]
    var global: Unmanaged<CFDictionary>?
    if IOPMCopyAssertionsStatus(&global) == kIOReturnSuccess, let values = global?.takeRetainedValue() as? [String: NSNumber] {
        result["system_levels"] = values.filter { assertionTypes.contains($0.key) }.mapValues { $0.intValue }
    }
    var byProcess: Unmanaged<CFDictionary>?
    if IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
       let values = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] {
        var groups: [String: [String: Int]] = [:]
        for (pid, assertions) in values {
            guard let group = monitored[pid.int32Value] else { continue }
            for assertion in assertions {
                guard let type = assertion[kIOPMAssertionTypeKey as String] as? String, assertionTypes.contains(type),
                      let level = assertion[kIOPMAssertionLevelKey as String] as? NSNumber, level.intValue > 0 else { continue }
                groups[group, default: [:]][type, default: 0] += 1
            }
        }
        result["monitored_group_active_counts"] = groups
    }
    return result
}

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

let requestedDuration = Double(argument("--duration") ?? "45") ?? 0
let interval = Double(argument("--interval") ?? "5") ?? 0
let scenario = argument("--scenario") ?? "unspecified"
let scenarios: Set<String> = ["unspecified", "quiet-desktop", "dashboard", "video-window", "external-video"]
guard requestedDuration >= 1, requestedDuration <= 60, interval >= 1, interval <= requestedDuration,
      scenarios.contains(scenario) else {
    FileHandle.standardError.write(Data("Use --duration 1...60, --interval 1...duration, and --scenario quiet-desktop|dashboard|video-window|external-video|unspecified.\n".utf8))
    exit(2)
}

var timebase = mach_timebase_info_data_t()
guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { exit(1) }
let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
let cores = ProcessInfo.processInfo.activeProcessorCount
let startDate = Date()
let startTime = ProcessInfo.processInfo.systemUptime
let firstMonitored = monitoredProcesses()
let initialDisplays = displayState()
let initialPower = powerState()
let initialAssertions = assertionState(firstMonitored)
let initialAppState = companionAppState(firstMonitored)
var tracked: [String: TrackedProcess] = [:]
var timeline: [[String: Any]] = []
var readFailures: [String: Int] = [:]
var observedCounts: [String: Int] = [:]

while true {
    let now = ProcessInfo.processInfo.systemUptime
    let monitored = monitoredProcesses()
    var counts: [String: Int] = [:]
    var groupResident: [String: Double] = [:]
    var groupFootprint: [String: Double] = [:]
    for (pid, group) in monitored {
        counts[group, default: 0] += 1
        guard let reading = usage(pid) else { readFailures[group, default: 0] += 1; continue }
        let readingTime = ProcessInfo.processInfo.systemUptime
        let key = "\(pid):\(reading.startTicks)"
        groupResident[group, default: 0] += Double(reading.residentBytes) / 1_048_576
        groupFootprint[group, default: 0] += Double(reading.footprintBytes) / 1_048_576
        if var process = tracked[key] {
            process.last = reading
            process.lastTime = readingTime
            process.residents.append(reading.residentBytes)
            process.footprints.append(reading.footprintBytes)
            process.readings += 1
            tracked[key] = process
        } else {
            tracked[key] = TrackedProcess(pid: pid, group: group, first: reading, firstTime: readingTime,
                last: reading, lastTime: readingTime, residents: [reading.residentBytes], footprints: [reading.footprintBytes], readings: 1)
        }
    }
    for (group, count) in counts { observedCounts[group] = max(observedCounts[group] ?? 0, count) }
    timeline.append(["elapsed_seconds": rounded(now - startTime), "thermal_state": thermalState(),
        "low_power_mode_enabled": ProcessInfo.processInfo.isLowPowerModeEnabled,
        "process_counts": counts, "summed_resident_mib": groupResident.mapValues(rounded),
        "summed_physical_footprint_mib": groupFootprint.mapValues(rounded)])
    let remaining = requestedDuration - (ProcessInfo.processInfo.systemUptime - startTime)
    if remaining <= 0 { break }
    Thread.sleep(forTimeInterval: min(interval, remaining))
}

let elapsed = ProcessInfo.processInfo.systemUptime - startTime
var processRecords: [[String: Any]] = []
var totals: [String: Double] = [:]
var completeCounts: [String: Int] = [:]
for process in tracked.values.sorted(by: { $0.group == $1.group ? $0.pid < $1.pid : $0.group < $1.group }) {
    let seconds = Double(counterDelta(process.last.cpuTicks, process.first.cpuTicks)) * secondsPerTick
    let observed = process.lastTime - process.firstTime
    let coverage = observed / elapsed
    let oneCorePercent = observed > 0 ? seconds / observed * 100 : 0
    let complete = coverage >= 0.99 && process.readings == timeline.count
    if complete { completeCounts[process.group, default: 0] += 1 }
    totals[process.group, default: 0] += seconds
    processRecords.append(["group": process.group, "pid": process.pid,
        "observed_seconds": rounded(observed), "full_interval_observed": complete,
        "cpu_seconds": rounded(seconds), "cpu_percent_one_core": rounded(oneCorePercent),
        "cpu_percent_all_active_cores": rounded(oneCorePercent / Double(max(1, cores))),
        "resident_memory": memorySummary(process.residents), "physical_footprint": memorySummary(process.footprints),
        "package_idle_wakeups_delta": counterDelta(process.last.idleWakeups, process.first.idleWakeups),
        "interrupt_wakeups_delta": counterDelta(process.last.interruptWakeups, process.first.interruptWakeups),
        "readings": process.readings])
}

let groups = Set(observedCounts.keys).union(readFailures.keys)
let groupRecords = groups.sorted().map { group -> [String: Any] in
    let seconds = totals[group] ?? 0
    let percentage = seconds / elapsed * 100
    let usableDeltas = tracked.values.filter { $0.group == group && $0.readings > 1 }.count
    return ["group": group, "maximum_observed_process_count": observedCounts[group] ?? 0,
        "full_interval_process_count": completeCounts[group] ?? 0,
        "cpu_counters_available": usableDeltas > 0,
        "unavailable_usage_reads": readFailures[group] ?? 0,
        "observed_cpu_seconds": usableDeltas > 0 ? rounded(seconds) as Any : NSNull(),
        "observed_cpu_percent_one_core": usableDeltas > 0 ? rounded(percentage) as Any : NSNull(),
        "observed_cpu_percent_all_active_cores": usableDeltas > 0 ? rounded(percentage / Double(max(1, cores))) as Any : NSNull()]
}
let os = ProcessInfo.processInfo.operatingSystemVersion
var report: [String: Any] = [
    "schema_version": 1, "captured_at_utc": ISO8601DateFormatter().string(from: startDate),
    "finished_at_utc": ISO8601DateFormatter().string(from: Date()),
    "source": "libproc proc_pid_rusage RUSAGE_INFO_V2, ProcessInfo, IOKit power-source and assertion read APIs",
    "changes_made": false, "requested_duration_seconds": requestedDuration,
    "actual_elapsed_seconds": rounded(elapsed), "sample_interval_seconds": interval,
    "scenario": scenario, "macos_version": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
    "active_processor_count": cores, "power_at_start": initialPower, "power_at_end": powerState(),
    "companion_app_at_start": initialAppState, "companion_app_at_end": companionAppState(monitoredProcesses()),
    "process_timestamp_reference": "immediately after each successful usage read",
    "displays_at_start": initialDisplays, "displays_at_end": displayState(),
    "assertions_at_start": initialAssertions, "assertions_at_end": assertionState(monitoredProcesses()),
    "groups": groupRecords, "processes": processRecords, "samples": timeline,
    "limits": ["CPU percentages use measured CPU-counter deltas:100% on the one-core scale means one logical CPU occupied for the interval. The all-active-cores scale divides by active processor count; it does not weight performance and efficiency cores.",
        "AirPlay, WindowServer, and VideoToolbox are shared services. Their complete process totals cannot be attributed to this app or this television.",
        "Process access may be denied. Missing usage is reported as unavailable reads, never as measured zero CPU. Exited or newly started processes have partial coverage; their unobserved work is omitted.",
        "Resident memory may include shared pages; summing processes can double-count them. Physical footprint is task-accounted memory, not private heap size. Sampled maxima can miss peaks between readings.",
        "Thermal state is a system status category, not a temperature. These data do not measure watts, visible latency, audio delay, or GPU/encoder utilization. Display snapshots omit device identities and connection types; reported refresh is not measured delivered frame rate.",
        "AppKit hidden and active flags describe application state; they do not establish App Nap or whether every individual window is visible.",
        "The profiler performs light process and power reads, has no network requests or control actions, and remains separate from the companion and shared-service totals. Process names are matched to a fixed allowlist; unlisted apps are omitted."]]
if let output = argument("--output") {
    report["output_saved"] = true
    do {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: output), options: .atomic)
    } catch {
        FileHandle.standardError.write(Data("The sanitized report could not be saved.\n".utf8)); exit(1)
    }
}
else if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}
