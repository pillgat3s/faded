// AudioRouter.swift — the brain. Owns the driver link, the play-through
// engine, the "which real device are we playing to" decision, volume
// mirroring, per-app gains and persistence.
//
// Invariants while engaged:
//   * macOS default output == "Faded" (so every app plays into the driver).
//   * `target` is the real device Faded.app plays to.
//   * The Faded device's volume/mute controls always show the *target's*
//     level. If the target has hardware volume we mirror the value onto it and
//     tell the driver to bypass its own gain (no double attenuation); if it
//     doesn't (Astro A50 & friends) the driver applies the gain in software.
//   * When macOS or the user changes the default output to something else
//     (Control Center, AirPods auto-switch, AirPlay pick), we adopt that
//     device as the new target and put Faded back as default. That is what
//     keeps AirPlay/AirPods "native".

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
    private(set) var outputs: [AudioDevice] = []
    private(set) var target: AudioDevice?
    private(set) var volume: Float = 1
    private(set) var muted = false
    private(set) var apps: [AppEntry] = []
    private(set) var isEngaged = false
    private(set) var lastError: String?

    /// User switch: route audio through Faded (true) or leave macOS alone.
    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Keys.enabled)
            enabled ? engage() : disengage(restoreDefault: true)
        }
    }

    /// Experimental: hide the "Faded" device from Sound settings / Control
    /// Center. Only useful if macOS still lets us make it the default output;
    /// `engage()` verifies that and flips this back off if it doesn't.
    var hideFadedDevice: Bool {
        didSet {
            defaults.set(hideFadedDevice, forKey: Keys.hideFaded)
            applyHiddenPreference()
        }
    }

    struct AppEntry: Identifiable, Hashable {
        let id: String       // ResolvedApp.id
        let name: String
        let pid: pid_t
        var gain: Float      // 0…2, what the driver applies
        var muted: Bool
        var peak: Float
        var keys: Set<String>
        var isBare: Bool
        var icon: NSImage { ProcessResolver.icon(for: ResolvedApp(id: id, name: name, pid: pid, isBare: isBare)) }
        static func == (l: AppEntry, r: AppEntry) -> Bool { l.id == r.id && l.gain == r.gain && l.muted == r.muted && l.peak == r.peak }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    // MARK: Internals

    let driver = DriverLink()
    private let engine = PlayThrough()
    private let defaults = UserDefaults.standard

    private var defaultOutputListener: ListenerToken?
    private var deviceListListener: ListenerToken?
    private var fadedControlListeners: [ListenerToken] = []
    private var targetControlListeners: [ListenerToken] = []
    private var targetRateListener: ListenerToken?
    private var meterTimer: Timer?

    private var settingDefault = false   // re-entrancy guard for default-output writes
    private var syncingVolume = false    // re-entrancy guard for volume mirroring

    private var volumeByDevice: [String: Float]
    private var mutedByDevice: [String: Bool]
    private var appGains: [String: Float]        // ResolvedApp.id → gain
    private var appMutedLevels: [String: Float]  // ResolvedApp.id → level before mute
    private var appNames: [String: String] = [:] // ResolvedApp.id → last seen name (for muted-but-idle rows)
    private var previousTargets: [String] = []   // UIDs, most recent last

    private enum Keys {
        static let enabled = "enabled"
        static let volumeByDevice = "volumeByDevice"
        static let mutedByDevice = "mutedByDevice"
        static let appGains = "appGains"
        static let appMutedLevels = "appMutedLevels"
        static let lastTarget = "lastTargetUID"
        static let previousTargets = "previousTargets"
        static let hideFaded = "hideFadedDevice"
    }

    init() {
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        hideFadedDevice = defaults.bool(forKey: Keys.hideFaded)
        volumeByDevice = defaults.dictionary(forKey: Keys.volumeByDevice) as? [String: Float] ?? [:]
        mutedByDevice = defaults.dictionary(forKey: Keys.mutedByDevice) as? [String: Bool] ?? [:]
        appGains = defaults.dictionary(forKey: Keys.appGains) as? [String: Float] ?? [:]
        appMutedLevels = defaults.dictionary(forKey: Keys.appMutedLevels) as? [String: Float] ?? [:]
        previousTargets = defaults.stringArray(forKey: Keys.previousTargets) ?? []

        driver.onClientsChanged = { [weak self] in self?.refreshApps() }
        driver.onAvailabilityChanged = { [weak self] in self?.driverAvailabilityChanged() }
        driverStatus = driver.status

        deviceListListener = AudioObject.listen(AudioSystem.object, .init(kAudioHardwarePropertyDevices)) { [weak self] in
            Task { @MainActor in self?.devicesChanged() }
        }
        defaultOutputListener = AudioObject.listen(AudioSystem.object, .init(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            Task { @MainActor in self?.defaultOutputChanged() }
        }

        refreshOutputs()
        if enabled { engage() }
    }

    // MARK: Engage / disengage

    func engage() {
        guard !isEngaged, driver.isReady, let faded = driver.outputDevice, let tapID = driver.tapDeviceID else {
            driverStatus = driver.status
            return
        }
        lastError = nil

        // Decide the initial target.
        let systemDefault = AudioSystem.defaultOutputDevice.flatMap(AudioDevice.init(id:))
        let initial: AudioDevice? = if let d = systemDefault, !d.isFadedDevice, d.hasOutput {
            d
        } else if let uid = defaults.string(forKey: Keys.lastTarget), let d = outputs.first(where: { $0.uid == uid }) {
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
            try startEngine(for: initialTarget, tapID: tapID)
        } catch {
            lastError = "\(error)"
            Self.log.error("engine start failed: \(String(describing: error))")
            return
        }
        applyHiddenPreference()
        setSystemDefault(to: faded.id)
        if AudioSystem.defaultOutputDevice != faded.id, hideFadedDevice {
            // macOS refused a hidden default — unhide and retry once.
            Self.log.warning("hidden Faded device rejected as default output; unhiding")
            hideFadedDevice = false
            setSystemDefault(to: faded.id)
        }
        installFadedControlListeners()
        installTargetListeners()
        pushAllAppGains()
        applyVolumeForTarget()
        isEngaged = true
        refreshApps()
        Self.log.info("engaged → \(initialTarget.name)")
    }

    func disengage(restoreDefault: Bool) {
        guard isEngaged else { return }
        engine.stop()
        fadedControlListeners.removeAll()
        targetControlListeners.removeAll()
        targetRateListener = nil
        if restoreDefault, let t = target, t.isAlive {
            setSystemDefault(to: t.id)
        }
        isEngaged = false
        Self.log.info("disengaged")
    }

    /// Call from applicationWillTerminate.
    func shutdown() {
        disengage(restoreDefault: true)
    }

    private func applyHiddenPreference() {
        guard driver.isReady else { return }
        if driver.isOutputHidden != hideFadedDevice { driver.setOutputHidden(hideFadedDevice) }
    }

    // MARK: Target selection

    func select(_ device: AudioDevice) {
        guard device.hasOutput, !device.isFadedDevice else { return }
        if !isEngaged {
            setSystemDefault(to: device.id)
            target = device
            return
        }
        retarget(device)
    }

    private func retarget(_ device: AudioDevice) {
        guard let tapID = driver.tapDeviceID else { return }
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
                try startEngine(for: device, tapID: tapID)
            }
        } catch {
            lastError = "\(error)"
            Self.log.error("retarget failed: \(String(describing: error))")
        }
        installTargetListeners()
        applyVolumeForTarget()
        Self.log.info("target → \(device.name)")
    }

    private func startEngine(for device: AudioDevice, tapID: AudioDeviceID) throws {
        let wanted = engineRate(for: device)
        let actual = driver.setSampleRate(wanted)
        try engine.start(tap: tapID, output: device.id, sampleRate: actual)
    }

    /// Run the virtual devices at the target's rate when we can, so nothing
    /// resamples; otherwise 48 kHz and let AUHAL convert on the way out.
    private func engineRate(for device: AudioDevice) -> Double {
        let r = device.nominalSampleRate
        return FadedProtocol.supportedSampleRates.contains(r) ? r : FadedProtocol.defaultSampleRate
    }

    private func fallbackDevice() -> AudioDevice? {
        for uid in previousTargets.reversed() {
            if let d = outputs.first(where: { $0.uid == uid }) { return d }
        }
        return outputs.first(where: { $0.transport == .builtIn }) ?? outputs.first
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

    private func defaultOutputChanged() {
        guard isEngaged, !settingDefault, let faded = driver.outputDevice else { return }
        guard let current = AudioSystem.defaultOutputDevice, current != faded.id else { return }
        // Someone (user via Control Center, AirPods auto-switch, AirPlay pick,
        // another app) pointed the system at a real device: adopt it, then take
        // the default back.
        if let dev = AudioDevice(id: current), dev.hasOutput, !dev.isFadedDevice {
            Self.log.info("system default moved to \(dev.name) — following")
            retarget(dev)
        }
        setSystemDefault(to: faded.id)
    }

    private func devicesChanged() {
        refreshOutputs()
        driver.refresh()
        driverStatus = driver.status
        guard isEngaged else { return }
        if let t = target, !outputs.contains(where: { $0.uid == t.uid }) || !t.isAlive {
            Self.log.info("target \(t.name) vanished")
            if let fb = fallbackDevice() { retarget(fb) } else { disengage(restoreDefault: false) }
        }
    }

    private func driverAvailabilityChanged() {
        driverStatus = driver.status
        if !driver.isReady, isEngaged {
            disengage(restoreDefault: true)
        } else if driver.isReady, enabled, !isEngaged {
            engage()
        }
    }

    func refreshOutputs() {
        outputs = AudioDevice.selectableOutputs().sorted { a, b in
            if a.transport == .builtIn, b.transport != .builtIn { return true }
            if b.transport == .builtIn, a.transport != .builtIn { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Volume

    /// From the UI slider.
    func setVolume(_ v: Float) {
        let clamped = min(max(v, 0), 1)
        if isEngaged {
            driver.setFadedVolume(clamped) // listener mirrors to target + persists
            if clamped > 0, muted { setMuted(false) }
        } else if let t = target ?? AudioSystem.defaultOutputDevice.flatMap(AudioDevice.init(id:)) {
            t.setVolume(clamped)
            volume = clamped
        }
    }

    func setMuted(_ m: Bool) {
        if isEngaged {
            driver.setFadedMuted(m)
        } else if let t = target ?? AudioSystem.defaultOutputDevice.flatMap(AudioDevice.init(id:)) {
            t.setMuted(m)
            muted = m
        }
    }

    /// The Faded control (moved by keys/Sound slider/our UI) changed → mirror.
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

    /// The *target's* hardware volume changed from elsewhere (AirPods stem,
    /// another app) → reflect on the Faded control.
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
        guard isEngaged, let t = target, let tapID = driver.tapDeviceID else { return }
        let rate = engineRate(for: t)
        guard abs(rate - engine.sampleRate) >= 1 else { return }
        Self.log.info("target rate → \(rate), restarting engine")
        do { try startEngine(for: t, tapID: tapID) } catch { lastError = "\(error)" }
    }

    // MARK: Per-app volume

    func refreshApps() {
        let clients = driver.clients()
        var byApp: [String: AppEntry] = [:]
        var order: [String] = []
        for c in clients {
            if c.pid == ProcessInfo.processInfo.processIdentifier { continue } // ourselves
            let app = ProcessResolver.resolve(pid: c.pid, bundleID: c.bundleID)
            appNames[app.id] = app.name
            let stored = appGains[app.id] ?? 1
            if var e = byApp[app.id] {
                e.keys.insert(c.key)
                e.peak = max(e.peak, c.peak)
                byApp[app.id] = e
            } else {
                byApp[app.id] = AppEntry(id: app.id, name: app.name, pid: app.pid,
                                         gain: stored, muted: appMutedLevels[app.id] != nil,
                                         peak: c.peak, keys: [c.key], isBare: app.isBare)
                order.append(app.id)
            }
        }
        apps = order.compactMap { byApp[$0] }
        pushAllAppGains()
    }

    /// Ensure the driver's key→gain map reflects the stored per-app gains.
    private func pushAllAppGains() {
        guard driver.isReady else { return }
        var map: [String: Float] = [:]
        for e in apps {
            let g = appMutedLevels[e.id] != nil ? 0 : (appGains[e.id] ?? 1)
            for k in e.keys where g != 1 { map[k] = g }
        }
        // Keep entries for apps that aren't currently connected but have a
        // stored key-shaped id (bundle ids double as keys for non-helper apps).
        for (id, g) in appGains where map[id] == nil && g != 1 && !id.hasPrefix("pid:") { map[id] = appMutedLevels[id] != nil ? 0 : g }
        for (id, _) in appMutedLevels where map[id] == nil && !id.hasPrefix("pid:") { map[id] = 0 }
        if map != driver.appGains() { driver.setAppGains(map) }
    }

    func setAppGain(_ appID: String, _ gain: Float) {
        let g = min(max(gain, 0), 2)
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
        if m {
            appMutedLevels[appID] = appGains[appID] ?? 1
        } else {
            appMutedLevels[appID] = nil
        }
        persistApps()
        if let i = apps.firstIndex(where: { $0.id == appID }) { apps[i].muted = m }
        pushAllAppGains()
    }

    func resetAppGain(_ appID: String) {
        appGains[appID] = nil
        appMutedLevels[appID] = nil
        persistApps()
        if let i = apps.firstIndex(where: { $0.id == appID }) { apps[i].gain = 1; apps[i].muted = false }
        pushAllAppGains()
    }

    private func persistApps() {
        defaults.set(appGains, forKey: Keys.appGains)
        defaults.set(appMutedLevels, forKey: Keys.appMutedLevels)
    }

    // MARK: Meters (only while the menu is open)

    func startMetering() {
        stopMetering()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePeaks() }
        }
    }

    func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func updatePeaks() {
        guard isEngaged else { return }
        let clients = driver.clients()
        var peakByKey: [String: Float] = [:]
        for c in clients { peakByKey[c.key] = max(peakByKey[c.key] ?? 0, c.peak) }
        for i in apps.indices {
            apps[i].peak = apps[i].keys.reduce(0) { max($0, peakByKey[$1] ?? 0) }
        }
    }

    // MARK: Diagnostics

    var diagnostics: String {
        var s = "driver: \(driverStatus)\n"
        s += "engaged: \(isEngaged) target: \(target?.name ?? "-")\n"
        let e = engine.stats
        s += "engine: rate=\(engine.sampleRate) ring=\(e.available) under=\(e.underruns) over=\(e.overruns) trims=\(e.trims)\n"
        for (k, v) in driver.stats().sorted(by: { $0.key < $1.key }) { s += "\(k)=\(v) " }
        if let err = lastError { s += "\nlast error: \(err)" }
        return s
    }
}
