// FadedApp.swift — menu bar–only app entry point.

import AppKit
import SwiftUI

@main
struct FadedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(router: delegate.router)
        } label: {
            MenuBarLabel(router: delegate.router)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar glyph: mirrors the system sound icon (waves scale with volume).
private struct MenuBarLabel: View {
    let router: AudioRouter

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
    }

    private var symbol: String {
        if router.driverStatus != .ready { return "speaker.badge.exclamationmark" }
        if router.muted || router.volume <= 0.001 { return "speaker.slash" }
        if router.volume < 0.34 { return "speaker.wave.1" }
        if router.volume < 0.67 { return "speaker.wave.2" }
        return "speaker.wave.3"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let router = AudioRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Give macOS its default output back so audio doesn't dead-end in the
        // driver when we're not running.
        router.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
