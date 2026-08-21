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

    private var rightClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItemContextMenu()
#if DEBUG
        // `Faded --render-menu <out.png> [--expanded]` renders the popover to a
        // file and quits, so the layout can be reviewed without installing the
        // driver or touching the audio system. Debug builds only.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-menu"), i + 1 < args.count {
            renderMenu(to: args[i + 1], expanded: args.contains("--expanded"), demo: args.contains("--demo"))
            NSApp.terminate(nil)
        }
        // `Faded --diagnose` prints what the engine is doing and exits. Log
        // messages from a menu-bar app are awkward to capture; this is not.
        if args.contains("--diagnose") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                print(router.diagnostics)
                router.shutdown()
                NSApp.terminate(nil)
            }
            return
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
    private func renderMenu(to path: String, expanded: Bool, demo: Bool = false) {
        router.applyPreviewState(demo: demo)
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

    /// `MenuBarExtra` has no API for a right-click menu, so the right mouse
    /// button is intercepted before it reaches the status item and used to pop
    /// up a small AppKit menu instead. Left-click still opens the popover, and
    /// the popover carries the same commands, so this is a convenience rather
    /// than the only route to them.
    private func installStatusItemContextMenu() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self,
                  let window = event.window,
                  NSStringFromClass(type(of: window)).contains("StatusBar")
            else { return event }
            self.showStatusMenu(with: event, in: window)
            return nil // swallow it, or the popover toggles underneath the menu
        }
    }

    private func showStatusMenu(with event: NSEvent, in window: NSWindow) {
        let menu = NSMenu()

        let settings = menu.addItem(withTitle: "Faded Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self

        let route = menu.addItem(withTitle: "Route Audio Through Faded", action: #selector(toggleRouting), keyEquivalent: "")
        route.target = self
        route.state = router.enabled ? .on : .off

        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "Quit Faded", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

        NSMenu.popUpContextMenu(menu, with: event, for: window.contentView ?? NSView())
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func toggleRouting() {
        router.enabled.toggle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Give macOS its default output back so audio doesn't dead-end in the
        // driver when we're not running.
        router.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
