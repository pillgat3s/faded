// MenuView.swift — the popover under the menu bar icon. Laid out like the
// macOS Control Center "Sound" module: title, big output slider, Output device
// list with checkmarks, then Fader's additions (Apps) and a footer.

import AppKit
import ServiceManagement
import SwiftUI

struct MenuView: View {
    @Bindable var router: AudioRouter
    @State private var showDiagnostics = false
    @State private var installError: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            if router.driverStatus != .ready {
                driverCard
            } else {
                outputSection
                if !router.apps.isEmpty || router.isEngaged {
                    Divider().padding(.horizontal, 12).padding(.top, 6)
                    appsSection
                }
            }
            Divider().padding(.horizontal, 12).padding(.top, 6)
            footer
        }
        .frame(width: width)
        .padding(.vertical, 6)
        .onAppear { router.refreshOutputs(); router.refreshApps(); router.startMetering() }
        .onDisappear { router.stopMetering() }
        .alert("Driver", isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })) {
            Button("OK") { installError = nil }
        } message: { Text(installError ?? "") }
    }

    // MARK: Header + master slider

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sound").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let t = router.target, router.isEngaged {
                    Label(t.name, systemImage: t.transport.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                VolumeSlider(value: Binding(get: { router.volume }, set: { router.setVolume($0) }),
                             glyph: volumeGlyph, muted: router.muted)
                Button {
                    router.setMuted(!router.muted)
                } label: {
                    Image(systemName: router.muted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(router.muted ? "Unmute" : "Mute")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var volumeGlyph: String {
        if router.muted || router.volume <= 0.001 { return "speaker.slash.fill" }
        if router.volume < 0.34 { return "speaker.wave.1.fill" }
        if router.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: Output devices

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Output")
            ForEach(router.outputs) { dev in
                DeviceRow(device: dev,
                          selected: dev.uid == router.target?.uid,
                          detail: dev.hasHardwareVolume ? nil : "software volume")
                {
                    router.select(dev)
                }
            }
            if router.outputs.isEmpty {
                Text("No output devices").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 14)
            }
            Text("AirPlay speakers: pick them in Control Center as usual — Fader follows.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .padding(.horizontal, 14).padding(.top, 4)
        }
        .padding(.top, 6)
    }

    // MARK: Apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Apps")
            if router.apps.isEmpty {
                Text("Nothing is playing audio.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 4)
            }
            ForEach(router.apps) { app in
                AppRow(app: app,
                       setGain: { router.setAppGain(app.id, $0) },
                       toggleMute: { router.setAppMuted(app.id, !app.muted) },
                       reset: { router.resetAppGain(app.id) })
            }
        }
        .padding(.top, 6)
    }

    // MARK: Driver card

    private var driverCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch router.driverStatus {
            case .notInstalled:
                Label("Audio driver not installed", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Fader needs a small system audio driver to control volume per app and on devices without a volume control. Installing asks for your password once and restarts the audio system (≈1 s of silence).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Install Driver…") { runInstall { try DriverInstaller.install() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case let .incompatible(found):
                Label("Driver needs updating (installed v\(found))", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                Button("Update Driver…") { runInstall { try DriverInstaller.install() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .ready:
                EmptyView()
            }
        }
        .padding(14)
    }

    private func runInstall(_ op: () throws -> Void) {
        do {
            try op()
            // coreaudiod restarts asynchronously; poll the driver back in.
            Task { @MainActor in
                for _ in 0 ..< 20 {
                    try? await Task.sleep(for: .milliseconds(500))
                    router.driver.refresh()
                    if router.driver.isReady { router.engage(); break }
                }
            }
        } catch DriverInstaller.InstallError.cancelled {
            // user hit cancel — nothing to say
        } catch {
            installError = error.localizedDescription
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Sound Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain).font(.system(size: 12))
            Spacer()
            Menu {
                Toggle("Route audio through Fader", isOn: $router.enabled)
                Toggle("Hide “Fader” from device lists (experimental)", isOn: $router.hideFaderDevice)
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Divider()
                if DriverInstaller.updateAvailable {
                    Button("Update Driver…") { runInstall { try DriverInstaller.install() } }
                }
                Button("Restart Audio System…") { runInstall { try DriverInstaller.restartCoreAudio() } }
                Button("Uninstall Driver…") {
                    router.disengage(restoreDefault: true)
                    runInstall { try DriverInstaller.uninstall() }
                }
                Divider()
                Button("Diagnostics…") { showDiagnostics = true }
                Button("Quit Fader") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .popover(isPresented: $showDiagnostics, arrowEdge: .bottom) {
            ScrollView {
                Text(router.diagnostics)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(width: 360, height: 180)
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.bottom, 2)
    }
}

// MARK: - Rows

private struct DeviceRow: View {
    let device: AudioDevice
    let selected: Bool
    let detail: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 12)
                    .opacity(selected ? 1 : 0)
                Image(systemName: device.transport.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(device.name).font(.system(size: 13)).lineLimit(1)
                Spacer()
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hover = $0 }
    }
}

private struct AppRow: View {
    let app: AudioRouter.AppEntry
    let setGain: (Float) -> Void
    let toggleMute: () -> Void
    let reset: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Image(nsImage: app.icon)
                    .resizable().interpolation(.high)
                    .frame(width: 18, height: 18)
                Text(app.name).font(.system(size: 12)).lineLimit(1)
                    .frame(width: 84, alignment: .leading)
                VolumeSlider(value: Binding(get: { app.gain }, set: { setGain($0) }),
                             max: 2, glyph: nil, height: 14, muted: app.muted)
                    .help("\(Int(app.gain * 100))% — drag past the middle to boost")
                Button(action: toggleMute) {
                    Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11)).frame(width: 16)
                }
                .buttonStyle(.plain).foregroundStyle(app.muted ? .red : .secondary)
                .help(app.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            }
            HStack(spacing: 8) {
                Spacer().frame(width: 18 + 8 + 84)
                PeakMeter(level: app.peak)
                Spacer().frame(width: 16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .contextMenu {
            Button("Reset to 100%") { reset() }
            Text(app.id).font(.caption)
        }
    }
}
