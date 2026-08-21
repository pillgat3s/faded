// DriverLink.swift — the app's handle on the installed FadedDriver.
//
// Finds the two virtual devices, speaks the custom-property protocol, and
// surfaces client (per-app) changes as a Swift async stream.

import CoreAudio
import Foundation

@MainActor
final class DriverLink {
    enum Status: Equatable {
        case notInstalled
        case incompatible(found: String)
        case ready
    }

    private(set) var status: Status = .notInstalled
    private(set) var outputDevice: AudioDevice?

    private var clientListener: ListenerToken?
    private var deviceListListener: ListenerToken?

    /// Called on the main actor whenever the driver reports client changes.
    var onClientsChanged: (@MainActor () -> Void)?
    /// Called when the driver appears/disappears (install, coreaudiod restart).
    var onAvailabilityChanged: (@MainActor () -> Void)?

    init() {
        deviceListListener = AudioObject.listen(AudioSystem.object, .init(kAudioHardwarePropertyDevices)) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    // MARK: Discovery

    func refresh() {
        let previous = status
        guard let outID = AudioSystem.deviceID(forUID: FadedProtocol.outputDeviceUID),
              let out = AudioDevice(id: outID)
        else {
            outputDevice = nil
            clientListener = nil
            status = .notInstalled
            if previous != status { onAvailabilityChanged?() }
            return
        }
        outputDevice = out

        let version = AudioObject.getString(outID, .init(FadedProtocol.Prop.version)) ?? "?"
        if version != FadedProtocol.protocolVersion {
            status = .incompatible(found: version)
        } else {
            status = .ready
        }

        if clientListener == nil || previous != status {
            clientListener = AudioObject.listen(outID, .init(FadedProtocol.Prop.clients)) { [weak self] in
                Task { @MainActor in self?.onClientsChanged?() }
            }
        }
        if previous != status { onAvailabilityChanged?() }
    }

    var isReady: Bool { status == .ready }

    // MARK: Protocol

    func clients() -> [DriverClient] {
        guard let id = outputDevice?.id,
              let list = try? AudioObject.getCF(id, .init(FadedProtocol.Prop.clients), as: CFArray.self) as? [[String: Any]]
        else { return [] }
        return list.compactMap { d in
            guard let pid = d["pid"] as? Int, let client = d["client"] as? Int else { return nil }
            return DriverClient(pid: pid_t(pid),
                                clientID: UInt32(client),
                                bundleID: d["bundle"] as? String ?? "",
                                key: d["key"] as? String ?? "pid:\(pid)",
                                gain: Float(d["gain"] as? Double ?? 1),
                                peak: Float(d["peak"] as? Double ?? 0))
        }
    }

    func appGains() -> [String: Float] {
        guard let id = outputDevice?.id,
              let dict = try? AudioObject.getCF(id, .init(FadedProtocol.Prop.appGains), as: CFDictionary.self) as? [String: Double]
        else { return [:] }
        return dict.mapValues(Float.init)
    }

    func setAppGains(_ gains: [String: Float]) {
        guard let id = outputDevice?.id else { return }
        let dict = gains.mapValues { Double($0) } as CFDictionary
        try? AudioObject.setCF(id, .init(FadedProtocol.Prop.appGains), dict)
    }

    /// Make the Faded device report `name`, so macOS's volume HUD and Sound
    /// settings show the speakers the audio is really going to.
    func setDisplayName(_ name: String) {
        guard let id = outputDevice?.id, !name.isEmpty else { return }
        try? AudioObject.setCF(id, .init(FadedProtocol.Prop.displayName), name as CFString)
    }

    func setBypassMaster(_ bypass: Bool) {
        guard let id = outputDevice?.id else { return }
        try? AudioObject.setCF(id, .init(FadedProtocol.Prop.bypassMaster), (bypass ? kCFBooleanTrue : kCFBooleanFalse)!)
    }

    func stats() -> [String: Any] {
        guard let id = outputDevice?.id,
              let dict = try? AudioObject.getCF(id, .init(FadedProtocol.Prop.stats), as: CFDictionary.self) as? [String: Any]
        else { return [:] }
        return dict
    }

    // MARK: Faded device volume/mute (the controls the OS drives)

    var fadedVolume: Float {
        get { outputDevice?.volume ?? 1 }
    }

    func setFadedVolume(_ v: Float) { outputDevice?.setVolume(v) }

    var fadedMuted: Bool { outputDevice?.isMuted ?? false }
    func setFadedMuted(_ m: Bool) { outputDevice?.setMuted(m) }

    /// Set both virtual devices to `rate` and wait (≤ 1 s) for the switch to
    /// land — nominal-rate changes are asynchronous in the HAL and AUHAL
    /// refuses an input client format whose rate differs from the device's.
    /// Returns the rate the Tap actually runs at afterwards.
    @discardableResult
    func setSampleRate(_ rate: Double) -> Double {
        guard let out = outputDevice else { return rate }
        guard FadedProtocol.supportedSampleRates.contains(rate) else { return out.nominalSampleRate }
        if abs(out.nominalSampleRate - rate) < 1 { return rate }
        try? out.setNominalSampleRate(rate)
        // Nominal-rate changes are asynchronous in the HAL; wait for it to land
        // so the play-through opens at the rate the driver is actually using.
        for _ in 0 ..< 40 {
            if abs(out.nominalSampleRate - rate) < 1 { return rate }
            usleep(25_000)
        }
        return out.nominalSampleRate
    }

    // MARK: Experimental: hide the Faded output device from pickers

    var isOutputHidden: Bool {
        guard let id = outputDevice?.id,
              let b = try? AudioObject.getCF(id, .init(FadedProtocol.Prop.hideOutput), as: CFBoolean.self)
        else { return false }
        return CFBooleanGetValue(b)
    }

    func setOutputHidden(_ hidden: Bool) {
        guard let id = outputDevice?.id else { return }
        try? AudioObject.setCF(id, .init(FadedProtocol.Prop.hideOutput), (hidden ? kCFBooleanTrue : kCFBooleanFalse)!)
    }
}
