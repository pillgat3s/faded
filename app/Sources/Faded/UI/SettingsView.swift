// SettingsView.swift — the Settings window (⌘,) reachable from the gear in the
// menu. Three tabs, no more: what Faded does, which devices it lists, and the
// per-app levels it remembers.

import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var router: AudioRouter

    var body: some View {
        TabView {
            GeneralSettings(router: router)
                .tabItem { Label("General", systemImage: "gearshape") }
            DeviceSettings(router: router)
                .tabItem { Label("Devices", systemImage: "hifispeaker.and.appletv") }
            AppSettings(router: router)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
        }
        .frame(width: 460, height: 400)
    }
}

#if DEBUG
extension SettingsView {
    /// `--render-settings` harness. NOTE: only partially useful — on macOS both
    /// `TabView` and `Form(.grouped)` are AppKit-backed and ImageRenderer
    /// rasterises them as blank, so this pane check has to be done live. The
    /// menu (`--render-menu`) is pure SwiftUI and renders correctly.
    static func debugPanes(router: AudioRouter) -> some View {
        HStack(alignment: .top, spacing: 12) {
            GeneralSettings(router: router).frame(width: 460, height: 430)
            DeviceSettings(router: router).frame(width: 460, height: 430)
            AppSettings(router: router).frame(width: 460, height: 430)
        }
        .padding(12)
        .background(.background)
    }
}
#endif

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var router: AudioRouter
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var message: String?
    @State private var showDiagnostics = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch Faded at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
                        } catch {
                            message = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Route audio through Faded", isOn: $router.enabled)
                Text(router.enabled
                     ? "Volume keys work on every device, and each app gets its own level."
                     : "Faded is passive: macOS handles audio exactly as it would without it.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Behaviour") }

            Section {
                Toggle("Show level meters", isOn: $router.showMeters)
                Toggle("Show input devices in the menu", isOn: $router.showInputSection)
                Toggle("Hide “Faded” from macOS device lists", isOn: $router.hideFadedDevice)
                Text("Experimental. If macOS refuses to use a hidden device as the default output, Faded turns this back off by itself.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Menu") }

            Section {
                LabeledContent("Status") {
                    switch router.driverStatus {
                    case .ready: Label("Installed and running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notInstalled: Label("Not installed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case let .incompatible(v): Label("Needs updating (v\(v))", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    }
                }
                HStack {
                    if router.driverStatus == .ready {
                        Button("Reinstall…") { run { try DriverInstaller.install() } }
                        Button("Uninstall…") {
                            router.disengage(restoreDefault: true)
                            run { try DriverInstaller.uninstall() }
                        }
                    } else {
                        Button("Install Driver…") { run { try DriverInstaller.install() } }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Restart Audio…") { run { try DriverInstaller.restartCoreAudio() } }
                    Spacer()
                    Button("Diagnostics…") { showDiagnostics = true }
                }
            } header: { Text("Audio Driver") }
        }
        .formStyle(.grouped)
        .alert("Faded", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .sheet(isPresented: $showDiagnostics) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Diagnostics").font(.headline)
                ScrollView {
                    Text(router.diagnostics)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(router.diagnostics, forType: .string)
                    }
                    Spacer()
                    Button("Done") { showDiagnostics = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 460)
        }
    }

    private func run(_ op: () throws -> Void) {
        do {
            try op()
            Task { @MainActor in
                for _ in 0 ..< 20 {
                    try? await Task.sleep(for: .milliseconds(500))
                    router.driver.refresh()
                    if router.driver.isReady, router.enabled { router.engage(); break }
                }
            }
        } catch DriverInstaller.InstallError.cancelled {
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Devices

private struct DeviceSettings: View {
    @Bindable var router: AudioRouter

    var body: some View {
        Form {
            Section {
                if router.allOutputs.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(router.allOutputs) { dev in
                    row(dev, symbol: dev.symbol(forInput: false),
                        hidden: router.hiddenOutputUIDs.contains(dev.uid),
                        note: dev.hasHardwareVolume ? nil : "software volume",
                        toggle: { router.setOutputHidden(dev, $0) })
                }
            } header: { Text("Output devices") } footer: {
                Text("Unchecked devices are tucked behind “Show More” in the menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if router.allInputs.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(router.allInputs) { dev in
                    row(dev, symbol: dev.symbol(forInput: true),
                        hidden: router.hiddenInputUIDs.contains(dev.uid),
                        note: dev.hasInputVolume ? nil : "no volume control",
                        toggle: { router.setInputHidden(dev, $0) })
                }
            } header: { Text("Input devices") }
        }
        .formStyle(.grouped)
        .onAppear { router.refreshDevices() }
    }

    private func row(_ dev: AudioDevice, symbol: String, hidden: Bool, note: String?, toggle: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { !hidden }, set: { toggle(!$0) })) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(dev.name)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Apps

private struct AppSettings: View {
    @Bindable var router: AudioRouter

    var body: some View {
        Form {
            Section {
                let known = router.knownApps()
                if known.isEmpty {
                    Text("No saved app levels yet. Star an app in the menu to pin it here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(known) { app in
                    HStack(spacing: 8) {
                        Button {
                            router.setAppStarred(app.id, !app.starred)
                        } label: {
                            Image(systemName: app.starred ? "star.fill" : "star")
                                .foregroundStyle(app.starred ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        }
                        .buttonStyle(.plain)
                        .help(app.starred ? "Always shown in the menu" : "Show only while playing")

                        Image(nsImage: app.icon).resizable().frame(width: 16, height: 16)
                        Text(app.name).lineLimit(1).frame(width: 110, alignment: .leading)
                        FadedSlider(value: Binding(get: { app.muted ? 0 : app.gain },
                                                   set: { router.setAppGain(app.id, $0) }),
                                    trackHeight: 4, knobDiameter: 12)
                        Text("\(Int((app.muted ? 0 : app.gain) * 100))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                        Button {
                            router.forgetApp(app.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Forget \(app.name)")
                    }
                }
            } header: { Text("Saved app levels") } footer: {
                Text("Starred apps always appear in the menu, even when they're silent. Everything else shows up while it's playing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { router.refreshApps() }
    }
}
