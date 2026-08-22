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
import CoreAudio
import Foundation
import Observation
import os

@MainActor
@Observable
final class AudioRouter {
    private static let log = Logger(subsystem: FadedProtocol.appBundleID, category: "Router")

    // MARK: Observable state

    private(set) var driverStatus: DriverLink.Status = .notInstalled
    private(set) var allOutputs: [AudioDevice] = []
    private(set) var allInputs: [AudioDevice] = []
    private(set) var target: AudioDevice?
    private(set) var selectedInput: AudioDevice?
    private(set) var volume: Float = 1
    private(set) var muted = false
    private(set) var inputVolume: Float = 1
    private(set) var inputMuted = false
    private(set) var apps: [AppEntry] = []
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

        refreshDevices()
        if enabled { engage() }
        refreshApps()
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
        refreshApps()
        Self.log.info("engaged → \(initialTarget.name)")
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
        // Nothing is being routed any more; stop impersonating a real device.
        driver.setDisplayName(FadedProtocol.outputDeviceName)
        Self.log.info("disengaged")
    }

    /// Call from applicationWillTerminate.
    func shutdown() {
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

    // MARK: Output selection

    func select(_ device: AudioDevice) {
        guard device.hasOutput, !device.isFadedDevice else { return }
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
        Self.log.info("target → \(device.name)")
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
        guard !settingDefault, let faded = driver.outputDevice else { return }
        guard let current = AudioSystem.defaultOutputDevice, current != faded.id else { return }
        adopt(current, attempt: 0)
    }

    /// Adopt `deviceID` if we can play to it, retrying briefly while it settles.
    private func adopt(_ deviceID: AudioDeviceID, attempt: Int) {
        guard let faded = driver.outputDevice else { return }
        // Something else moved the default again while we were waiting.
        guard AudioSystem.defaultOutputDevice == deviceID else { return }

        let device = AudioDevice(id: deviceID)
        let adoptable = device.map { $0.hasOutput && !$0.isFadedDevice && $0.isAlive } ?? false

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

        if attempt < 6 {
            adoptRetry?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.adopt(deviceID, attempt: attempt + 1) }
            }
            adoptRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }

        // Genuinely cannot follow it. Let macOS route natively rather than
        // fighting for the default and yanking playback away from the user.
        guard isEngaged else { return }
        Self.log.info("default moved somewhere Faded can't follow — stepping aside")
        steppedAside = true
        disengage(restoreDefault: false)
        target = device
        readVolumeFromTargetDirectly()
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
        guard isEngaged, !syncingVolume, let t = target, t.hasHardwareVolume else { return }
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
        let stats = driver.stats()
        outputLevel = (Float(stats["peakL"] as? Double ?? 0), Float(stats["peakR"] as? Double ?? 0))

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
        s += String(format: "drift loop: fill=%.0f frames (target %d) correction=%+.0f ppm\n",
                    e.fill, Int(kFadedRingPrimeFrames), e.driftPPM)
        for (k, v) in driver.stats().sorted(by: { $0.key < $1.key }) { s += "\(k)=\(v) " }
        if let err = lastError { s += "\nlast error: \(err)" }
        return s
    }
}
