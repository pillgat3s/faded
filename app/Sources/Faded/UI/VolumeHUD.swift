// VolumeHUD.swift — the bezel the system would have shown.
//
// When Faded swallows a volume key (device without hardware volume), macOS
// never draws its own volume HUD, so this one stands in: a small pill under
// the menu bar, top-right, that fades a moment after the last key.

import AppKit
import SwiftUI

@MainActor
final class VolumeHUD {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let model = HUDModel()

    func show(volume: Float, muted: Bool, deviceName: String) {
        model.volume = volume
        model.muted = muted
        model.name = deviceName
        let p = panel ?? makePanel()
        place(p)
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func fadeOut() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            p.animator().alphaValue = 0
        }, completionHandler: { Task { @MainActor in if p.alphaValue == 0 { p.orderOut(nil) } } })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: HUDView(model: model))
        panel = p
        return p
    }

    private func place(_ p: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 12, y: f.maxY - size.height - 8))
    }
}

@Observable
private final class HUDModel {
    var volume: Float = 1
    var muted = false
    var name = ""
}

private struct HUDView: View {
    let model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.muted || model.volume <= 0.001 ? "speaker.slash.fill"
                              : model.volume < 0.34 ? "speaker.wave.1.fill"
                              : model.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 20)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.18))
                    Capsule().fill(.primary)
                        .frame(width: geo.size.width * CGFloat(model.muted ? 0 : model.volume))
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 14)
        .frame(width: 220, height: 44)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}
