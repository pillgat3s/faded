// AudioObject.swift — thin, typed wrappers over the CoreAudio HAL C API.
//
// Everything in Faded that touches CoreAudio goes through here so the rest of
// the app never sees UnsafeMutableRawPointer arithmetic.

import CoreAudio
import Foundation

enum AudioError: Error, CustomStringConvertible {
    case osStatus(OSStatus, String)
    case notFound(String)

    var description: String {
        switch self {
        case let .osStatus(status, what): "\(what) failed: \(status) (\(fourCC(UInt32(bitPattern: status))))"
        case let .notFound(what): "\(what) not found"
        }
    }
}

/// Renders a FourCharCode as text for logs ("fcli", "who?", …).
func fourCC(_ code: UInt32) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
    ]
    let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    return printable ? String(decoding: bytes, as: UTF8.self) : String(code)
}

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
    {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

/// Namespace for property get/set on any AudioObjectID.
enum AudioObject {
    static func has(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        return AudioObjectHasProperty(id, &addr)
    }

    static func isSettable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &addr, &settable) == noErr && settable.boolValue
    }

    static func dataSize(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> UInt32 {
        var addr = address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        guard status == noErr else { throw AudioError.osStatus(status, "GetPropertyDataSize \(fourCC(address.mSelector))") }
        return size
    }

    // MARK: Plain-old-data values

    static func get<T: BitwiseCopyable>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, as _: T.Type = T.self) throws -> T {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        guard status == noErr else { throw AudioError.osStatus(status, "GetPropertyData \(fourCC(address.mSelector))") }
        return ptr.pointee
    }

    static func set<T: BitwiseCopyable>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var addr = address
        var v = value
        let status = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
        guard status == noErr else { throw AudioError.osStatus(status, "SetPropertyData \(fourCC(address.mSelector))") }
    }

    static func getArray<T: BitwiseCopyable>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, of _: T.Type = T.self) throws -> [T] {
        var addr = address
        var size = try dataSize(id, address)
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var out = [T](unsafeUninitializedCapacity: count) { buf, initialized in
            let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf.baseAddress!)
            initialized = status == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
        // Trim in case the device list shrank between size query and fetch.
        if out.count > Int(size) / MemoryLayout<T>.stride { out.removeLast(out.count - Int(size) / MemoryLayout<T>.stride) }
        return out
    }

    // MARK: CoreFoundation values (CFString / CFPropertyList / CFURL)

    static func getCF<T: AnyObject>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, as _: T.Type = T.self) throws -> T {
        var addr = address
        var size = UInt32(MemoryLayout<Unmanaged<T>?>.size)
        var value: Unmanaged<T>? = nil
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let v = value else { throw AudioError.osStatus(status, "GetPropertyData(CF) \(fourCC(address.mSelector))") }
        return v.takeRetainedValue()
    }

    static func setCF<T: AnyObject>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var addr = address
        var unmanaged: Unmanaged<T>? = Unmanaged.passUnretained(value)
        let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<T>?>.size), ptr)
        }
        guard status == noErr else { throw AudioError.osStatus(status, "SetPropertyData(CF) \(fourCC(address.mSelector))") }
    }

    static func getString(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        (try? getCF(id, address, as: CFString.self)).map { $0 as String }
    }

    // MARK: Listeners

    /// Registers a property listener; returns a token that removes it on deinit.
    static func listen(_ id: AudioObjectID,
                       _ address: AudioObjectPropertyAddress,
                       queue: DispatchQueue = .main,
                       _ handler: @escaping @Sendable () -> Void) -> ListenerToken
    {
        ListenerToken(objectID: id, address: address, queue: queue, handler: handler)
    }
}

final class ListenerToken: @unchecked Sendable {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    fileprivate init(objectID: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue,
                     handler: @escaping @Sendable () -> Void)
    {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(objectID, &self.address, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}

// MARK: - System object conveniences

enum AudioSystem {
    static let object = AudioObjectID(kAudioObjectSystemObject)

    static func allDeviceIDs() -> [AudioDeviceID] {
        (try? AudioObject.getArray(object, .init(kAudioHardwarePropertyDevices), of: AudioDeviceID.self)) ?? []
    }

    static var defaultOutputDevice: AudioDeviceID? {
        get {
            let id: AudioDeviceID? = try? AudioObject.get(object, .init(kAudioHardwarePropertyDefaultOutputDevice))
            return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
        }
    }

    static func setDefaultOutputDevice(_ id: AudioDeviceID) throws {
        try AudioObject.set(object, .init(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    static var defaultInputDevice: AudioDeviceID? {
        let id: AudioDeviceID? = try? AudioObject.get(object, .init(kAudioHardwarePropertyDefaultInputDevice))
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func setDefaultInputDevice(_ id: AudioDeviceID) throws {
        try AudioObject.set(object, .init(kAudioHardwarePropertyDefaultInputDevice), id)
    }

    static var defaultSystemOutputDevice: AudioDeviceID? {
        let id: AudioDeviceID? = try? AudioObject.get(object, .init(kAudioHardwarePropertyDefaultSystemOutputDevice))
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func setDefaultSystemOutputDevice(_ id: AudioDeviceID) throws {
        try AudioObject.set(object, .init(kAudioHardwarePropertyDefaultSystemOutputDevice), id)
    }

    /// Resolves a device UID → AudioDeviceID. Works for *hidden* devices too,
    /// which is how the app finds "Faded Tap".
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID: Unmanaged<CFString>? = Unmanaged.passUnretained(uid as CFString)
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { inPtr in
            AudioObjectGetPropertyData(object, &addr,
                                       UInt32(MemoryLayout<Unmanaged<CFString>?>.size), inPtr,
                                       &size, &deviceID)
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
