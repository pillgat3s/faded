// DriverInstaller.swift — installs / removes FaderDriver.driver from inside
// the app.
//
// The .driver bundle is embedded in Fader.app/Contents/Resources. Installing
// means copying it to /Library/Audio/Plug-Ins/HAL and restarting coreaudiod;
// both need root, so we run one shell command through AppleScript's
// "with administrator privileges" — macOS shows its native password dialog,
// the app never sees the password.

import AppKit
import Foundation
import os

@MainActor
enum DriverInstaller {
    private static let log = Logger(subsystem: FaderProtocol.appBundleID, category: "Installer")

    static let installDir = "/Library/Audio/Plug-Ins/HAL"
    static let bundleName = "FaderDriver.driver"
    static var installedPath: String { "\(installDir)/\(bundleName)" }

    static var embeddedDriverURL: URL? {
        Bundle.main.url(forResource: "FaderDriver", withExtension: "driver")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installedPath) }

    static func version(at url: URL) -> String? {
        Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static var embeddedVersion: String? { embeddedDriverURL.flatMap(version(at:)) }
    static var installedVersion: String? { version(at: URL(fileURLWithPath: installedPath)) }

    /// True when the embedded driver differs from what's on disk.
    static var updateAvailable: Bool {
        guard isInstalled, let a = embeddedVersion, let b = installedVersion else { return false }
        return a != b
    }

    enum InstallError: Error, LocalizedError {
        case noEmbeddedDriver
        case cancelled
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noEmbeddedDriver: "This build of Fader has no driver embedded (build with `make app`)."
            case .cancelled: "Cancelled."
            case let .failed(m): m
            }
        }
    }

    static func install() throws {
        guard let src = embeddedDriverURL else { throw InstallError.noEmbeddedDriver }
        let script = """
        rm -rf '\(installedPath)' && \
        mkdir -p '\(installDir)' && \
        cp -R '\(src.path)' '\(installDir)/' && \
        chown -R root:wheel '\(installedPath)' && \
        chmod -R go-w '\(installedPath)' && \
        killall coreaudiod
        """
        try runPrivileged(script)
        log.info("driver installed")
    }

    static func uninstall() throws {
        let script = "rm -rf '\(installedPath)' && killall coreaudiod"
        try runPrivileged(script)
        log.info("driver removed")
    }

    /// Restart coreaudiod only (e.g. after a hang). Also privileged.
    static func restartCoreAudio() throws {
        try runPrivileged("killall coreaudiod")
    }

    private static func runPrivileged(_ shell: String) throws {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw InstallError.failed("Could not build AppleScript.") }
        script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { throw InstallError.cancelled }
            let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)"
            throw InstallError.failed(message)
        }
    }
}
