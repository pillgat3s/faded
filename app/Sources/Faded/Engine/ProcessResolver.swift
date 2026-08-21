// ProcessResolver.swift — turns a driver client (pid + bundle id) into the app
// the user actually recognises.
//
// Browsers and Electron apps play audio from helper processes
// (com.google.Chrome.helper, com.apple.WebKit.GPU, Discord Helper…). We
// resolve the *responsible* application: first via the same private call
// Activity Monitor uses (responsibility_get_pid_responsible_for_pid, looked up
// dynamically so a missing symbol can't break the build), then by walking the
// parent-pid chain until we hit a regular/accessory app.

import AppKit
import Darwin
import Foundation

struct ResolvedApp: Hashable, Sendable {
    /// Stable identity used for persistence: the app's bundle id, or "pid:N".
    let id: String
    let name: String
    let pid: pid_t
    /// True when we could not find a proper .app for it (raw process).
    let isBare: Bool
}

enum ProcessResolver {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    private static let helperSuffixes = [".helper", ".Helper", ".helper.renderer", ".helper.gpu", ".helper.plugin"]

    static func resolve(pid: pid_t, bundleID: String) -> ResolvedApp {
        // 1. Responsible process (handles XPC services like com.apple.WebKit.GPU → Safari).
        if let fn = responsibleFn {
            let rp = fn(pid)
            if rp > 0, rp != pid, let app = runningApp(rp), isRealApp(app) {
                return make(app, pid: rp)
            }
        }
        // 2. Walk parents (handles classic helper subprocesses).
        var p = pid
        for _ in 0 ..< 8 {
            if let app = runningApp(p), isRealApp(app) { return make(app, pid: p) }
            let parent = parentPID(of: p)
            if parent <= 1 { break }
            p = parent
        }
        // 3. Whatever we know about the pid itself.
        if let app = runningApp(pid) {
            let name = app.localizedName ?? bundleID
            return ResolvedApp(id: app.bundleIdentifier ?? "pid:\(pid)", name: name, pid: pid, isBare: app.bundleIdentifier == nil)
        }
        let name = processName(pid) ?? (bundleID.isEmpty ? "Process \(pid)" : bundleID)
        return ResolvedApp(id: bundleID.isEmpty ? "pid:\(pid)" : bundleID, name: name, pid: pid, isBare: true)
    }

    /// Name + icon for an app that isn't currently running (starred favourites).
    static func staticInfo(bundleID: String) -> (name: String, icon: NSImage)? {
        guard !bundleID.hasPrefix("pid:"),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let name = (Bundle(url: url)?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }

    static func icon(for app: ResolvedApp) -> NSImage {
        if let running = NSRunningApplication(processIdentifier: app.pid), let icon = running.icon { return icon }
        if !app.id.hasPrefix("pid:"), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
    }

    // MARK: Helpers

    private static func make(_ app: NSRunningApplication, pid: pid_t) -> ResolvedApp {
        ResolvedApp(id: app.bundleIdentifier ?? "pid:\(pid)",
                    name: app.localizedName ?? app.bundleIdentifier ?? "App \(pid)",
                    pid: pid, isBare: false)
    }

    private static func runningApp(_ pid: pid_t) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }

    private static func isRealApp(_ app: NSRunningApplication) -> Bool {
        guard let bid = app.bundleIdentifier else { return false }
        if helperSuffixes.contains(where: { bid.hasSuffix($0) }) { return false }
        return app.activationPolicy != .prohibited || app.bundleURL?.pathExtension == "app"
    }

    static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
}
