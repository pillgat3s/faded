// Controls.swift — the small custom controls the menu is built from.
//
// SwiftUI's stock `Slider` on macOS is the thin Settings-style control with a
// square knob; Control Center's Sound module uses a rounded track with a blue
// fill and a round knob, and it responds to a click anywhere on the track.
// `FadedSlider` reproduces that. `LevelMeter` is the thin stereo bar that sits
// to the left of a device icon, the way SoundSource shows levels.

import SwiftUI

// MARK: - Slider

struct FadedSlider: View {
    @Binding var value: Float              // 0…1
    var enabled = true
    var trackHeight: CGFloat = 6
    var knobDiameter: CGFloat = 18
    var onCommit: (() -> Void)? = nil

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let usable = max(w - knobDiameter, 1)
            let frac = CGFloat(min(max(value, 0), 1))
            let knobX = usable * frac + knobDiameter / 2

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: trackHeight)
                Capsule()
                    .fill(enabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                    .frame(width: max(knobX, trackHeight), height: trackHeight)
                Circle()
                    .fill(.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                    .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                    .position(x: knobX, y: geo.size.height / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        dragging = true
                        value = Float(min(max((g.location.x - knobDiameter / 2) / usable, 0), 1))
                    }
                    .onEnded { _ in
                        guard enabled else { return }
                        dragging = false
                        onCommit?()
                    }
            )
            .animation(dragging ? nil : .easeOut(duration: 0.12), value: value)
            .opacity(enabled ? 1 : 0.5)
        }
        .frame(height: max(knobDiameter, trackHeight))
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            value = min(max(value + (direction == .increment ? 0.05 : -0.05), 0), 1)
            onCommit?()
        }
    }
}

// MARK: - Level meter

/// Thin stereo level bar shown to the left of a device or app icon.
/// `active == false` draws the empty track only (device isn't producing sound,
/// or metering isn't possible for it).
struct LevelMeter: View {
    var level: (Float, Float)
    var active = true
    var height: CGFloat = 22
    var barWidth: CGFloat = 2.5

    var body: some View {
        HStack(spacing: 1.5) {
            bar(Double(level.0))
            bar(Double(level.1))
        }
        .frame(width: barWidth * 2 + 1.5, height: height)
        .opacity(active ? 1 : 0.12)
        .accessibilityHidden(true)
    }

    private func bar(_ raw: Double) -> some View {
        // Perceptual curve: linear peak values put everyday listening levels in
        // the bottom fifth of the bar, so pull them up the way a real meter does.
        let shaped = raw <= 0.0001 ? 0 : min(1, pow(raw, 0.45))
        return GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(raw > 0.985 ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.accentColor))
                    .frame(height: max(0, geo.size.height * shaped))
                    .animation(.linear(duration: 1.0 / 15.0), value: shaped)
            }
        }
        .frame(width: barWidth)
    }
}

// MARK: - Device icon

/// The circular device badge from Control Center: filled accent when selected,
/// translucent grey otherwise.
struct DeviceBadge: View {
    var symbol: String
    var selected: Bool
    var diameter: CGFloat = 26

    var body: some View {
        ZStack {
            Circle()
                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.46, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Row background

/// Hover highlight used by every clickable row in the menu.
struct MenuRowStyle: ButtonStyle {
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hover || configuration.isPressed ? Color.primary.opacity(0.09) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}
