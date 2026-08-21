// AudioDevice.swift — a value-type snapshot of one CoreAudio device plus the
// handful of live operations Faded needs (volume, mute, sample rate).

import AudioToolbox
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable, Sendable {
    enum Transport: Sendable {
        case builtIn, usb, bluetooth, airPlay, hdmi, displayPort, thunderbolt, aggregate, virtual, continuity, other

        init(raw: UInt32) {
            switch raw {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
            case kAudioDeviceTransportTypeAirPlay: self = .airPlay
            case kAudioDeviceTransportTypeHDMI: self = .hdmi
            case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
            case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
            case kAudioDeviceTransportTypeAggregate: self = .aggregate
            case kAudioDeviceTransportTypeVirtual: self = .virtual
            case kAudioDeviceTransportTypeContinuityCaptureWired,
                 kAudioDeviceTransportTypeContinuityCaptureWireless: self = .continuity
            default: self = .other
            }
        }

        /// SF Symbol that mirrors what Control Center shows.
        var symbol: String {
            switch self {
            case .builtIn: "laptopcomputer"
            case .usb: "cable.connector"
            case .bluetooth: "headphones"
            case .airPlay: "airplayaudio"
            case .hdmi, .displayPort: "display"
            case .thunderbolt: "bolt.horizontal"
            case .aggregate: "square.stack.3d.up"
            case .virtual: "waveform"
            case .continuity: "iphone"
            case .other: "speaker.wave.2"
            }
        }
    }

    /// SF Symbol for this device in a given role. Output uses the transport
    /// glyph; input falls back to a microphone for devices whose transport
    /// carries no useful picture (a plain USB interface, an aggregate, …).
    func symbol(forInput: Bool) -> String {
        guard forInput else { return transport.symbol }
        switch transport {
        case .builtIn, .continuity, .bluetooth: return transport.symbol
        case .usb, .aggregate, .virtual, .other, .thunderbolt: return "mic"
        case .airPlay, .hdmi, .displayPort: return transport.symbol
        }
    }

    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: Transport
    let hasOutput: Bool
    let hasInput: Bool
    let hasHardwareVolume: Bool
    let hasHardwareMute: Bool
    /// Input side has a settable volume (built-in mic yes, many USB headsets no).
    let hasInputVolume: Bool
    let isHidden: Bool

    // MARK: Snapshot

    init?(id: AudioDeviceID) {
        guard let uid = AudioObject.getString(id, .init(kAudioDevicePropertyDeviceUID)) else { return nil }
        self.id = id
        self.uid = uid
        name = AudioObject.getString(id, .init(kAudioObjectPropertyName)) ?? uid
        let rawTransport: UInt32 = (try? AudioObject.get(id, .init(kAudioDevicePropertyTransportType))) ?? 0
        transport = Transport(raw: rawTransport)
        hasOutput = Self.channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0
        hasInput = Self.channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0
        hasHardwareVolume = Self.volumeAddress(for: id) != nil
        hasHardwareMute = Self.muteAddress(for: id) != nil
        hasInputVolume = Self.volumeAddress(for: id, scope: kAudioObjectPropertyScopeInput) != nil
        let hidden: UInt32 = (try? AudioObject.get(id, .init(kAudioDevicePropertyIsHidden))) ?? 0
        isHidden = hidden != 0
    }

#if DEBUG
    /// Synthesises a device that isn't attached to any real hardware, so the
    /// README screenshot can be generated without leaking the machine's actual
    /// device names. Debug builds only.
    init(demoID: AudioDeviceID, uid: String, name: String, transport: Transport,
         hasOutput: Bool, hasInput: Bool, hasHardwareVolume: Bool, hasInputVolume: Bool)
    {
        id = demoID
        self.uid = uid
        self.name = name
        self.transport = transport
        self.hasOutput = hasOutput
        self.hasInput = hasInput
        self.hasHardwareVolume = hasHardwareVolume
        hasHardwareMute = hasHardwareVolume
        self.hasInputVolume = hasInputVolume
        isHidden = false
    }
#endif

    static func all() -> [AudioDevice] {
        AudioSystem.allDeviceIDs().compactMap(AudioDevice.init(id:))
    }

    /// Output-capable, non-hidden devices, excluding Faded's own virtual ones.
    static func selectableOutputs() -> [AudioDevice] {
        all().filter { $0.hasOutput && !$0.isHidden && !$0.isFadedDevice }
    }

    /// Input-capable, non-hidden devices, excluding Faded's own virtual ones.
    static func selectableInputs() -> [AudioDevice] {
        all().filter { $0.hasInput && !$0.isHidden && !$0.isFadedDevice }
    }

    var isFadedDevice: Bool { uid == FadedProtocol.outputDeviceUID }

    var isAlive: Bool {
        let alive: UInt32 = (try? AudioObject.get(id, .init(kAudioDevicePropertyDeviceIsAlive))) ?? 0
        return alive != 0
    }

    // MARK: Streams

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        let addr = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        guard let size = try? AudioObject.dataSize(id, addr), size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        var a = addr
        var s = size
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: Volume

    /// The address macOS's own Sound slider uses (VirtualMainVolume), or the
    /// classic per-device VolumeScalar on the main element, or channel 1.
    private static func volumeAddress(for id: AudioDeviceID,
                                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> AudioObjectPropertyAddress?
    {
        let candidates = [
            AudioObjectPropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope),
            AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope),
            AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: scope, element: 1),
        ]
        return candidates.first { AudioObject.has(id, $0) && AudioObject.isSettable(id, $0) }
    }

    private static func muteAddress(for id: AudioDeviceID,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> AudioObjectPropertyAddress?
    {
        let candidates = [
            AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: scope),
            AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: scope, element: 1),
        ]
        return candidates.first { AudioObject.has(id, $0) && AudioObject.isSettable(id, $0) }
    }

    // MARK: Input volume / mute

    var inputVolume: Float? {
        guard let addr = Self.volumeAddress(for: id, scope: kAudioObjectPropertyScopeInput) else { return nil }
        return try? AudioObject.get(id, addr, as: Float32.self)
    }

    func setInputVolume(_ value: Float) {
        guard let addr = Self.volumeAddress(for: id, scope: kAudioObjectPropertyScopeInput) else { return }
        try? AudioObject.set(id, addr, Float32(min(max(value, 0), 1)))
        let ch2 = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: 2)
        if addr.mElement == 1, AudioObject.has(id, ch2) { try? AudioObject.set(id, ch2, Float32(value)) }
    }

    var isInputMuted: Bool? {
        guard let addr = Self.muteAddress(for: id, scope: kAudioObjectPropertyScopeInput) else { return nil }
        let v: UInt32? = try? AudioObject.get(id, addr)
        return v.map { $0 != 0 }
    }

    func setInputMuted(_ muted: Bool) {
        guard let addr = Self.muteAddress(for: id, scope: kAudioObjectPropertyScopeInput) else { return }
        try? AudioObject.set(id, addr, UInt32(muted ? 1 : 0))
    }

    var inputVolumeListenerAddresses: [AudioObjectPropertyAddress] {
        let candidates = [
            AudioObjectPropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeInput),
            AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput),
            AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: 1),
            AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput),
        ]
        return candidates.filter { AudioObject.has(id, $0) }
    }

    /// 0…1 scalar, or nil if the device has no settable volume.
    var volume: Float? {
        guard let addr = Self.volumeAddress(for: id) else { return nil }
        return try? AudioObject.get(id, addr, as: Float32.self)
    }

    func setVolume(_ value: Float) {
        guard let addr = Self.volumeAddress(for: id) else { return }
        try? AudioObject.set(id, addr, Float32(min(max(value, 0), 1)))
        // Some devices only expose per-channel controls; mirror to channel 2 too.
        let ch2 = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: 2)
        if addr.mElement == 1, AudioObject.has(id, ch2) { try? AudioObject.set(id, ch2, Float32(value)) }
    }

    var isMuted: Bool? {
        guard let addr = Self.muteAddress(for: id) else { return nil }
        let v: UInt32? = try? AudioObject.get(id, addr)
        return v.map { $0 != 0 }
    }

    func setMuted(_ muted: Bool) {
        guard let addr = Self.muteAddress(for: id) else { return }
        try? AudioObject.set(id, addr, UInt32(muted ? 1 : 0))
        let ch2 = AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, element: 2)
        if addr.mElement == 1, AudioObject.has(id, ch2) { try? AudioObject.set(id, ch2, UInt32(muted ? 1 : 0)) }
    }

    /// Addresses to watch for external volume/mute changes on this device.
    var volumeListenerAddresses: [AudioObjectPropertyAddress] {
        let candidates = [
            AudioObjectPropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput),
            AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput),
            AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: 1),
            AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput),
            AudioObjectPropertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, element: 1),
        ]
        return candidates.filter { AudioObject.has(id, $0) }
    }

    // MARK: Sample rate

    var nominalSampleRate: Double {
        (try? AudioObject.get(id, .init(kAudioDevicePropertyNominalSampleRate), as: Float64.self)) ?? 0
    }

    func setNominalSampleRate(_ rate: Double) throws {
        try AudioObject.set(id, .init(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }

    var availableSampleRates: [Double] {
        let ranges = (try? AudioObject.getArray(id, .init(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)) ?? []
        return ranges.map(\.mMinimum)
    }

    // MARK: Hashable on identity only

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool { lhs.id == rhs.id && lhs.uid == rhs.uid }
    func hash(into hasher: inout Hasher) { hasher.combine(uid) }
}
