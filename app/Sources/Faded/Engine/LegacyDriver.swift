// LegacyDriver.swift — removes the audio driver an older Faded installed.
//
// Faded used to route audio through a HAL plug-in of its own. It no longer
// needs one, but a machine that ran that version still has it in
// /Library/Audio/Plug-Ins/HAL, publishing a "Faded" device that plays to
// nothing. Removing it needs root, so the one command runs through
// AppleScript's "with administrator privileges" — macOS shows its own
// password dialog and the app never sees the password.

import AppKit
import Foundation

@MainActor
enum LegacyDriver {
    static let installedPath = "/Library/Audio/Plug-Ins/HAL/FadedDriver.driver"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installedPath) }

    enum RemoveError: Error, LocalizedError {
        case cancelled
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: "Cancelled."
            case let .failed(m): m
            }
        }
    }

    /// Deletes the driver and restarts coreaudiod (about a second of silence).
    static func remove() throws {
        let shell = "rm -rf '\(installedPath)' && killall coreaudiod"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw RemoveError.failed("Could not build AppleScript.") }
        script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { throw RemoveError.cancelled }
            throw RemoveError.failed(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)")
        }
    }
}
