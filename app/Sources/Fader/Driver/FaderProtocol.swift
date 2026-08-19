// FaderProtocol.swift — Swift mirror of driver/FaderProtocol.h.
//
// Kept in sync by hand (Swift can't import multi-character char constants like
// 'fcli' from C). If you change one, change both — `make check-protocol`
// diffs the two.

import CoreAudio
import Foundation

enum FaderProtocol {
    static let outputDeviceUID = "com.andri.fader.output"
    static let outputDeviceName = "Fader"
    static let tapDeviceUID = "com.andri.fader.tap"
    static let tapDeviceName = "Fader Tap"
    static let appBundleID = "com.andri.fader"
    static let driverBundleID = "com.andri.fader.driver"

    static let channelCount = 2
    static let defaultSampleRate = 48000.0
    static let supportedSampleRates: [Double] = [44100, 48000, 88200, 96000]

    static let protocolVersion = "1"

    /// Custom property selectors on the Fader output device object.
    enum Prop {
        static let clients = fourCC("fcli")
        static let appGains = fourCC("fapv")
        static let bypassMaster = fourCC("fbyp")
        static let hideOutput = fourCC("fhid")
        static let version = fourCC("fver")
        static let stats = fourCC("fsta")
    }

    private static func fourCC(_ s: String) -> AudioObjectPropertySelector {
        precondition(s.utf8.count == 4)
        return s.utf8.reduce(0) { ($0 << 8) | AudioObjectPropertySelector($1) }
    }
}

/// One entry of the driver's 'fcli' list: a process attached to the Fader device.
struct DriverClient: Hashable, Sendable {
    let pid: pid_t
    let clientID: UInt32
    let bundleID: String
    /// Gain key the driver uses: bundle id, or "pid:N" for bundle-less processes.
    let key: String
    let gain: Float
    let peak: Float
}
