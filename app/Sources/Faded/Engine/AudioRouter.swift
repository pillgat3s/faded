// AudioRouter.swift — the brain. Owns the tap engine, the "which device is
// the system output" bookkeeping, volume, input selection, per-app gains,
// meters, the browser bridge and persistence.
//
// Invariants:
//   * The system default output device is macOS's to own. Faded never sets it
//     except when you pick a device in Faded's own menu — the same act as
//     picking it in Control Center.
//   * `target` is whatever device is the system default right now.
//   * The tap engine plays to `target`. Its stream runs only while some app is
//     running output, so what the system sees is what it would see without
//     Faded (an open stream is what makes in-ear AirPods jump over from a
//     phone, so this matters).
//   * Devices with hardware volume are left to macOS — the keys, Control
//     Center and AirPods stem gestures all work natively and Faded only
//     reflects them. Devices without one get a software master gain in the
//     mix, and Faded takes the volume keys for them.
//
// Input is not interposed: Faded selects the system input device and drives
// its hardware volume/mute directly, so nothing of Faded's ever turns up in a
// microphone picker.

import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Observation
import os

/// Appends one timestamped line to ~/Library/Application Support/Faded/trace.log.
/// os_log has proven unreliable as a witness on this system (whole-process
/// silence in `log show`), and a debugger cannot watch a menu bar app react to
/// device hot-plugs in real time. A plain file can. Cheap enough to leave on.
func trace(_ message: String) {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Faded", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("trace.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

@MainActor
@Observable
final class AudioRouter {
    private static let log = Logger(subsystem: Faded.bundleID, category: "Router")

    // MARK: Observable state

    /// The volume keys need the Accessibility permission on devices without
    /// hardware volume. True while that is missing and such a device is current.
    private(set) var needsAccessibility = false
    private(set) var allOutputs: [AudioDevice] = []
    private(set) var allInputs: [AudioDevice] = []
    /// Paired Bluetooth headphones with no CoreAudio device yet (they are with
    /// the iPhone, or in the case). Shown in the menu; picking one connects it.
    private(set) var offlineBluetooth: [PairedBluetoothDevice] = []
    /// MAC of the device currently being connected, for the row spinner.
    private(set) var connectingBluetooth: String?
    private(set) var target: AudioDevice?
    private(set) var selectedInput: AudioDevice?
    private(set) var volume: Float = 1
    private(set) var muted = false
    private(set) var inputVolume: Float = 1
    private(set) var inputMuted = false
    private(set) var apps: [AppEntry] = []
    /// Chrome tabs, live from the Faded Tabs extension over the native bridge.
    private(set) var browserTabs: [BrowserTab] = []
    private(set) var browserBridgeConnected = false
    /// True while the tap engine owns the audio path.
    private(set) var isEngaged = false
    private(set) var lastError: String?
    /// True when the current default device could not be followed (the tap
    /// engine failed on it). Audio flows natively; per-app volume pauses.
    private(set) var steppedAside = false

    /// Master output meter (L, R), 0…1.
    private(set) var outputLevel: (Float, Float) = (0, 0)
    /// Selected input meter (L, R), 0…1.
    private(set) var inputLevel: (Float, Float) = (0, 0)

    // MARK: Settings (persisted)

    /// Per-app volume and the volume keys (false = leave macOS completely alone).
    var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            defaults.set(enabled, forKey: Keys.enabled)
            enabled ? engage() : disengage()
        }
    }

    /// Draw level meters next to devices and apps.
    var showMeters: Bool {
        didSet {
            guard oldValue != showMeters else { return }
            defaults.set(showMeters, forKey: Keys.showMeters)
            if !showMeters { inputMeter.stop(); outputLevel = (0, 0); inputLevel = (0, 0) }
        }
    }

    /// Draw a live level meter for the selected *input* device.
    ///
    /// Off by default, and deliberately separate from `showMeters`: output
    /// metering is free (the mix is already in hand), but there is no property
    /// anywhere in CoreAudio that reports an input's level, so this one has to
    /// open a capture stream — which lights the orange microphone indicator in
    /// the menu bar for as long as it runs. Faded does not do that unless asked.
    var showInputMeter: Bool {
        didSet {
            guard oldValue != showInputMeter else { return }
            defaults.set(showInputMeter, forKey: Keys.showInputMeter)
            if !showInputMeter { inputMeter.stop(); inputLevel = (0, 0) }
        }
    }

    /// Show the Input section in the menu.
    var showInputSection: Bool {
        didSet {
            guard oldValue != showInputSection else { return }
            defaults.set(showInputSection, forKey: Keys.showInputSection)
        }
    }

    private(set) var hiddenOutputUIDs: Set<String>
    private(set) var hiddenInputUIDs: Set<String>
    private(set) var starredApps: Set<String>

    // MARK: Derived views for the UI

    var visibleOutputs: [AudioDevice] { allOutputs.filter { !hiddenOutputUIDs.contains($0.uid) } }
    var hiddenOutputs: [AudioDevice] { allOutputs.filter { hiddenOutputUIDs.contains($0.uid) } }
    var visibleInputs: [AudioDevice] { allInputs.filter { !hiddenInputUIDs.contains($0.uid) } }
    var hiddenInputs: [AudioDevice] { allInputs.filter { hiddenInputUIDs.contains($0.uid) } }
    var hasHiddenDevices: Bool { !hiddenOutputs.isEmpty || !hiddenInputs.isEmpty }

    /// Apps pinned with a star — shown even when the Apps list is collapsed or
    /// the app isn't currently playing.
    var starredEntries: [AppEntry] { apps.filter(\.starred) }
    /// Everything currently making sound.
    var playingEntries: [AppEntry] { apps.filter(\.isPlaying) }

    /// True when the selected input's level can be shown (Bluetooth excluded —
    /// capturing would force the HFP profile and wreck playback).
    var canMeterInput: Bool {
        guard showMeters, showInputMeter, let i = selectedInput else { return false }
        return InputMeter.canMeter(i)
    }

    struct AppEntry: Identifiable, Hashable {
        let id: String       // ResolvedApp.id — bundle id, or "pid:N"
        let name: String
        let pid: pid_t
        var gain: Float      // 0…1 (no boost)
        var muted: Bool
        var peak: Float
        var isBare: Bool
        var starred: Bool
        var isPlaying: Bool
        var icon: NSImage {
            if isPlaying {
                return ProcessResolver.icon(for: ResolvedApp(id: id, name: name, pid: pid, isBare: isBare))
            }
            return ProcessResolver.staticInfo(bundleID: id)?.icon
                ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }

        static func == (l: AppEntry, r: AppEntry) -> Bool {
            l.id == r.id && l.gain == r.gain && l.muted == r.muted
                && l.peak == r.peak && l.starred == r.starred && l.isPlaying == r.isPlaying
        }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    // MARK: Internals

    let bridge = BrowserBridge()
    let tapEngine = TapEngine()
    private let mediaKeys = MediaKeyTap()
    private let hud = VolumeHUD()
    private let inputMeter = InputMeter()
    private let defaults = UserDefaults.standard

    private var defaultOutputListener: ListenerToken?
    private var defaultInputListener: ListenerToken?
    private var deviceListListener: ListenerToken?
    private var targetControlListeners: [ListenerToken] = []
    private var inputControlListeners: [ListenerToken] = []
    private var reconcileTimer: Timer?
    private var meterTimer: Timer?
    private var pollTimer: Timer?
    private var followRetry: DispatchWorkItem?
    private var stopWork: DispatchWorkItem?
    private var startFailures = 0
    private var retryAfter = Date.distantPast
    private var activity: NSObjectProtocol?
    private var idleTicks = 0
    private var pollTicks = 0
    private var lastSignal = Date()
    private var peaksByProcess: [AudioObjectID: Float] = [:]
    private var resolvedByProcess: [AudioObjectID: ResolvedApp] = [:]

    private var previewMode = false      // DEBUG --render-menu only
    private var settingDefault = false   // re-entrancy guard for default-device writes

    private var volumeByDevice: [String: Float]  // software master, per device without hardware volume
    private var mutedByDevice: [String: Bool]
    private var appGains: [String: Float]        // app id → gain
    private var appMutedLevels: [String: Float]  // app id → level stashed while muted
    private var appNames: [String: String]       // app id → last seen display name
    private var previousTargets: [String] = []   // UIDs, most recent last

    /// App id → when it last produced a signal above `audibleThreshold`.
    /// Every process that merely *opens* a device has a tap — corespeechd,
    /// callservicesd, loginwindow, Siri and a dozen other daemons sit there
    /// permanently at digital silence. Only things actually making sound
    /// belong in the menu, so an app has to have been audible recently to be
    /// listed (starred apps are exempt).
    private var lastAudible: [String: Date] = [:]
    private let audibleThreshold: Float = 0.0003   // ≈ −70 dBFS
    private let audibleHold: TimeInterval = 8      // keep listed this long after it goes quiet

    private enum Keys {
        static let enabled = "enabled"
        static let volumeByDevice = "volumeByDevice"
        static let mutedByDevice = "mutedByDevice"
        static let appGains = "appGains"
        static let appMutedLevels = "appMutedLevels"
        static let appNames = "appNames"
        static let lastTarget = "lastTargetUID"
        static let previousTargets = "previousTargets"
        static let showMeters = "showMeters"
        static let showInputMeter = "showInputMeter"
        static let showInputSection = "showInputSection"
        static let hiddenOutputs = "hiddenOutputUIDs"
        static let hiddenInputs = "hiddenInputUIDs"
        static let starredApps = "starredApps"
    }

    init() {
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        showMeters = defaults.object(forKey: Keys.showMeters) as? Bool ?? true
        showInputMeter = defaults.bool(forKey: Keys.showInputMeter)   // opt-in: uses the mic
        showInputSection = defaults.object(forKey: Keys.showInputSection) as? Bool ?? true
        volumeByDevice = defaults.dictionary(forKey: Keys.volumeByDevice) as? [String: Float] ?? [:]
        mutedByDevice = defaults.dictionary(forKey: Keys.mutedByDevice) as? [String: Bool] ?? [:]
        appGains = defaults.dictionary(forKey: Keys.appGains) as? [String: Float] ?? [:]
        appMutedLevels = defaults.dictionary(forKey: Keys.appMutedLevels) as? [String: Float] ?? [:]
        appNames = defaults.dictionary(forKey: Keys.appNames) as? [String: String] ?? [:]
        previousTargets = defaults.stringArray(forKey: Keys.previousTargets) ?? []
        hiddenOutputUIDs = Set(defaults.stringArray(forKey: Keys.hiddenOutputs) ?? [])
        hiddenInputUIDs = Set(defaults.stringArray(forKey: Keys.hiddenInputs) ?? [])
        starredApps = Set(defaults.stringArray(forKey: Keys.starredApps) ?? [])

        deviceListListener = AudioObject.listen(AudioSystem.object, .init(kAudioHardwarePropertyDevices)) { [weak self] in
            Task { @MainActor in self?.devicesChanged() }
        }
        defaultOutputListener = AudioObject.listen(AudioSystem.object, .init(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            Task { @MainActor in self?.defaultOutputChanged() }
        }
        defaultInputListener = AudioObject.listen(AudioSystem.object, .init(kAudioHardwarePropertyDefaultInputDevice)) { [weak self] in
            Task { @MainActor in self?.refreshInputs() }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopMetering() }
        }

        // `--render-menu` / `--render-settings` only rasterise the UI from
        // invented state; they must not touch devices, Bluetooth or the bridge.
        let rendering = CommandLine.arguments.contains { $0.hasPrefix("--render-") }
        guard !rendering else { return }

        bridge.onTabs = { [weak self] tabs in
            // Audible first, then anything holding a non-default setting.
            self?.browserTabs = tabs.sorted {
                ($0.audible ? 0 : 1, $0.title) < ($1.audible ? 0 : 1, $1.title)
            }
        }
        bridge.onConnectionChanged = { [weak self] connected in
            self?.browserBridgeConnected = connected
        }
        bridge.start()

        tapEngine.onProcessesChanged = { [weak self] in
            self?.pushAllAppGains()
            self?.refreshApps()
        }
        tapEngine.onOutputActivity = { [weak self] in self?.reconcileStream() }
        mediaKeys.onKey = { [weak self] key in self?.handleMediaKey(key) }

        refreshDevices()
        if enabled { engage() }
        refreshApps()
        startWatchdog()
    }

    // MARK: Browser tabs (via the extension bridge)

    func setTabGain(_ tabID: Int, _ gain: Float) {
        bridge.setTabGain(tabID, gain)
        if let i = browserTabs.firstIndex(where: { $0.id == tabID }) {
            browserTabs[i].gain = min(max(gain, 0), 1)   // optimistic; snapshot follows
        }
    }

    func setTabMuted(_ tabID: Int, _ muted: Bool) {
        bridge.setTabMuted(tabID, muted)
        if let i = browserTabs.firstIndex(where: { $0.id == tabID }) {
            browserTabs[i].muted = muted
        }
    }

    // MARK: Engage / disengage

    func engage() {
        guard !isEngaged, enabled else { return }
        lastError = nil
        var current = AudioSystem.defaultOutputDevice.flatMap(AudioDevice.init(id:))
        // The device the original driver-based engine published can still be
        // the default on a machine that ran that version; hand the system a
        // real one first.
        if current == nil || current!.isLegacyFadedDevice || !current!.hasOutput {
            if let fb = fallbackDevice() { setSystemDefault(to: fb.id); current = fb }
        }
        guard let dev = current else { lastError = "No output device."; return }
        target = dev
        do {
            try tapEngine.start(output: dev)
        } catch {
            lastError = "\(error)"
            trace("engage failed on \(dev.name): \(error)")
            standAside(for: dev, reason: "tap engine failed")
            return
        }
        steppedAside = false
        isEngaged = true
        startFailures = 0
        // App Nap would delay the listener that starts our stream when an app
        // begins playing; that delay is audible silence.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                             reason: "Faded audio engine")
        }
        installTargetListeners()
        applyVolumeForTarget()
        pushAllAppGains()
        updateMediaKeys()
        startPolling()
        refreshApps()
        reconcileStream()
        trace("engaged → \(dev.name)")
    }

    func disengage() {
        guard isEngaged else { return }
        stopWork?.cancel()
        stopWork = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        tapEngine.stop()
        pollTimer?.invalidate()
        pollTimer = nil
        mediaKeys.isActive = false
        needsAccessibility = false
        outputLevel = (0, 0)
        isEngaged = false
        readVolumeFromTargetDirectly()
        trace("disengaged")
    }

    /// Call from applicationWillTerminate.
    func shutdown() {
        bridge.stop()
        inputMeter.stop()
        mediaKeys.stop()
        disengage()
    }

    /// The engine cannot run on this device. Track it for display only — the
    /// header names it and the slider drives its hardware volume — and try
    /// again when the default moves or after a pause.
    private func standAside(for device: AudioDevice, reason: String) {
        trace("standing aside for \(device.name) (\(reason))")
        if isEngaged { disengage() }
        steppedAside = true
        target = device
        retryAfter = Date().addingTimeInterval(30)
        installTargetListeners()
        readVolumeFromTargetDirectly()
    }

    // MARK: Following the system default

    /// The default moved (user, Control Center, AirPods, AirPlay): follow it.
    /// Retries while a device is still materialising — an AirPlay device is
    /// created in the same breath as it becomes the default, with no streams
    /// configured yet, and Bluetooth takes seconds to bring its streams up.
    private func followDefault(_ id: AudioDeviceID, attempt: Int) {
        followRetry?.cancel()
        followRetry = nil
        if let current = AudioSystem.defaultOutputDevice, current != id {
            // Moved again mid-retry (AirPods connects flip it more than once).
            followDefault(current, attempt: 0)
            return
        }
        let device = AudioDevice(id: id)
        if let d = device, d.isLegacyFadedDevice {
            if let fb = fallbackDevice() { setSystemDefault(to: fb.id) }
            return
        }
        guard let dev = device, dev.hasOutput, dev.isAlive else {
            if attempt < 40 {
                let work = DispatchWorkItem { [weak self] in
                    Task { @MainActor in self?.followDefault(id, attempt: attempt + 1) }
                }
                followRetry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            } else {
                trace("default \(id) never became usable")
            }
            return
        }
        if target?.uid != dev.uid {
            if let old = target {
                previousTargets.removeAll { $0 == old.uid }
                previousTargets.append(old.uid)
                if previousTargets.count > 8 { previousTargets.removeFirst() }
                defaults.set(previousTargets, forKey: Keys.previousTargets)
            }
            defaults.set(dev.uid, forKey: Keys.lastTarget)
        }
        target = dev
        installTargetListeners()
        if isEngaged {
            do {
                try tapEngine.retarget(dev)
                steppedAside = false
            } catch {
                lastError = "\(error)"
                trace("retarget to \(dev.name) failed: \(error)")
                standAside(for: dev, reason: "retarget failed")
                return
            }
        } else if enabled, Date() >= retryAfter {
            engage()
            return
        }
        applyVolumeForTarget()
        updateMediaKeys()
        reconcileStream()
        trace("following → \(dev.name)")
    }

    private func defaultOutputChanged() {
        guard !settingDefault else { return }
        resolveDefaultChange(attempt: 0)
    }

    /// Reading kAudioHardwarePropertyDefaultOutputDevice from inside the HAL's
    /// own change callback frequently returns kAudioObjectUnknown — the HAL is
    /// mid-transaction. So the read is retried on a short timer until it answers.
    private func resolveDefaultChange(attempt: Int) {
        let current = AudioSystem.defaultOutputDevice
        trace("resolveDefault attempt=\(attempt) current=\(current ?? 0)")
        if let current, current != 0 {
            followDefault(current, attempt: 0)
            return
        }
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            Task { @MainActor in self?.resolveDefaultChange(attempt: attempt + 1) }
        }
    }

    /// Watchdog for every way following can silently break: a change callback
    /// whose read failed, a device that became usable after the retry window,
    /// a stood-aside device that now works. Two cheap reads every three seconds.
    private func startWatchdog() {
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
    }

    private func watchdogTick() {
        guard enabled, !settingDefault, followRetry == nil,
              let current = AudioSystem.defaultOutputDevice, current != 0 else { return }
        let currentUID = AudioDevice(id: current)?.uid
        if !isEngaged {
            if Date() >= retryAfter { followDefault(current, attempt: 0) }
        } else if currentUID != nil, currentUID != tapEngine.output?.uid {
            followDefault(current, attempt: 0)
        }
    }

    private func devicesChanged() {
        refreshDevices()
        // A vanished default makes macOS pick another; the change notification
        // brings the engine along. Nothing else to do here.
    }

    // MARK: Output selection

    /// The user picked a device in Faded's menu. The default is macOS's to
    /// own; the change notification does the rest.
    func select(_ device: AudioDevice) {
        guard device.hasOutput, !device.isLegacyFadedDevice else { return }
        setSystemDefault(to: device.id)
        followDefault(device.id, attempt: 0)
    }

    private func setSystemDefault(to id: AudioDeviceID) {
        settingDefault = true
        defer { settingDefault = false }
        do {
            try AudioSystem.setDefaultOutputDevice(id)
            try AudioSystem.setDefaultSystemOutputDevice(id)
        } catch {
            Self.log.error("set default failed: \(String(describing: error))")
        }
    }

    private func fallbackDevice() -> AudioDevice? {
        for uid in previousTargets.reversed() {
            if let d = allOutputs.first(where: { $0.uid == uid }) { return d }
        }
        return allOutputs.first(where: { $0.transport == .builtIn }) ?? allOutputs.first
    }

    // MARK: Devices

    func refreshDevices() {
        if previewMode { return }
        allOutputs = AudioDevice.selectableOutputs().sorted(by: Self.deviceOrder)
        let uids = allOutputs.map(\.uid)
        offlineBluetooth = BluetoothAudio.pairedAudioDevices()
            .filter { bt in !uids.contains { BluetoothAudio.matches(uid: $0, id: bt.id) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        refreshInputs()
        if !isEngaged, target == nil {
            target = AudioSystem.defaultOutputDevice.flatMap(AudioDevice.init(id:))
            readVolumeFromTargetDirectly()
        }
    }

    private func refreshInputs() {
        allInputs = AudioDevice.selectableInputs().sorted(by: Self.deviceOrder)
        let current = AudioSystem.defaultInputDevice.flatMap(AudioDevice.init(id:))
        if current?.uid != selectedInput?.uid {
            selectedInput = current
            installInputListeners()
            readInputLevels()
        }
    }

    /// Connect a paired-but-absent Bluetooth device — Control Center's move.
    /// The Bluetooth link comes up off-main; audio arriving shows up as a new
    /// CoreAudio device, which is then selected like any other.
    func connectBluetooth(_ bt: PairedBluetoothDevice) {
        guard connectingBluetooth == nil else { return }
        connectingBluetooth = bt.id
        trace("bt connect \(bt.name) (\(bt.id))")
        let id = bt.id
        DispatchQueue.global(qos: .userInitiated).async {
            let linked = BluetoothAudio.connect(id)
            Task { @MainActor [weak self] in
                trace("bt link \(linked ? "up" : "FAILED") for \(id)")
                // The link alone does not move AirPods audio to the Mac —
                // ownership is negotiated with the other device by the
                // system's routing arbiter. Asking it for playback is what
                // Control Center effectively does; the CoreAudio device
                // appears once arbitration lands.
                AVAudioRoutingArbiter.shared.begin(category: .playback) { _, error in
                    Task { @MainActor in
                        trace("bt arbitration \(error.map { "error: \($0)" } ?? "granted")")
                    }
                }
                self?.awaitBluetoothAudio(id, attempt: 0)
            }
        }
    }

    private func awaitBluetoothAudio(_ id: String, attempt: Int) {
        guard connectingBluetooth == id else { return }
        if let dev = AudioDevice.selectableOutputs()
            .first(where: { BluetoothAudio.matches(uid: $0.uid, id: id) }) {
            trace("bt audio up: \(dev.name) after \(Double(attempt) * 0.5)s")
            AVAudioRoutingArbiter.shared.leave()
            connectingBluetooth = nil
            refreshDevices()
            select(dev)
            return
        }
        // Bluetooth audio profiles take seconds; 30 covers a phone handoff.
        guard attempt < 60 else {
            trace("bt audio never appeared for \(id)")
            AVAudioRoutingArbiter.shared.leave()
            connectingBluetooth = nil
            refreshDevices()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Task { @MainActor in self?.awaitBluetoothAudio(id, attempt: attempt + 1) }
        }
    }

    private static func deviceOrder(_ a: AudioDevice, _ b: AudioDevice) -> Bool {
        if a.transport == .builtIn, b.transport != .builtIn { return true }
        if b.transport == .builtIn, a.transport != .builtIn { return false }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    func setOutputHidden(_ device: AudioDevice, _ hidden: Bool) {
        if hidden { hiddenOutputUIDs.insert(device.uid) } else { hiddenOutputUIDs.remove(device.uid) }
        defaults.set(Array(hiddenOutputUIDs), forKey: Keys.hiddenOutputs)
    }

    func setInputHidden(_ device: AudioDevice, _ hidden: Bool) {
        if hidden { hiddenInputUIDs.insert(device.uid) } else { hiddenInputUIDs.remove(device.uid) }
        defaults.set(Array(hiddenInputUIDs), forKey: Keys.hiddenInputs)
    }

    // MARK: Input selection

    func selectInput(_ device: AudioDevice) {
        guard device.hasInput else { return }
        settingDefault = true
        defer { settingDefault = false }
        try? AudioSystem.setDefaultInputDevice(device.id)
        selectedInput = device
        installInputListeners()
        readInputLevels()
    }

    func setInputVolume(_ v: Float) {
        guard let i = selectedInput, i.hasInputVolume else { return }
        let clamped = min(max(v, 0), 1)
        i.setInputVolume(clamped)
        inputVolume = clamped
        if clamped > 0, inputMuted { setInputMuted(false) }
    }

    func setInputMuted(_ m: Bool) {
        guard let i = selectedInput else { return }
        i.setInputMuted(m)
        inputMuted = m
    }

    private func readInputLevels() {
        guard let i = selectedInput else { inputVolume = 1; inputMuted = false; return }
        inputVolume = i.inputVolume ?? 1
        inputMuted = i.isInputMuted ?? false
    }

    private func installInputListeners() {
        inputControlListeners.removeAll()
        guard let i = selectedInput else { return }
        inputControlListeners = i.inputVolumeListenerAddresses.map { addr in
            AudioObject.listen(i.id, addr) { [weak self] in
                Task { @MainActor in self?.readInputLevels() }
            }
        }
    }

    // MARK: Output volume

    func setVolume(_ v: Float) {
        let clamped = min(max(v, 0), 1)
        guard let t = target else { return }
        if t.hasHardwareVolume {
            t.setVolume(clamped)
        } else if isEngaged {
            volumeByDevice[t.uid] = clamped
            defaults.set(volumeByDevice, forKey: Keys.volumeByDevice)
            tapEngine.setMaster(clamped, muted: false)
        } else {
            return   // nothing can apply it
        }
        volume = clamped
        if muted { setMuted(false) }
    }

    func setMuted(_ m: Bool) {
        guard let t = target else { return }
        if t.hasHardwareMute {
            t.setMuted(m)
        } else if isEngaged {
            mutedByDevice[t.uid] = m
            defaults.set(mutedByDevice, forKey: Keys.mutedByDevice)
            tapEngine.setMaster(volume, muted: m)
        } else {
            return
        }
        muted = m
    }

    /// Seed the slider and the engine's master gain for the current device.
    private func applyVolumeForTarget() {
        guard let t = target else { return }
        if t.hasHardwareVolume {
            volume = t.volume ?? 1
            muted = t.isMuted ?? false
            tapEngine.setMaster(1, muted: false)
        } else {
            volume = volumeByDevice[t.uid] ?? 1
            muted = mutedByDevice[t.uid] ?? false
            tapEngine.setMaster(volume, muted: muted)
        }
    }

    /// Not engaged: the slider just shows/drives the real device.
    private func readVolumeFromTargetDirectly() {
        guard !isEngaged, let t = target else { return }
        volume = t.volume ?? 1
        muted = t.isMuted ?? false
    }

    /// The device's own volume changed elsewhere (AirPods stem, Control
    /// Center, another app) → reflect it.
    private func targetControlChanged() {
        guard let t = target else { return }
        if t.hasHardwareVolume, let v = t.volume { volume = v }
        if t.hasHardwareMute, let m = t.isMuted { muted = m }
    }

    private func installTargetListeners() {
        targetControlListeners.removeAll()
        guard let t = target else { return }
        targetControlListeners = t.volumeListenerAddresses.map { addr in
            AudioObject.listen(t.id, addr) { [weak self] in
                Task { @MainActor in self?.targetControlChanged() }
            }
        }
    }

    // MARK: Volume keys

    /// Volume keys are only intercepted on devices that have no volume of
    /// their own; everywhere else macOS handles them natively.
    private func updateMediaKeys() {
        let wants = isEngaged && (target.map { !$0.hasHardwareVolume } ?? false)
        guard wants else {
            mediaKeys.isActive = false
            needsAccessibility = false
            return
        }
        if mediaKeys.start() {
            mediaKeys.isActive = true
            needsAccessibility = false
        } else {
            mediaKeys.isActive = false
            needsAccessibility = true
        }
    }

    func requestAccessibility() {
        MediaKeyTap.requestAccessibility()
        // Grants arrive asynchronously through System Settings; poll briefly.
        Task { @MainActor in
            for _ in 0 ..< 60 {
                try? await Task.sleep(for: .seconds(1))
                if MediaKeyTap.hasAccessibility { updateMediaKeys(); break }
            }
        }
    }

    private func handleMediaKey(_ key: MediaKeyTap.Key) {
        let step: Float = 1.0 / 16.0
        switch key {
        case .up: setVolume(min(1, (muted ? 0 : volume) + step))
        case .down: setVolume(max(0, volume - step))
        case .mute: setMuted(!muted)
        }
        hud.show(volume: volume, muted: muted, deviceName: target?.name ?? "")
    }

    // MARK: The engine's stream

    /// One-second safety net behind the listeners: gather peaks for the
    /// audible bookkeeping even with the menu closed, and re-check that our
    /// stream state matches what the apps are doing.
    private func startPolling() {
        pollTimer?.invalidate()
        lastSignal = Date()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard isEngaged else { return }
        pollEnginePeaks()
        pollTicks += 1
        if pollTicks % 10 == 0 {
            let loudest = peaksByProcess.values.max() ?? 0
            trace("engine: \(tapEngine.stats) loudest=\(loudest) output=\(target?.name ?? "-") idle=\(Int(Date().timeIntervalSince(lastSignal)))s")
        }
        if !menuPopoverIsVisible { peaksByProcess.removeAll() }
        reconcileStream()
    }

    /// Our stream runs exactly while some app runs output — what macOS sees
    /// natively. Stopping waits a moment so players that close and reopen
    /// their stream between tracks don't make us flap.
    private func reconcileStream() {
        guard isEngaged else { return }
        let wanted = tapEngine.anyProcessRunningOutput
        if wanted {
            stopWork?.cancel()
            stopWork = nil
            guard !tapEngine.isRunning, Date() >= retryAfter else { return }
            do {
                try tapEngine.resumeIO()
                startFailures = 0
            } catch {
                startFailures += 1
                trace("stream start failed (\(startFailures)): \(error)")
                if startFailures >= 3, let t = target {
                    // Taps are muting everything and we cannot play it: get
                    // out of the way so audio flows natively, try again later.
                    standAside(for: t, reason: "stream will not start")
                }
            }
        } else if tapEngine.isRunning, stopWork == nil {
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.isEngaged else { return }
                    self.stopWork = nil
                    if !self.tapEngine.anyProcessRunningOutput { self.tapEngine.pauseIO() }
                }
            }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    private func pollEnginePeaks() {
        let fresh = tapEngine.takePeaks()
        var anySignal = false
        for (k, v) in fresh {
            peaksByProcess[k] = max(peaksByProcess[k] ?? 0, v)
            if v > audibleThreshold { anySignal = true }
        }
        if anySignal { lastSignal = Date() }
    }

    private func resolvedApp(for p: TappedProcess) -> ResolvedApp {
        if let r = resolvedByProcess[p.id] { return r }
        let r = ProcessResolver.resolve(pid: p.pid, bundleID: p.bundleID)
        resolvedByProcess[p.id] = r
        return r
    }

    // MARK: Per-app volume

    func refreshApps() {
        if previewMode { return }
        var byApp: [String: AppEntry] = [:]
        var playingOrder: [String] = []

        for p in tapEngine.processes {
            let app = resolvedApp(for: p)
            appNames[app.id] = app.name
            let peak = peaksByProcess[p.id] ?? 0
            if var e = byApp[app.id] {
                e.peak = max(e.peak, peak)
                byApp[app.id] = e
            } else {
                byApp[app.id] = AppEntry(id: app.id, name: app.name, pid: app.pid,
                                         gain: appGains[app.id] ?? 1,
                                         muted: appMutedLevels[app.id] != nil,
                                         peak: peak, isBare: app.isBare,
                                         starred: starredApps.contains(app.id), isPlaying: true)
                playingOrder.append(app.id)
            }
        }

        // Anything that has actually made a sound recently stays listed for a
        // few seconds, so a quiet passage or a pause doesn't make the row
        // disappear under the cursor.
        let now = Date()
        for (id, e) in byApp where e.peak > audibleThreshold { lastAudible[id] = now }
        func audible(_ id: String) -> Bool {
            guard let t = lastAudible[id] else { return false }
            return now.timeIntervalSince(t) < audibleHold
        }
        byApp = byApp.filter { audible($0.key) || starredApps.contains($0.key) }
        for (id, e) in byApp where !audible(id) {
            var e = e; e.isPlaying = false; byApp[id] = e
        }

        // Starred apps stay in the list even when they're silent or not
        // running, so their level can be set before they make a sound.
        for id in starredApps where byApp[id] == nil {
            let name = appNames[id] ?? ProcessResolver.staticInfo(bundleID: id)?.name ?? id
            byApp[id] = AppEntry(id: id, name: name, pid: 0,
                                 gain: appGains[id] ?? 1,
                                 muted: appMutedLevels[id] != nil,
                                 peak: 0, isBare: id.hasPrefix("pid:"),
                                 starred: true, isPlaying: false)
        }
        defaults.set(appNames, forKey: Keys.appNames)

        let starred = byApp.values.filter(\.starred).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let rest = playingOrder.compactMap { byApp[$0] }.filter { !$0.starred }
        apps = starred + rest
    }

    /// Push every process's gain to the engine from the stored per-app levels.
    private func pushAllAppGains() {
        for p in tapEngine.processes {
            let id = resolvedApp(for: p).id
            tapEngine.setGain(forProcess: p.id, appMutedLevels[id] != nil ? 0 : (appGains[id] ?? 1))
        }
    }

    func setAppGain(_ appID: String, _ gain: Float) {
        let g = min(max(gain, 0), 1)   // no boost
        appGains[appID] = g
        if g > 0 { appMutedLevels[appID] = nil }
        persistApps()
        if let i = apps.firstIndex(where: { $0.id == appID }) {
            apps[i].gain = g
            apps[i].muted = appMutedLevels[appID] != nil
        }
        pushAllAppGains()
    }

    func setAppMuted(_ appID: String, _ m: Bool) {
        appMutedLevels[appID] = m ? (appGains[appID] ?? 1) : nil
        persistApps()
        if let i = apps.firstIndex(where: { $0.id == appID }) { apps[i].muted = m }
        pushAllAppGains()
    }

    func setAppStarred(_ appID: String, _ starred: Bool) {
        if starred { starredApps.insert(appID) } else { starredApps.remove(appID) }
        defaults.set(Array(starredApps), forKey: Keys.starredApps)
        refreshApps()
    }

    func resetAppGain(_ appID: String) {
        appGains[appID] = nil
        appMutedLevels[appID] = nil
        persistApps()
        if let i = apps.firstIndex(where: { $0.id == appID }) { apps[i].gain = 1; apps[i].muted = false }
        pushAllAppGains()
    }

    /// Every app Faded has a saved setting or star for — the Settings list.
    func knownApps() -> [AppEntry] {
        let ids = Set(appGains.keys).union(appMutedLevels.keys).union(starredApps)
        return ids.map { id in
            apps.first { $0.id == id } ?? AppEntry(id: id,
                                                   name: appNames[id] ?? ProcessResolver.staticInfo(bundleID: id)?.name ?? id,
                                                   pid: 0,
                                                   gain: appGains[id] ?? 1,
                                                   muted: appMutedLevels[id] != nil,
                                                   peak: 0,
                                                   isBare: id.hasPrefix("pid:"),
                                                   starred: starredApps.contains(id), isPlaying: false)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func forgetApp(_ appID: String) {
        appGains[appID] = nil
        appMutedLevels[appID] = nil
        appNames[appID] = nil
        starredApps.remove(appID)
        persistApps()
        defaults.set(Array(starredApps), forKey: Keys.starredApps)
        defaults.set(appNames, forKey: Keys.appNames)
        refreshApps()
        pushAllAppGains()
    }

    private func persistApps() {
        defaults.set(appGains, forKey: Keys.appGains)
        defaults.set(appMutedLevels, forKey: Keys.appMutedLevels)
    }

    // MARK: Meters — only while the menu is open

    /// Start the meter loop.
    ///
    /// `MenuBarExtra(.window)` builds its content view at launch and does not
    /// reliably send `onDisappear` when the popover closes, so visibility is
    /// checked on every tick instead: the popover is a non-`.normal` level
    /// window, the Settings window is `.normal`. Anything mic-related is gated
    /// on that check, and the loop shuts itself down once the popover has been
    /// gone for a few seconds.
    func startMetering() {
        if previewMode || meterTimer != nil { return }
        idleTicks = 0
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMeters() }
        }
    }

    func stopMetering() {
        if previewMode { return }
        meterTimer?.invalidate()
        meterTimer = nil
        inputMeter.stop()
        outputLevel = (0, 0)
        inputLevel = (0, 0)
    }

    /// True while the menu bar popover is on screen. The Settings window sits
    /// at `.normal` level, so it does not count — no reason to hold the
    /// microphone open while someone is reading a preferences pane.
    private var menuPopoverIsVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.level != .normal }
    }

    private func tickMeters() {
        if previewMode { return }

        guard menuPopoverIsVisible else {
            // Popover closed (or never opened). Release the microphone at once
            // and wind the whole loop down shortly after.
            inputMeter.stop()
            inputLevel = (0, 0)
            outputLevel = (0, 0)
            idleTicks += 1
            if idleTicks > 45 { stopMetering() }   // ~3 s
            return
        }
        idleTicks = 0

        if showMeters, showInputMeter, let i = selectedInput, InputMeter.canMeter(i) {
            inputMeter.start(device: i)
            inputLevel = inputMeter.level
        } else {
            inputMeter.stop()
            inputLevel = (0, 0)
        }

        guard isEngaged else { outputLevel = (0, 0); return }
        outputLevel = tapEngine.takeOutputPeak()
        pollEnginePeaks()
        var peakByApp: [String: Float] = [:]
        for p in tapEngine.processes {
            let id = resolvedApp(for: p).id
            peakByApp[id] = max(peakByApp[id] ?? 0, peaksByProcess[p.id] ?? 0)
        }
        peaksByProcess.removeAll()
        for i in apps.indices { apps[i].peak = peakByApp[apps[i].id] ?? 0 }

        // Did anything start or stop being audible? Only then rebuild the list.
        let now = Date()
        let before = Set(apps.map(\.id))
        var changed = false
        for (id, peak) in peakByApp where peak > audibleThreshold {
            if lastAudible[id] == nil || !before.contains(id) { changed = true }
            lastAudible[id] = now
        }
        if !changed {
            changed = apps.contains { !$0.starred && (lastAudible[$0.id].map { now.timeIntervalSince($0) >= audibleHold } ?? true) }
        }
        if changed { refreshApps() }
    }

#if DEBUG
    /// Fills in the parts of the menu that need a running engine so the layout
    /// can be rendered and reviewed without touching the audio system.
    /// `demo: true` also swaps in invented devices, so the README screenshot
    /// doesn't leak the device names of whatever machine generated it.
    /// Used by `--render-menu`; never reachable in a Release build.
    func applyPreviewState(demo: Bool = false) {
        previewMode = true
        isEngaged = true
        volume = 0.55
        outputLevel = (0.42, 0.51)
        apps = [
            AppEntry(id: "com.spotify.client", name: "Spotify", pid: 0, gain: 0.65, muted: false,
                     peak: 0.5, isBare: false, starred: true, isPlaying: true),
            AppEntry(id: "com.hnc.Discord", name: "Discord", pid: 0, gain: 1, muted: false,
                     peak: 0.12, isBare: false, starred: true, isPlaying: true),
            AppEntry(id: "com.apple.Safari", name: "Safari", pid: 0, gain: 0.4, muted: true,
                     peak: 0, isBare: false, starred: false, isPlaying: true),
        ]
        browserTabs = [
            BrowserTab(id: 1, title: "Lofi hip hop radio — beats to relax/study to", gain: 0.5, audible: true, muted: false),
            BrowserTab(id: 2, title: "Some podcast I keep open", gain: 1, audible: true, muted: false),
        ]
        browserBridgeConnected = true
        if demo {
            allOutputs = [
                AudioDevice(demoID: 1, uid: "d1", name: "MacBook Pro Speakers", transport: .builtIn,
                            hasOutput: true, hasInput: false, hasHardwareVolume: true, hasInputVolume: false),
                AudioDevice(demoID: 2, uid: "d2", name: "Astro A50 Game", transport: .usb,
                            hasOutput: true, hasInput: true, hasHardwareVolume: false, hasInputVolume: false),
                AudioDevice(demoID: 3, uid: "d3", name: "AirPods Pro", transport: .bluetooth,
                            hasOutput: true, hasInput: true, hasHardwareVolume: true, hasInputVolume: false),
                AudioDevice(demoID: 4, uid: "d4", name: "Studio Display", transport: .displayPort,
                            hasOutput: true, hasInput: false, hasHardwareVolume: false, hasInputVolume: false),
            ]
            allInputs = [
                AudioDevice(demoID: 5, uid: "d5", name: "MacBook Pro Microphone", transport: .builtIn,
                            hasOutput: false, hasInput: true, hasHardwareVolume: false, hasInputVolume: true),
                AudioDevice(demoID: 6, uid: "d6", name: "Astro A50 Voice", transport: .usb,
                            hasOutput: false, hasInput: true, hasHardwareVolume: false, hasInputVolume: false),
            ]
            target = allOutputs[1]        // the Astro — software volume, the reason this exists
            selectedInput = allInputs[0]
            return
        }
        if target == nil { target = allOutputs.first }
        if selectedInput == nil { selectedInput = allInputs.first }
    }
#endif

    // MARK: Diagnostics

    var diagnostics: String {
        var s = "enabled: \(enabled)  engaged: \(isEngaged)  steppedAside: \(steppedAside)\n"
        s += "output: \(target?.name ?? "-")  hw volume: \(target?.hasHardwareVolume ?? false) (false ⇒ software master gain)\n"
        s += "input: \(selectedInput?.name ?? "-")\n"
        s += "engine: \(tapEngine.stats)\n"
        s += "accessibility: \(MediaKeyTap.hasAccessibility)  bridge: \(browserBridgeConnected ? "connected" : "not connected")\n"
        s += "legacy driver installed: \(LegacyDriver.isInstalled)\n"
        if let err = lastError { s += "last error: \(err)" }
        return s
    }
}
