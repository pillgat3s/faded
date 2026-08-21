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

        Settings {
            SettingsView(router: delegate.router)
        }
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
#if DEBUG
        // `Faded --render-menu <out.png> [--expanded]` renders the popover to a
        // file and quits, so the layout can be reviewed without installing the
        // driver or touching the audio system. Debug builds only.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-menu"), i + 1 < args.count {
            renderMenu(to: args[i + 1], expanded: args.contains("--expanded"))
            NSApp.terminate(nil)
        }
        if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
            renderSettings(to: args[i + 1])
            NSApp.terminate(nil)
        }
#endif
    }

#if DEBUG
    @MainActor
    private func renderSettings(to path: String) {
        router.applyPreviewState()
        write(ImageRenderer(content: SettingsView.debugPanes(router: router)
            .environment(\.colorScheme, .dark)), to: path)
    }

    @MainActor
    private func renderMenu(to path: String, expanded: Bool) {
        router.applyPreviewState()
        let view = MenuView(router: router, previewExpandApps: expanded)
            .padding(6)
            .background(.background)
            .environment(\.colorScheme, .dark)
        write(ImageRenderer(content: view), to: path)
    }

    @MainActor
    private func write(_ renderer: ImageRenderer<some View>, to path: String) {
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
#endif

    func applicationWillTerminate(_ notification: Notification) {
        // Give macOS its default output back so audio doesn't dead-end in the
        // driver when we're not running.
        router.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
