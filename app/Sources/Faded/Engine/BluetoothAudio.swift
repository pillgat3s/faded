// BluetoothAudio.swift — paired headphones that are not on the audio bus yet.
//
// Control Center's output list includes AirPods that are currently with the
// user's iPhone; picking one initiates the Bluetooth connection, which is what
// pulls audio over to the Mac. A CoreAudio-only device list cannot do that —
// a headset that is not audio-connected has no CoreAudio device at all. This
// wraps IOBluetooth so the menu can offer those devices too and connect them
// on click. Requires the Bluetooth privacy permission (one-time prompt).

import Foundation
import IOBluetooth

struct PairedBluetoothDevice: Identifiable, Hashable, Sendable {
    /// MAC address in IOBluetooth's form, e.g. "74-77-86-93-b3-4d". CoreAudio
    /// BT device UIDs embed the same dashed MAC, which is how the two worlds
    /// are matched.
    let id: String
    let name: String
}

enum BluetoothAudio {
    /// Paired audio-class devices (headphones, headsets, speakers).
    static func pairedAudioDevices() -> [PairedBluetoothDevice] {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired.compactMap { d in
            guard let addr = d.addressString, let name = d.name else { return nil }
            guard d.deviceClassMajor == kBluetoothDeviceClassMajorAudio else { return nil }
            // Find My leaves ghost pairings behind ("AirPods Pro von X - Find
            // My") that Apple's own audio pickers do not offer either.
            guard !name.hasSuffix("- Find My") else { return nil }
            return PairedBluetoothDevice(id: addr, name: name)
        }
    }

    /// Establishes the Bluetooth connection — the same act as clicking the
    /// device in Control Center. Blocking (seconds); call off the main thread.
    /// Whether audio follows is the caller's problem to watch for on CoreAudio.
    static func connect(_ id: String) -> Bool {
        guard let dev = IOBluetoothDevice(addressString: id) else { return false }
        if dev.isConnected() {
            // Baseband already linked (iCloud proximity) but audio absent —
            // cycle the link so the audio profiles renegotiate toward the Mac.
            dev.closeConnection()
            for _ in 0..<20 where dev.isConnected() { Thread.sleep(forTimeInterval: 0.1) }
        }
        return dev.openConnection() == kIOReturnSuccess
    }

    /// True when a CoreAudio device UID carries this Bluetooth MAC.
    static func matches(uid: String, id: String) -> Bool {
        uid.lowercased().contains(id.lowercased())
    }
}
