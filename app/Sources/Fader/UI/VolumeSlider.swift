// VolumeSlider.swift — a Control-Center-style capsule slider.
//
// The stock SwiftUI Slider on macOS is the small "settings" slider; the Sound
// module in Control Center / the menu bar uses a tall capsule with the glyph
// riding inside the filled part. This reproduces that: track = capsule with
// material, fill = solid capsule, glyph at the leading edge, drag anywhere.

import SwiftUI

struct VolumeSlider: View {
    @Binding var value: Float          // 0…1 (or 0…max)
    var max: Float = 1
    var glyph: String? = nil           // SF Symbol shown inside the fill
    var height: CGFloat = 22
    var muted = false
    var onEditingChanged: ((Bool) -> Void)? = nil

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = CGFloat(min(Swift.max(value / max, 0), 1))
            let fillWidth = Swift.max(height, w * frac)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(muted ? AnyShapeStyle(.secondary.opacity(0.35)) : AnyShapeStyle(.primary.opacity(0.9)))
                    .frame(width: fillWidth)
                if let glyph {
                    Image(systemName: glyph)
                        .font(.system(size: height * 0.5, weight: .semibold))
                        .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.background))
                        .frame(width: height, height: height)
                }
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { dragging = true; onEditingChanged?(true) }
                        let x = g.location.x - height / 2
                        let usable = Swift.max(w - height, 1)
                        value = Float(min(Swift.max(x / usable, 0), 1)) * max
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged?(false)
                    }
            )
            .animation(dragging ? nil : .easeOut(duration: 0.12), value: value)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((value / max) * 100)) percent")
    }
}

/// Thin peak meter used under per-app sliders.
struct PeakMeter: View {
    var level: Float // 0…1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.6))
                Capsule()
                    .fill(level > 0.98 ? Color.red : Color.accentColor.opacity(0.8))
                    .frame(width: geo.size.width * CGFloat(min(level, 1)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 2)
    }
}
