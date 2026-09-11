// Faded.swift — the few identifiers shared across the app.

import Foundation

enum Faded {
    static let bundleID = "com.andri.faded"

    /// UID of the virtual output device that Faded's original, driver-based
    /// engine published. That engine is gone; the device is never listed and
    /// never played to. If the driver is still installed from an older
    /// version, Settings offers to remove it — see `LegacyDriver`.
    static let legacyDeviceUID = "com.andri.faded.output"
}
