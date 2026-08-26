// AudioRouter.swift — the brain. Owns the driver link, the play-through
// engine, the "which real device are we playing to" decision, volume
// mirroring, input selection, per-app gains, meters and persistence.
//
// Invariants while engaged:
//   * macOS default output == "Faded" (so every app plays into the driver).
//   * `target` is the real device Faded.app plays to.
//   * The Faded device's volume/mute controls always show the *target's*
//     level. If the target has hardware volume we mirror the value onto it and
//     tell the driver to bypass its own gain (no double attenuation); if it
//     doesn't (Astro A50 & friends) the driver applies the gain in software.
//     Either way the keyboard volume keys drive the Faded control, which is
//     the whole point.
//   * When macOS or the user changes the default output to something else
//     (Control Center, AirPods auto-switch, AirPlay pick), we adopt that
//     device as the new target and put Faded back as default. That is what
//     keeps AirPlay/AirPods behaving exactly like the stock menu.
//
// Input is *not* interposed: Faded selects the system input device and drives
// its hardware volume/mute directly. Nothing sits in the mic path, so no app
// ever sees a fake microphone.

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
    private static let log = Logger(subsystem: FadedProtocol.appBundleID, category: "Router")

    // MARK: Observable state

    private(set) var driverStatus: DriverLink.Status = .notInstalled
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
    private(set) var isEngaged = false
    private(set) var lastError: String?
    /// True when macOS is routing output somewhere Faded cannot follow (an
    /// AirPlay speaker). Faded is passive and the menu says so.
    private(set) var steppedAside = false

    /// Master output meter (L, R), 0…1 — straight from the driver.
    private(set) var outputLevel: (Float, Float) = (0, 0)
    /// Selected input meter (L, R), 0…1.
    private(set) var inputLevel: (Float, Float) = (0, 0)

    // MARK: Settings (persisted)

    /// Route audio through Faded (false = leave macOS completely alone).
    var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            defaults.set(enabled, forKey: Keys.enabled)
            enabled ? engage() : disengage(restoreDefault: true)
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
    /// metering is free (the driver already has the mixed buffer), but there is
    /// no property anywhere in CoreAudio that reports an input's level, so this
    /// one has to open a capture stream — which lights the orange microphone
    /// indicator in the menu bar for as long as it runs. Faded does not do that
    /// unless you ask for it.
    var showInputMeter: Bool {
        didSet {
            guard oldValue != showInputMeter else { return }
            defaults.set(showInputMeter, forKey: Keys.showInputMeter)
            if !showInputMeter { inputMeter.stop(); inputLevel = (0, 0) }
        }
    }

    /// Route Bluetooth headphones through Faded like any other device.
    ///
    /// OFF by default, deliberately. AirPods-class devices carry their own
    /// hardware volume (the keys work natively) and their whole ecosystem —
    /// automatic switching between Mac and iPhone, ear-detection pause, the
    /// connection banners — keys off macOS owning the default device. Every
    /// time Faded reclaims the default from them, Apple's heuristics read it
    /// as the user rejecting the AirPods and learn to stop switching. So in
    /// native mode Faded stands aside while a Bluetooth device holds the
    /// default, and returns the moment any other device does. The cost is
    /// per-app volume for Mac apps during that time; browser tab volumes are
    /// browser-side and keep working.
    var routeBluetoothThroughFaded: Bool {
        didSet {
            guard oldValue != routeBluetoothThroughFaded else { return }
            defaults.set(routeBluetoothThroughFaded, forKey: Keys.routeBluetooth)
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
        var keys: Set<String>
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

    let driver = DriverLink()
    let bridge = BrowserBridge()
    private let engine = PlayThrough()
    private let inputMeter = InputMeter()
    private let defaults = UserDefaults.standard

    private var defaultOutputListener: ListenerToken?
    private var defaultInputListener: ListenerToken?
    private var deviceListListener: ListenerToken?
    private var fadedControlListeners: [ListenerToken] = []
    private var targetControlListeners: [ListenerToken] = []
    private var targetRateListener: ListenerToken?
    private var fadedRateListener: ListenerToken?
    private var fadedRunningListener: ListenerToken?
    private var idlePauseTimer: Timer?
    private var reconcileTimer: Timer?
    private var inputControlListeners: [ListenerToken] = []
    private var meterTimer: Timer?
    private var healthTimer: Timer?
    private var lastHealth: (under: UInt64, resync: UInt64) = (0, 0)
    private var adoptRetry: DispatchWorkItem?
    private var idleTicks = 0

    private var previewMode = false      // DEBUG --render-menu only
    private var settingDefault = false   // re-entrancy guard for default-device writes
    private var syncingVolume = false    // re-entrancy guard for volume mirroring

    private var volumeByDevice: [String: Float]
    private var mutedByDevice: [String: Bool]
    private var appGains: [String: Float]        // app id → gain
    private var appMutedLevels: [String: Float]  // app id → level stashed while muted
    private var appNames: [String: String]       // app id → last seen display name
    private var appKeys: [String: [String]]      // app id → driver client keys last seen
    private var previousTargets: [String] = []   // UIDs, most recent last

    /// App id → when it last produced a signal above `audibleThreshold`.
    /// Every process that merely *opens* the device is a driver client —
    /// corespeechd, callservicesd, loginwindow, Siri and a dozen other daemons
    /// sit there permanently at digital silence. Only things actually making
    /// sound belong in the menu, so an app has to have been audible recently to
    /// be listed (starred apps are exempt).
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
        static let appKeys = "appKeys"
        static let lastTarget = "lastTargetUID"
        static let previousTargets = "previousTargets"
        static let showMeters = "showMeters"
        static let showInputMeter = "showInputMeter"
        static let routeBluetooth = "routeBluetoothThroughFaded"
        static let showInputSection = "showInputSection"
        static let hiddenOutputs = "hiddenOutputUIDs"
        static let hiddenInputs = "hiddenInputUIDs"
        static let starredApps = "starredApps"
    }

    init() {
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        showMeters = defaults.object(forKey: Keys.showMeters) as? Bool ?? true
        showInputMeter = defaults.bool(forKey: Keys.showInputMeter)   // opt-in: uses the mic
        routeBluetoothThroughFaded = defaults.bool(forKey: Keys.routeBluetooth)
        showInputSection = defaults.object(forKey: Keys.showInputSection) as? Bool ?? true
        volumeByDevice = defaults.dictionary(forKey: Keys.volumeByDevice) as? [String: Float] ?? [:]
        mutedByDevice = defaults.dictionary(forKey: Keys.mutedByDevice) as? [String: Bool] ?? [:]
        appGains = defaults.dictionary(forKey: Keys.appGains) as? [String: Float] ?? [:]
        appMutedLevels = defaults.dictionary(forKey: Keys.appMutedLevels) as? [String: Float] ?? [:]
        appNames = defaults.dictionary(forKey: Keys.appNames) as? [String: String] ?? [:]
        appKeys = defaults.dictionary(forKey: Keys.appKeys) as? [String: [String]] ?? [:]
        previousTargets = defaults.stringArray(forKey: Keys.previousTargets) ?? []
        hiddenOutputUIDs = Set(defaults.stringArray(forKey: Keys.hiddenOutputs) ?? [])
        hiddenInputUIDs = Set(defaults.stringArray(forKey: Keys.hiddenInputs) ?? [])
        starredApps = Set(defaults.stringArray(forKey: Keys.starredApps) ?? [])

        driver.onClientsChanged = { [weak self] in self?.refreshApps() }
        driver.onAvailabilityChanged = { [weak self] in self?.driverAvailabilityChanged() }
        driverStatus = driver.status

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
        guard !isEngaged, driver.isReady, let faded = driver.outputDevice else {
            driverStatus = driver.status
            return
        }
        lastError = nil

        let systemDefault = AudioSystem.defaultOutputDevice.flatMap(AudioDevice.init(id:))
        let initial: AudioDevice? = if let d = systemDefault, !d.isFadedDevice, d.hasOutput {
            d
        } else if let uid = defaults.string(forKey: Keys.lastTarget), let d = allOutputs.first(where: { $0.uid == uid }) {
            d
        } else {
            fallbackDevice()
        }
        guard let initialTarget = initial else {
            lastError = "No output device to play to."
            return
        }

        if initialTarget.transport == .bluetooth, !routeBluetoothThroughFaded,
           AudioSystem.defaultOutputDevice == initialTarget.id {
            standAside(for: initialTarget, reason: "bluetooth default at engage")
            return
        }

        target = initialTarget
        do {
            try startEngine(for: initialTarget)
        } catch {
            lastError = "\(error)"
            Self.log.error("engine start failed: \(String(describing: error))")
            return
        }
        // Tested and settled: macOS refuses to use a device with
        // kAudioDevicePropertyIsHidden set as the default output, so Faded is
        // always visible. It reports the target's name instead (see
        // driver.setDisplayName), which is what the volume HUD shows.
        driver.setOutputHidden(false)
        setSystemDefault(to: faded.id)
        installFadedControlListeners()
        installTargetListeners()
        startHealthLogging()
        driver.setDisplayName(initialTarget.name)
        pushAllAppGains()
        applyVolumeForTarget()
        isEngaged = true
        trace("engaged → \(initialTarget.name)")
        installIdleRelease()
        refreshApps()
        Self.log.notice("engaged → \(initialTarget.name)")
    }

    func disengage(restoreDefault: Bool) {
        guard isEngaged else { return }
        healthTimer?.invalidate()
        healthTimer = nil
        engine.stop()
        fadedControlListeners.removeAll()
        targetControlListeners.removeAll()
        targetRateListener = nil
        fadedRateListener = nil
        if restoreDefault, let t = target, t.isAlive {
            setSystemDefault(to: t.id)
        }
        outputLevel = (0, 0)
        isEngaged = false
        fadedRunningListener = nil
        idlePauseTimer?.invalidate()
        idlePauseTimer = nil
        // Nothing is being routed any more; stop impersonating a real device.
        driver.setDisplayName(FadedProtocol.outputDeviceName)
        Self.log.notice("disengaged")
    }

    /// Call from applicationWillTerminate.
    func shutdown() {
        bridge.stop()
        inputMeter.stop()
        disengage(restoreDefault: true)
    }

    /// Glitches that happen "sometimes" cannot be caught live, so the engine
    /// leaves a trail: whenever a dropout or a resync actually occurs it is
    /// logged at notice level (which persists), along with the state of the
    /// drift loop at that moment. Afterwards,
    ///   log show --predicate 'subsystem == "com.andri.faded"' --last 1h
    /// answers what happened and when, instead of relying on someone noticing
    /// a click and remembering what they were doing.
    private func startHealthLogging() {
        healthTimer?.invalidate()
        lastHealth = (0, 0)
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.logHealth() }
        }
    }

    private func logHealth() {
        guard isEngaged else { return }
        let e = engine.stats
        guard e.underruns != lastHealth.under || e.resyncs != lastHealth.resync else { return }
        let newUnder = e.underruns &- lastHealth.under
        let newResync = e.resyncs &- lastHealth.resync
        lastHealth = (e.underruns, e.resyncs)
        let fill = Int(e.fill)
        let ppm = Int(e.driftPPM)
        Self.log.notice("audio dropout: \(newUnder) underrun(s), \(newResync) resync(s) — fill \(fill) frames, drift correction \(ppm) ppm")
    }

    // MARK: Idle release

    /// The HAL flips kAudioDevicePropertyDeviceIsRunningSomewhere on the Faded
    /// device the moment any app starts or stops doing I/O to it. Playing →
    /// output opens immediately (the ring buffers the first frames, so nothing
    /// is lost). Silent for ten seconds → the output stream is released, which
    /// lets devices sleep and — the part that matters for AirPods — lets
    /// Apple's automatic switching hand them back to the iPhone, which it will
    /// never do while the Mac holds a stream open.
    private func installIdleRelease() {
        guard let faded = driver.outputDevice else { return }
        fadedRunningListener = AudioObject.listen(faded.id,
            .init(kAudioDevicePropertyDeviceIsRunningSomewhere)) { [weak self] in
            Task { @MainActor in self?.producerRunningChanged() }
        }
        producerRunningChanged()
    }

    private func producerRunningChanged() {
        guard isEngaged, let faded = driver.outputDevice else { return }
        let running = (try? AudioObject.get(faded.id,
            .init(kAudioDevicePropertyDeviceIsRunningSomewhere), as: UInt32.self)) ?? 0
        trace("producerRunning=\(running)")
        if running != 0 {
            idlePauseTimer?.invalidate()
            idlePauseTimer = nil
            engine.resumeOutput()
        } else if idlePauseTimer == nil {
            idlePauseTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isEngaged else { return }
                    trace("idle 10 s — pausing output")
                    self.engine.pauseOutput()
                }
            }
        }
    }

    // MARK: Output selection

    func select(_ device: AudioDevice) {
        guard device.hasOutput, !device.isFadedDevice else { return }
        // Native Bluetooth mode: hand the device to macOS outright, whichever
        // state we were in — same behaviour as an auto-switch landing on it.
        if device.transport == .bluetooth, !routeBluetoothThroughFaded {
            setSystemDefault(to: device.id)
            standAside(for: device, reason: "selected in menu")
            return
        }
        steppedAside = false
        if !isEngaged {
            if enabled, driver.isReady {
                setSystemDefault(to: device.id)
                target = device
                engage()
                return
            }
            setSystemDefault(to: device.id)
            target = device
            readVolumeFromTargetDirectly()
            return
        }
        retarget(device)
    }

    private func retarget(_ device: AudioDevice) {
        if let old = target, old.uid != device.uid {
            previousTargets.removeAll { $0 == old.uid }
            previousTargets.append(old.uid)
            if previousTargets.count > 8 { previousTargets.removeFirst() }
            defaults.set(previousTargets, forKey: Keys.previousTargets)
        }
        target = device
        defaults.set(device.uid, forKey: Keys.lastTarget)
        do {
            let rate = engineRate(for: device)
            if engine.isRunning, abs(engine.sampleRate - rate) < 1 {
                try engine.retarget(output: device.id)
            } else {
                try startEngine(for: device)
            }
        } catch {
            lastError = "\(error)"
            Self.log.error("retarget failed: \(String(describing: error))")
        }
        installTargetListeners()
        applyVolumeForTarget()
        driver.setDisplayName(device.name)
        trace("retarget complete → \(device.name); displayName sent")
    }

    private func startEngine(for device: AudioDevice) throws {
        // Whatever rate the Faded device is currently running at is the rate
        // the driver produces frames at. Follow it rather than imposing one —
        // the output unit converts to the target device's own rate anyway.
        let rate = driver.outputDevice?.nominalSampleRate ?? FadedProtocol.defaultSampleRate
        try engine.start(output: device.id, sampleRate: rate > 0 ? rate : FadedProtocol.defaultSampleRate)
    }

    /// Run the virtual devices at the target's rate when we can, so nothing
    /// resamples; otherwise 48 kHz and let AUHAL convert on the way out.
    private func engineRate(for device: AudioDevice) -> Double {
        let r = device.nominalSampleRate
        return FadedProtocol.supportedSampleRates.contains(r) ? r : FadedProtocol.defaultSampleRate
    }

    private func fallbackDevice() -> AudioDevice? {
        for uid in previousTargets.reversed() {
            if let d = allOutputs.first(where: { $0.uid == uid }) { return d }
        }
        return allOutputs.first(where: { $0.transport == .builtIn }) ?? allOutputs.first
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

    // MARK: System default management

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

    /// The system default output moved.
    ///
    /// Normally we adopt the new device as the play-to target and take the
    /// default back, so everything keeps flowing through Faded.
    ///
    /// The subtle case is AirPlay. An AirPlay speaker is not a CoreAudio device
    /// while it is idle — macOS *materialises* a device named "AirPlay" at the
    /// instant you pick one, and makes it the default in the same breath. Its
    /// streams are not configured yet when the notification arrives, so a
    /// snapshot taken right now reports no output channels and it looks like
    /// something we cannot play to. Standing down on that first look is what
    /// made Faded miss AirPlay entirely; instead the device gets a few hundred
    /// milliseconds to finish appearing before we give up on it.
    private func defaultOutputChanged() {
        guard !settingDefault else { return }
        resolveDefaultChange(attempt: 0)
    }

    /// Reading kAudioHardwarePropertyDefaultOutputDevice from inside the HAL's
    /// own change callback frequently returns kAudioObjectUnknown — the HAL is
    /// mid-transaction. Trusting that read made the app deaf to device
    /// switches whenever the timing was wrong (which for AirPods was nearly
    /// always). So the read is retried on a short timer until the HAL answers.
    private func resolveDefaultChange(attempt: Int) {
        guard let faded = driver.outputDevice else { return }
        let current = AudioSystem.defaultOutputDevice
        trace("resolveDefault attempt=\(attempt) current=\(current ?? 0)")
        if let current, current != 0 {
            if current != faded.id { adopt(current, attempt: 0) }
            return
        }
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            Task { @MainActor in self?.resolveDefaultChange(attempt: attempt + 1) }
        }
    }

    /// Adopt `deviceID` if we can play to it, retrying briefly while it settles.
    private func adopt(_ deviceID: AudioDeviceID, attempt: Int) {
        trace("adopt(\(deviceID), attempt \(attempt))")
        guard let faded = driver.outputDevice else { return }
        // The default moved again mid-retry (AirPods connects flip it more
        // than once). Chase the new one rather than silently giving up.
        if let current = AudioSystem.defaultOutputDevice, current != deviceID {
            if current != faded.id { adopt(current, attempt: 0) }
            return
        }

        let device = AudioDevice(id: deviceID)
        let adoptable = device.map { $0.hasOutput && !$0.isFadedDevice && $0.isAlive } ?? false

        if let d = device {
            trace("adopt: adoptable=\(adoptable) name=\(d.name) hasOutput=\(d.hasOutput) alive=\(d.isAlive) isFaded=\(d.isFadedDevice) engaged=\(isEngaged)")
        } else {
            trace("adopt: device snapshot nil for \(deviceID)")
        }
        adoptRetry?.cancel()
        adoptRetry = nil

        // Native Bluetooth mode: a BT headset holding the default is the
        // intended steady state, not something to fight — reclaiming it reads
        // to Apple's auto-switch heuristics as the user rejecting the device.
        if let d = device, d.transport == .bluetooth, !routeBluetoothThroughFaded {
            standAside(for: d, reason: "bluetooth handled natively")
            return
        }

        if adoptable, let device {
            if isEngaged {
                Self.log.info("system default moved to \(device.name) — following")
                retarget(device)
                setSystemDefault(to: faded.id)
            } else if enabled, driver.isReady {
                Self.log.info("adoptable device \(device.name) is default — engaging")
                steppedAside = false
                target = device
                engage()
            }
            return
        }

        // Bluetooth audio takes seconds to bring its streams up, not the few
        // hundred milliseconds AirPlay needs — a window that ends before the
        // device is ready leaves Faded stood aside with no event to ever wake
        // it (the default never changes again). Ten seconds covers AirPods
        // reconnecting from an iPhone handoff.
        if attempt < 40 {
            adoptRetry?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.adopt(deviceID, attempt: attempt + 1) }
            }
            adoptRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            return
        }

        // Genuinely cannot follow it. Let macOS route natively rather than
        // fighting for the default and yanking playback away from the user.
        guard isEngaged else { return }
        standAside(for: device, reason: "not adoptable")
    }

    /// Faded gets out of the audio path entirely, tracking the device only for
    /// display: the header names it, and the menu's slider drives its hardware
    /// volume directly. Idempotent so the watchdog can call it every tick.
    private func standAside(for device: AudioDevice?, reason: String) {
        if steppedAside, target?.uid == device?.uid { return }
        trace("standing aside for \(device?.name ?? "?") (\(reason))")
        steppedAside = true
        if isEngaged { disengage(restoreDefault: false) }
        target = device
        installTargetListeners()
        readVolumeFromTargetDirectly()
    }

    /// Watchdog for every way routing can silently break: a change callback
    /// whose read failed, a device that became adoptable after the retry
    /// window, a stepped-aside AirPlay session ending, a stolen default. Two
    /// cheap property reads every three seconds; acts only when the default
    /// is a real device that is not Faded.
    private func startWatchdog() {
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
    }

    private func watchdogTick() {
        guard enabled, driver.isReady, !settingDefault, adoptRetry == nil,
              let faded = driver.outputDevice,
              let current = AudioSystem.defaultOutputDevice, current != 0,
              current != faded.id
        else { return }
        if !routeBluetoothThroughFaded, let dev = AudioDevice(id: current),
           dev.transport == .bluetooth {
            standAside(for: dev, reason: "watchdog")
            return
        }
        trace("watchdog: default is \(current), not faded — adopting")
        steppedAside = false
        adopt(current, attempt: 0)
    }

    private func devicesChanged() {
        refreshDevices()
        driver.refresh()
        driverStatus = driver.status
        guard isEngaged else { return }
        if let t = target, !allOutputs.contains(where: { $0.uid == t.uid }) || !t.isAlive {
            Self.log.info("target \(t.name) vanished")
            if let fb = fallbackDevice() { retarget(fb) } else { disengage(restoreDefault: false) }
        }
    }

    private func driverAvailabilityChanged() {
        driverStatus = driver.status

        // coreaudiod restarted (driver reinstalled, or macOS restarted it on
        // its own). Every handle we hold is stale: the audio unit is dead, and
        // the shared-memory mapping points at the *previous* driver's segment,
        // which was unlinked and will never be written to again. Nothing about
        // that is visible as an error — the app would just play silence for
        // ever while still believing it was engaged. Tear it all down and
        // build it again.
        if driver.driverWasReloaded, isEngaged {
            Self.log.info("driver was reloaded — rebuilding the audio path")
            disengage(restoreDefault: false)
        }

        if !driver.isReady, isEngaged {
            disengage(restoreDefault: true)
        } else if driver.isReady, enabled, !isEngaged {
            engage()
        }
    }

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
    /// CoreAudio device, which is then routed like any other selection.
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

    // MARK: Device visibility

    func setOutputHidden(_ device: AudioDevice, _ hidden: Bool) {
        if hidden { hiddenOutputUIDs.insert(device.uid) } else { hiddenOutputUIDs.remove(device.uid) }
        defaults.set(Array(hiddenOutputUIDs), forKey: Keys.hiddenOutputs)
    }

    func setInputHidden(_ device: AudioDevice, _ hidden: Bool) {
        if hidden { hiddenInputUIDs.insert(device.uid) } else { hiddenInputUIDs.remove(device.uid) }
        defaults.set(Array(hiddenInputUIDs), forKey: Keys.hiddenInputs)
    }

    // MARK: Output volume

    func setVolume(_ v: Float) {
        let clamped = min(max(v, 0), 1)
        if isEngaged {
            driver.setFadedVolume(clamped) // listener mirrors to target + persists
            if clamped > 0, muted { setMuted(false) }
        } else if let t = target {
            t.setVolume(clamped)
            volume = clamped
        }
    }

    func setMuted(_ m: Bool) {
        if isEngaged {
            driver.setFadedMuted(m)
        } else if let t = target {
            t.setMuted(m)
            muted = m
        }
    }

    /// Not engaged: the top slider just shows/drives the real device.
    private func readVolumeFromTargetDirectly() {
        guard !isEngaged, let t = target else { return }
        volume = t.volume ?? 1
        muted = t.isMuted ?? false
    }

    /// The Faded control (moved by keys / Sound slider / our UI) changed → mirror.
    private func fadedControlChanged() {
        guard isEngaged, !syncingVolume, let t = target else { return }
        syncingVolume = true
        defer { syncingVolume = false }
        let v = driver.fadedVolume
        let m = driver.fadedMuted
        volume = v
        muted = m
        volumeByDevice[t.uid] = v
        mutedByDevice[t.uid] = m
        defaults.set(volumeByDevice, forKey: Keys.volumeByDevice)
        defaults.set(mutedByDevice, forKey: Keys.mutedByDevice)
        if t.hasHardwareVolume { t.setVolume(v) }
        if t.hasHardwareMute { t.setMuted(m) }
    }

    /// The *target's* hardware volume changed elsewhere (AirPods stem, another
    /// app) → reflect it on the Faded control so the two never disagree.
    private func targetControlChanged() {
        guard !syncingVolume, let t = target else { return }
        guard isEngaged else {
            // Standing aside: just reflect the device's own level in the menu.
            if let v = t.volume { volume = v }
            if let m = t.isMuted { muted = m }
            return
        }
        guard t.hasHardwareVolume else { return }
        syncingVolume = true
        defer { syncingVolume = false }
        if let v = t.volume { driver.setFadedVolume(v); volume = v; volumeByDevice[t.uid] = v }
        if let m = t.isMuted { driver.setFadedMuted(m); muted = m; mutedByDevice[t.uid] = m }
    }

    /// New target: decide who owns the gain stage and seed the Faded control.
    private func applyVolumeForTarget() {
        guard let t = target else { return }
        driver.setBypassMaster(t.hasHardwareVolume)
        syncingVolume = true
        let v: Float = t.hasHardwareVolume ? (t.volume ?? 1) : (volumeByDevice[t.uid] ?? 1)
        let m: Bool = t.hasHardwareMute ? (t.isMuted ?? false) : (mutedByDevice[t.uid] ?? false)
        driver.setFadedVolume(v)
        driver.setFadedMuted(m)
        volume = v
        muted = m
        syncingVolume = false
    }

    private func installFadedControlListeners() {
        guard let faded = driver.outputDevice else { return }
        fadedControlListeners = faded.volumeListenerAddresses.map { addr in
            AudioObject.listen(faded.id, addr) { [weak self] in
                Task { @MainActor in self?.fadedControlChanged() }
            }
        }
        // coreaudiod re-rates the Faded device to suit its clients — open a
        // 44.1 kHz track and the device follows it. The driver then produces
        // frames at that rate, so the play-through has to be reopened to match
        // or it drains the ring at the wrong speed and glitches continuously.
        fadedRateListener = AudioObject.listen(faded.id, .init(kAudioDevicePropertyNominalSampleRate)) { [weak self] in
            Task { @MainActor in self?.fadedRateChanged() }
        }
    }

    private func fadedRateChanged() {
        guard isEngaged, let t = target, let faded = driver.outputDevice else { return }
        let rate = faded.nominalSampleRate
        guard rate > 0, abs(rate - engine.sampleRate) >= 1 else { return }
        Self.log.info("Faded device re-rated to \(rate) — reopening play-through")
        do {
            try engine.start(output: t.id, sampleRate: rate)
        } catch {
            lastError = "\(error)"
            Self.log.error("reopen after rate change failed: \(String(describing: error))")
        }
    }

    private func installTargetListeners() {
        targetControlListeners.removeAll()
        targetRateListener = nil
        guard let t = target else { return }
        targetControlListeners = t.volumeListenerAddresses.map { addr in
            AudioObject.listen(t.id, addr) { [weak self] in
                Task { @MainActor in self?.targetControlChanged() }
            }
        }
        targetRateListener = AudioObject.listen(t.id, .init(kAudioDevicePropertyNominalSampleRate)) { [weak self] in
            Task { @MainActor in self?.targetRateChanged() }
        }
    }

    private func targetRateChanged() {
        guard isEngaged, let t = target else { return }
        let rate = engineRate(for: t)
        guard abs(rate - engine.sampleRate) >= 1 else { return }
        Self.log.info("target rate → \(rate), restarting engine")
        do { try startEngine(for: t) } catch { lastError = "\(error)" }
    }

    // MARK: Per-app volume

    func refreshApps() {
        if previewMode { return }
        var byApp: [String: AppEntry] = [:]
        var playingOrder: [String] = []

        for c in driver.clients() {
            if c.pid == ProcessInfo.processInfo.processIdentifier { continue } // ourselves
            let app = ProcessResolver.resolve(pid: c.pid, bundleID: c.bundleID)
            appNames[app.id] = app.name
            if var e = byApp[app.id] {
                e.keys.insert(c.key)
                e.peak = max(e.peak, c.peak)
                byApp[app.id] = e
            } else {
                byApp[app.id] = AppEntry(id: app.id, name: app.name, pid: app.pid,
                                         gain: appGains[app.id] ?? 1,
                                         muted: appMutedLevels[app.id] != nil,
                                         peak: c.peak, keys: [c.key], isBare: app.isBare,
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

        // Starred apps stay in the list even when they're silent or not running,
        // so their level can be set before they make a sound.
        for id in starredApps where byApp[id] == nil {
            let name = appNames[id] ?? ProcessResolver.staticInfo(bundleID: id)?.name ?? id
            byApp[id] = AppEntry(id: id, name: name, pid: 0,
                                 gain: appGains[id] ?? 1,
                                 muted: appMutedLevels[id] != nil,
                                 peak: 0, keys: Set(appKeys[id] ?? []), isBare: id.hasPrefix("pid:"),
                                 starred: true, isPlaying: false)
        }

        // Remember each app's driver keys so a stored gain can be pushed before
        // the app next opens the device.
        for (id, e) in byApp where !e.keys.isEmpty { appKeys[id] = Array(e.keys) }
        defaults.set(appNames, forKey: Keys.appNames)
        defaults.set(appKeys, forKey: Keys.appKeys)

        let starred = byApp.values.filter(\.starred).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let rest = playingOrder.compactMap { byApp[$0] }.filter { !$0.starred }
        apps = starred + rest

        pushAllAppGains()
    }

    /// Ensure the driver's key→gain map reflects the stored per-app gains.
    private func pushAllAppGains() {
        guard driver.isReady else { return }
        var map: [String: Float] = [:]

        func gain(for id: String) -> Float {
            appMutedLevels[id] != nil ? 0 : (appGains[id] ?? 1)
        }
        // Live entries: use the keys the driver actually reported.
        for e in apps {
            let g = gain(for: e.id)
            guard g != 1 else { continue }
            for k in e.keys { map[k] = g }
        }
        // Anything with a stored non-unity gain: push under its remembered keys
        // (and its own id, which doubles as the key for non-helper apps) so the
        // setting applies the moment it starts playing.
        for id in Set(appGains.keys).union(appMutedLevels.keys) {
            let g = gain(for: id)
            guard g != 1 else { continue }
            if !id.hasPrefix("pid:") { map[id] = g }
            for k in appKeys[id] ?? [] { map[k] = g }
        }
        if map != driver.appGains() { driver.setAppGains(map) }
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
                                                   peak: 0, keys: Set(appKeys[id] ?? []),
                                                   isBare: id.hasPrefix("pid:"),
                                                   starred: starredApps.contains(id), isPlaying: false)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func forgetApp(_ appID: String) {
        appGains[appID] = nil
        appMutedLevels[appID] = nil
        appKeys[appID] = nil
        appNames[appID] = nil
        starredApps.remove(appID)
        persistApps()
        defaults.set(Array(starredApps), forKey: Keys.starredApps)
        defaults.set(appNames, forKey: Keys.appNames)
        defaults.set(appKeys, forKey: Keys.appKeys)
        refreshApps()
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
        outputLevel = engine.outputPeak

        let clients = driver.clients()
        var peakByKey: [String: Float] = [:]
        for c in clients { peakByKey[c.key] = max(peakByKey[c.key] ?? 0, c.peak) }
        for i in apps.indices {
            apps[i].peak = apps[i].keys.reduce(0) { max($0, peakByKey[$1] ?? 0) }
        }

        // Did anything start or stop being audible? Only then rebuild the list.
        let now = Date()
        let before = Set(apps.map(\.id))
        var changed = false
        for c in clients where c.peak > audibleThreshold {
            let id = ProcessResolver.resolve(pid: c.pid, bundleID: c.bundleID).id
            if lastAudible[id] == nil || !before.contains(id) { changed = true }
            lastAudible[id] = now
        }
        if !changed {
            changed = apps.contains { !$0.starred && (lastAudible[$0.id].map { now.timeIntervalSince($0) >= audibleHold } ?? true) }
        }
        if changed { refreshApps() }
    }

#if DEBUG
    /// Fills in the parts of the menu that need a working driver so the layout
    /// can be rendered and reviewed without installing anything.
    /// `demo: true` also swaps in invented devices, so the README screenshot
    /// doesn't leak the device names of whatever machine generated it.
    /// Used by `--render-menu`; never reachable in a Release build.
    func applyPreviewState(demo: Bool = false) {
        previewMode = true
        driverStatus = .ready
        isEngaged = true
        volume = 0.55
        outputLevel = (0.42, 0.51)
        apps = [
            AppEntry(id: "com.spotify.client", name: "Spotify", pid: 0, gain: 0.65, muted: false,
                     peak: 0.5, keys: [], isBare: false, starred: true, isPlaying: true),
            AppEntry(id: "com.hnc.Discord", name: "Discord", pid: 0, gain: 1, muted: false,
                     peak: 0.12, keys: [], isBare: false, starred: true, isPlaying: true),
            AppEntry(id: "com.apple.Safari", name: "Safari", pid: 0, gain: 0.4, muted: true,
                     peak: 0, keys: [], isBare: false, starred: false, isPlaying: true),
        ]
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
        var s = "driver: \(driverStatus)  enabled: \(enabled)\n"
        let ringRate: String = engine.reader.sampleRate.map { "\($0)" } ?? "-"
        s += "shared ring open: \(engine.reader.isOpen)  ring rate: \(ringRate)\n"
        s += "engaged: \(isEngaged)  output: \(target?.name ?? "-")  input: \(selectedInput?.name ?? "-")\n"
        s += "output has hw volume: \(target?.hasHardwareVolume ?? false) (false ⇒ Faded applies it in software)\n"
        let e = engine.stats
        s += "engine: rate=\(engine.sampleRate) under=\(e.underruns) resync=\(e.resyncs) over=\(e.overruns) producing=\(e.producing)\n"
        s += String(format: "drift loop: fill=%.0f frames (target %.0f) correction=%+.0f ppm\n",
                    e.fill, engine.reader.target, e.driftPPM)
        for (k, v) in driver.stats().sorted(by: { $0.key < $1.key }) { s += "\(k)=\(v) " }
        if let err = lastError { s += "\nlast error: \(err)" }
        return s
    }
}
