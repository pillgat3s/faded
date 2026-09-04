// MediaKeyTap.swift — the volume keys, for devices that have no volume.
//
// With the real device as the system default, macOS sends the volume keys to
// that device's volume control. Devices without one (Astro A50, most USB
// interfaces, HDMI) get the "no" bezel and nothing happens — the very thing
// Faded exists to fix. So while such a device is current, the keys are taken
// before the system sees them and drive Faded's software master gain
// instead. This needs the Accessibility permission (an event tap that
// swallows events is a "control this computer" capability to macOS).

import AppKit
import ApplicationServices
import Foundation

@MainActor
final class MediaKeyTap {
    enum Key { case up, down, mute }

    var onKey: ((Key) -> Void)?
    /// When false the tap passes everything through untouched.
    var isActive = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: { _, type, event, refcon in
                                               MediaKeyTap.handle(type: type, event: event, refcon: refcon)
                                           }, userInfo: refcon)
        else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
    }

    private nonisolated static func handle(type: CGEventType, event: CGEvent,
                                           refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
        // macOS disables a tap that stalls; re-arm rather than go deaf.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) } }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data = ns.data1
        let keyCode = (data & 0xFFFF_0000) >> 16
        let keyFlags = data & 0xFFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0xA
        let key: Key
        switch keyCode {
        case 0: key = .up       // NX_KEYTYPE_SOUND_UP
        case 1: key = .down     // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute     // NX_KEYTYPE_MUTE
        default: return Unmanaged.passUnretained(event)
        }
        let swallow: Bool = MainActor.assumeIsolated {
            guard me.isActive else { return false }
            if isDown { me.onKey?(key) }
            return true
        }
        // Swallowed: no system bezel, no double handling.
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
