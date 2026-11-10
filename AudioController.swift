import CoreAudio
import Foundation

struct OutputDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    var uid: String = ""

    /// For Bluetooth devices CoreAudio's UID starts with the device address, e.g. "54-10-4F-CB-9D-DF:output".
    var bluetoothAddress: String? {
        guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
              uid.count >= 17 else { return nil }
        let address = uid.prefix(17).replacingOccurrences(of: "-", with: ":").uppercased()
        return address.split(separator: ":").count == 6 ? address : nil
    }

    /// SF Symbol that roughly matches what the native Sound panel shows.
    var symbolName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker"
        default: return "speaker.wave.2"
        }
    }
}

/// Thin wrapper over CoreAudio: system output volume, mute, and the output device list.
/// Uses the same "virtual main volume" property the native slider uses, and listens for
/// changes instead of polling.
final class AudioController {
    /// Fires on the main queue when volume, mute, default device or the device list changes.
    var onChange: (() -> Void)?

    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663 // 'vmvc'
    private var boundDevice = AudioObjectID(kAudioObjectUnknown)
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlock: AudioObjectPropertyListenerBlock?

    private func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default fallback: T) -> T {
        var addr = addr
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : fallback
    }

    @discardableResult
    private func write<T: BitwiseCopyable>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ newValue: T) -> Bool {
        var addr = addr
        var value = newValue
        return AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    // MARK: - Listeners

    func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebindDeviceListeners()
            self?.onChange?()
        }
        systemBlock = block
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, .main, block)
        }
        rebindDeviceListeners()
    }

    private func rebindDeviceListeners() {
        let selectors = [virtualMainVolume, kAudioDevicePropertyMute]
        if boundDevice != kAudioObjectUnknown, let old = deviceBlock {
            for selector in selectors {
                var addr = address(selector, scope: kAudioObjectPropertyScopeOutput)
                AudioObjectRemovePropertyListenerBlock(boundDevice, &addr, .main, old)
            }
        }
        boundDevice = defaultOutputDevice
        deviceBlock = nil
        guard boundDevice != kAudioObjectUnknown else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
        deviceBlock = block
        for selector in selectors {
            var addr = address(selector, scope: kAudioObjectPropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(boundDevice, &addr, .main, block)
        }
    }

    // MARK: - Default device

    var defaultOutputDevice: AudioDeviceID {
        read(system, address(kAudioHardwarePropertyDefaultOutputDevice), default: AudioDeviceID(kAudioObjectUnknown))
    }

    func setDefaultOutput(_ id: AudioDeviceID) {
        write(system, address(kAudioHardwarePropertyDefaultOutputDevice), id)
        write(system, address(kAudioHardwarePropertyDefaultSystemOutputDevice), id)
    }

    // MARK: - Volume / mute

    private var volumeAddress: AudioObjectPropertyAddress {
        address(virtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    }

    private var muteAddress: AudioObjectPropertyAddress {
        address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
    }

    var volume: Float {
        read(defaultOutputDevice, volumeAddress, default: Float32(0.5))
    }

    var canSetVolume: Bool {
        var addr = volumeAddress
        var settable: DarwinBoolean = false
        let device = defaultOutputDevice
        guard AudioObjectHasProperty(device, &addr) else { return false }
        return AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    func setVolume(_ newValue: Float) {
        let clamped = min(1, max(0, newValue))
        let device = defaultOutputDevice
        write(device, volumeAddress, Float32(clamped))
        if clamped > 0, isMuted { setMuted(false) }
    }

    var isMuted: Bool {
        read(defaultOutputDevice, muteAddress, default: UInt32(0)) != 0
    }

    func setMuted(_ muted: Bool) {
        var addr = muteAddress
        let device = defaultOutputDevice
        guard AudioObjectHasProperty(device, &addr) else { return }
        write(device, addr, UInt32(muted ? 1 : 0))
    }

    // MARK: - Device list

    func outputDevices() -> [OutputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard outputChannelCount(id) > 0 else { return nil }
            guard read(id, address(kAudioDevicePropertyIsHidden), default: UInt32(0)) == 0 else { return nil }
            let transport: UInt32 = read(id, address(kAudioDevicePropertyTransportType), default: UInt32(0))
            // The native panel hides software devices such as "Microsoft Teams Audio".
            guard transport != kAudioDeviceTransportTypeVirtual else { return nil }
            return OutputDevice(id: id, name: deviceName(id), transport: transport, uid: deviceUID(id))
        }
    }

    private func deviceName(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let name else {
            return "Unknown Device"
        }
        return name.takeRetainedValue() as String
    }

    private func deviceUID(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid) == noErr, let uid else { return "" }
        return uid.takeRetainedValue() as String
    }

    private func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
