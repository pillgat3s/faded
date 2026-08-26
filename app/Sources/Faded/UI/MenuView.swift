// MenuView.swift — the popover under the menu bar icon.
//
// Deliberately shaped like Control Center's Sound module: title, one big
// volume slider, an "Output" list of circular device badges, a matching
// "Input" list, and "Sound Settings…" at the bottom. Faded's own additions are
// the level meters beside each row and the collapsible Apps section.

import AppKit
import SwiftUI

struct MenuView: View {
    @Bindable var router: AudioRouter
    /// DEBUG render mode starts with the Apps list open (see `--render-menu`).
    var previewExpandApps = false
    // Collapsed sections show only the selected device — the useful summary —
    // and remember their state across popover openings.
    @AppStorage("menuOutputExpanded") private var outputExpanded = true
    @AppStorage("menuInputExpanded") private var inputExpanded = true
    @State private var showingHidden = false
    @State private var appsExpanded = false
    @State private var installError: String?
    @Environment(\.openSettings) private var openSettings

    private let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if router.driverStatus == .ready {
                if router.steppedAside { steppedAsideBanner }
                outputSlider
                outputSection
                if router.showInputSection, !router.allInputs.isEmpty { inputSection }
                appsSection
            } else {
                driverCard
            }
            footer
        }
        .frame(width: width)
        .padding(.vertical, 8)
        .onAppear {
            appsExpanded = appsExpanded || previewExpandApps
            router.refreshDevices()
            router.refreshApps()
            router.startMetering()
        }
        .onDisappear { router.stopMetering() }
        // NB: MenuBarExtra(.window) builds this view at launch and does not
        // reliably send onDisappear, so the router also checks popover
        // visibility on every tick — see AudioRouter.startMetering().
        .alert("Driver", isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })) {
            Button("OK") { installError = nil }
        } message: { Text(installError ?? "") }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Sound").font(.system(size: 14, weight: .bold))
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Faded Settings")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: Output volume

    private var outputSlider: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            FadedSlider(value: Binding(get: { router.muted ? 0 : router.volume },
                                       set: { router.setVolume($0) }),
                        enabled: router.target != nil)
            Button {
                router.setMuted(!router.muted)
            } label: {
                Image(systemName: router.muted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(router.muted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(router.muted ? "Unmute" : "Mute")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: Output devices

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionToggle("Output", isExpanded: $outputExpanded)
            if outputExpanded {
                ForEach(router.visibleOutputs) { dev in
                    deviceRow(dev, selected: dev.uid == router.target?.uid, kind: .output)
                }
                if showingHidden {
                    ForEach(router.hiddenOutputs) { dev in
                        deviceRow(dev, selected: dev.uid == router.target?.uid, kind: .output, dimmed: true)
                    }
                }
                if router.visibleOutputs.isEmpty, !showingHidden {
                    Text("No output devices").font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 4)
                }
                ForEach(router.offlineBluetooth) { bt in
                    offlineBluetoothRow(bt)
                }
                if router.hasHiddenDevices { showMoreRow }
                Text("AirPlay speakers: choose them in Control Center.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 3)
            } else if let t = router.target,
                      let dev = router.allOutputs.first(where: { $0.uid == t.uid }) {
                deviceRow(dev, selected: true, kind: .output)
            }
        }
        .padding(.bottom, 8)
    }

    /// A paired headset that is not audio-connected (with the iPhone, or in
    /// its case). Clicking connects it, exactly like Control Center would.
    private func offlineBluetoothRow(_ bt: PairedBluetoothDevice) -> some View {
        Button { router.connectBluetooth(bt) } label: {
            HStack(spacing: 10) {
                Color.clear.frame(width: meterWidth)
                Group {
                    if router.connectingBluetooth == bt.id {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: bt.name.localizedCaseInsensitiveContains("airpods max")
                                          ? "airpods.max" : bt.name.localizedCaseInsensitiveContains("airpods")
                                          ? "airpods.pro" : "headphones")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 26)
                Text(bt.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.trailing, 8)
        }
        .buttonStyle(MenuRowStyle())
        .padding(.horizontal, 8)
        .disabled(router.connectingBluetooth != nil)
    }

    /// Shown when macOS has routed output somewhere Faded cannot follow.
    private var steppedAsideBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: "airplayaudio")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(router.target?.transport == .bluetooth
                 ? "\(router.target?.name ?? "Your headphones") are handled natively — auto-switching with your iPhone and ear detection work as usual. Per-app volume resumes on other devices."
                 : "macOS is routing audio directly\(router.target.map { " to \($0.name)" } ?? ""). Faded is standing by.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var showMoreRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { showingHidden.toggle() }
        } label: {
            HStack(spacing: 8) {
                Text(showingHidden ? "Show Less" : "Show More")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(showingHidden ? 90 : 0))
            }
            .padding(.leading, meterWidth + 8 + 26 + 10)
            .padding(.trailing, 8)
        }
        .buttonStyle(MenuRowStyle())
        .padding(.horizontal, 8)
    }

    // MARK: Input devices

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionToggle("Input", isExpanded: $inputExpanded)
            if inputExpanded {
                ForEach(router.visibleInputs) { dev in
                    deviceRow(dev, selected: dev.uid == router.selectedInput?.uid, kind: .input)
                }
                if showingHidden {
                    ForEach(router.hiddenInputs) { dev in
                        deviceRow(dev, selected: dev.uid == router.selectedInput?.uid, kind: .input, dimmed: true)
                    }
                }
            } else if let i = router.selectedInput,
                      let dev = router.allInputs.first(where: { $0.uid == i.uid }) {
                deviceRow(dev, selected: true, kind: .input)
            }
        }
        .padding(.bottom, 8)
    }

    /// Section header that collapses its list, shaped exactly like the Apps
    /// toggle so the three sections read as one family.
    private func sectionToggle(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                Spacer()
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(MenuRowStyle())
        .padding(.horizontal, 8)
    }

    // MARK: Device row    // MARK: Device row

    private enum DeviceKind { case output, input }

    private var meterWidth: CGFloat { router.showMeters ? 6.5 : 0 }

    @ViewBuilder
    private func deviceRow(_ dev: AudioDevice, selected: Bool, kind: DeviceKind, dimmed: Bool = false) -> some View {
        Button {
            kind == .output ? router.select(dev) : router.selectInput(dev)
        } label: {
            HStack(spacing: 8) {
                if router.showMeters {
                    LevelMeter(level: meterLevel(dev, kind: kind, selected: selected),
                               active: meterActive(dev, kind: kind, selected: selected),
                               height: 22)
                }
                DeviceBadge(symbol: dev.symbol(forInput: kind == .input), selected: selected)
                Text(dev.name)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if dimmed {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(MenuRowStyle())
        .padding(.horizontal, 8)
        .opacity(dimmed ? 0.55 : 1)
        .contextMenu {
            Button(dimmed ? "Show in Menu" : "Hide from Menu") {
                switch kind {
                case .output: router.setOutputHidden(dev, !dimmed)
                case .input: router.setInputHidden(dev, !dimmed)
                }
            }
        }
    }

    private func meterLevel(_ dev: AudioDevice, kind: DeviceKind, selected: Bool) -> (Float, Float) {
        guard selected else { return (0, 0) }
        switch kind {
        case .output: return router.isEngaged ? router.outputLevel : (0, 0)
        case .input: return router.canMeterInput ? router.inputLevel : (0, 0)
        }
    }

    private func meterActive(_ dev: AudioDevice, kind: DeviceKind, selected: Bool) -> Bool {
        guard selected else { return false }
        return kind == .output ? router.isEngaged : router.canMeterInput
    }

    // MARK: Apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { appsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Apps")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(appsExpanded ? 90 : 0))
                    Spacer()
                    if !appsExpanded, !router.playingEntries.isEmpty {
                        Text("\(router.playingEntries.count) playing")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(MenuRowStyle())
            .padding(.horizontal, 8)

            ForEach(visibleAppRows) { app in
                appRow(app)
            }
            if appsExpanded, !router.browserTabs.isEmpty {
                Text("Chrome tabs")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                ForEach(router.browserTabs) { tab in
                    tabRow(tab)
                }
            }
            // Only say nothing is playing when nothing actually is. A collapsed
            // section with unstarred apps behind it has no rows to show, but
            // the header's count is already telling the truth.
            if router.apps.isEmpty {
                Text("Nothing is playing audio.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 4)
            } else if visibleAppRows.isEmpty {
                Text("Open Apps to set levels, or star an app to keep it here.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 16).padding(.vertical, 2)
            }
        }
        .padding(.bottom, 6)
    }

    /// Starred apps are always listed; everything else only while expanded.
    private var visibleAppRows: [AudioRouter.AppEntry] {
        appsExpanded ? router.apps : router.starredEntries
    }

    private func appRow(_ app: AudioRouter.AppEntry) -> some View {
        HStack(spacing: 7) {
            Button {
                router.setAppStarred(app.id, !app.starred)
            } label: {
                Image(systemName: app.starred ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(app.starred ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 13)
            }
            .buttonStyle(.plain)
            .help(app.starred ? "Unpin \(app.name)" : "Always show \(app.name)")

            if router.showMeters {
                LevelMeter(level: (app.peak, app.peak), active: app.isPlaying, height: 16)
            }

            Image(nsImage: app.icon)
                .resizable().interpolation(.high)
                .frame(width: 17, height: 17)

            Text(app.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 78, alignment: .leading)

            FadedSlider(value: Binding(get: { app.muted ? 0 : app.gain },
                                       set: { router.setAppGain(app.id, $0) }),
                        trackHeight: 4, knobDiameter: 12)

            Button {
                router.setAppMuted(app.id, !app.muted)
            } label: {
                Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(app.muted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(app.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .opacity(app.isPlaying ? 1 : 0.6)
        .contextMenu {
            Button("Reset to 100%") { router.resetAppGain(app.id) }
            Button(app.starred ? "Don't Always Show" : "Always Show") { router.setAppStarred(app.id, !app.starred) }
            Divider()
            Text(app.id)
        }
    }

    /// One Chrome tab, driven through the extension bridge. Shaped like an app
    /// row, indented, no star (tabs are ephemeral) and no meter (levels live in
    /// the page; the extension does not stream them).
    private func tabRow(_ tab: BrowserTab) -> some View {
        HStack(spacing: 7) {
            Image(systemName: tab.audible ? "speaker.wave.2" : "globe")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 13)
            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 96, alignment: .leading)
            FadedSlider(value: Binding(get: { tab.muted ? 0 : tab.gain },
                                       set: { router.setTabGain(tab.id, $0) }),
                        trackHeight: 4, knobDiameter: 12)
            Button {
                router.setTabMuted(tab.id, !tab.muted)
            } label: {
                Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(tab.muted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(tab.muted ? "Unmute tab" : "Mute tab")
        }
        .padding(.leading, 30)
        .padding(.trailing, 16)
        .padding(.vertical, 2)
    }

    // MARK: Driver card

    private var driverCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch router.driverStatus {
            case .notInstalled:
                Label("Audio driver not installed", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Faded needs a small audio driver to control per-app volume and devices that have no volume control of their own. Installing asks for your password once and restarts the audio system (about a second of silence).")
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
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func runInstall(_ op: () throws -> Void) {
        do {
            try op()
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
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 12).padding(.bottom, 6)
            footerRow("Sound Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            footerRow("Quit Faded") {
                NSApp.terminate(nil)
            }
        }
    }

    private func footerRow(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(MenuRowStyle())
        .padding(.horizontal, 8)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 3)
    }
}
