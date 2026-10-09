import CoreGraphics
import CoreWLAN
import Foundation

// Read display capabilities without changing modes or exposing device identities.
func readCommand(_ executable: String, _ arguments: [String]) -> Data? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    } catch { return nil }
}

func modeRecord(_ mode: CGDisplayMode) -> [String: Any] {
    ["logical_width": mode.width, "logical_height": mode.height,
     "pixel_width": mode.pixelWidth, "pixel_height": mode.pixelHeight,
     "refresh_hz": mode.refreshRate,
     "usable_for_desktop": mode.isUsableForDesktopGUI()]
}

var result: [String: Any] = ["source": "CoreGraphics and system_profiler", "changes_made": false]
let os = ProcessInfo.processInfo.operatingSystemVersion
result["macos_version"] = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
if let data = readCommand("/usr/sbin/sysctl", ["-n", "hw.model"]),
   let model = String(data: data, encoding: .utf8) {
    result["hardware_model"] = model.trimmingCharacters(in: .whitespacesAndNewlines)
}

var airPlayIDs: Set<CGDirectDisplayID> = []
if let data = readCommand("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"]),
   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let gpus = object["SPDisplaysDataType"] as? [[String: Any]] {
    result["gpu_models"] = gpus.compactMap { $0["sppci_model"] as? String }
    for gpu in gpus {
        for display in gpu["spdisplays_ndrvs"] as? [[String: Any]] ?? [] {
            guard display["spdisplays_connection_type"] as? String == "spdisplays_airplay",
                  let identifier = display["_spdisplays_displayID"] as? String,
                  let number = UInt32(identifier) else { continue }
            airPlayIDs.insert(number)
        }
    }
}

var displays: [[String: Any]] = []
for identifier in airPlayIDs.sorted() {
    var display: [String: Any] = [
        "connection": "airplay", "online": CGDisplayIsOnline(identifier) != 0,
        "is_main": CGDisplayIsMain(identifier) != 0,
        "mirroring": CGDisplayIsInMirrorSet(identifier) != 0
    ]
    if let current = CGDisplayCopyDisplayMode(identifier) { display["current_mode"] = modeRecord(current) }
    if let modes = CGDisplayCopyAllDisplayModes(identifier, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] {
        var seen = Set<String>()
        display["available_modes"] = modes.compactMap { mode -> [String: Any]? in
            let key = "\(mode.width)x\(mode.height):\(mode.pixelWidth)x\(mode.pixelHeight):\(mode.refreshRate)"
            return seen.insert(key).inserted ? modeRecord(mode) : nil
        }.sorted {
            let a = ($0["pixel_width"] as? Int ?? 0) * ($0["pixel_height"] as? Int ?? 0)
            let b = ($1["pixel_width"] as? Int ?? 0) * ($1["pixel_height"] as? Int ?? 0)
            return a < b
        }
    }
    displays.append(display)
}
result["airplay_displays"] = displays
let defaultAudio = AudioRouting.currentDefaultOutputID()
result["audio_outputs"] = AudioRouting.outputs().map { output -> [String: Any] in
    let kind = output.isBuiltIn ? "built_in" : (output.isAirPlay ? "airplay" : "other")
    return ["kind": kind, "is_default": output.id == defaultAudio]
}
if let interface = CWWiFiClient.shared().interface(), interface.powerOn() {
    var link: [String: Any] = ["source": "CoreWLAN", "limits": "Radio link readings describe the Mac-to-access-point link, not TV delivery or available throughput."]
    let signal = interface.rssiValue()
    let noise = interface.noiseMeasurement()
    let rate = interface.transmitRate()
    if (-120..<0).contains(signal) { link["rssi_dbm"] = signal }
    if (-120..<0).contains(noise) { link["noise_dbm"] = noise }
    if rate > 0 && rate.isFinite { link["reported_transmit_rate_mbps"] = rate }
    if let channel = interface.wlanChannel() {
        let bands = [1: "2.4 GHz", 2: "5 GHz", 3: "6 GHz"]
        link["band"] = bands[channel.channelBand.rawValue] ?? "unknown"
    }
    result["wifi_link"] = link
}
result["limits"] = ["A reported display refresh rate is not a measured delivered video frame rate.",
                    "Available modes do not establish stream bitrate, codec, chroma, or visible latency."]
if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
