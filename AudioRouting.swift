import CoreAudio
import Foundation

struct AudioOutput {
    let id: UInt32
    let name: String
    let isBuiltIn: Bool
    let isAirPlay: Bool
}

enum AudioRoutingError: LocalizedError {
    case outputUnavailable, selectionUnsupported, systemError(OSStatus), selectionDidNotApply

    var errorDescription: String? {
        switch self {
        case .outputUnavailable:
            return "This audio output is no longer available. Refresh the list and try again."
        case .selectionUnsupported:
            return "macOS cannot select this output here. Choose it in Sound settings."
        case .systemError(let status):
            return "macOS could not change the audio output (\(status)). Try Sound settings."
        case .selectionDidNotApply:
            return "macOS did not keep this audio output selected. Choose it in Sound settings."
        }
    }
}

enum AudioRouting {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func property(_ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func integer(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = property(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func name(_ device: AudioObjectID) -> String {
        var address = property(kAudioObjectPropertyName)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value = value else { return "Audio output" }
        return value.takeRetainedValue() as String
    }

    static func outputs() -> [AudioOutput] {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !devices.isEmpty else { return [] }
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return devices.compactMap { device -> AudioOutput? in
            var streams = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr,
                  streamSize > 0,
                  integer(device, kAudioDevicePropertyDeviceIsAlive) == 1,
                  integer(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioDevicePropertyScopeOutput) == 1 else { return nil }
            let transport = integer(device, kAudioDevicePropertyTransportType)
            return AudioOutput(id: device, name: name(device),
                               isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                               isAirPlay: transport == kAudioDeviceTransportTypeAirPlay)
        }.sorted { left, right in
            if left.isBuiltIn != right.isBuiltIn { return left.isBuiltIn }
            if left.isAirPlay != right.isAirPlay { return left.isAirPlay }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    static func currentDefaultOutputID() -> UInt32? {
        guard let identifier = integer(system, kAudioHardwarePropertyDefaultOutputDevice),
              identifier != kAudioObjectUnknown else { return nil }
        return identifier
    }

    // Called only after an explicit user selection. This does not change the alerts output.
    static func selectOutput(id: UInt32) throws {
        guard outputs().contains(where: { $0.id == id }) else { throw AudioRoutingError.outputUnavailable }
        var address = property(kAudioHardwarePropertyDefaultOutputDevice)
        var settable: DarwinBoolean = false
        let query = AudioObjectIsPropertySettable(system, &address, &settable)
        guard query == noErr else { throw AudioRoutingError.systemError(query) }
        guard settable.boolValue else { throw AudioRoutingError.selectionUnsupported }
        var identifier = AudioObjectID(id)
        let result = AudioObjectSetPropertyData(system, &address, 0, nil,
                                               UInt32(MemoryLayout<AudioObjectID>.size), &identifier)
        guard result == noErr else { throw AudioRoutingError.systemError(result) }
        guard currentDefaultOutputID() == id else { throw AudioRoutingError.selectionDidNotApply }
    }
}
