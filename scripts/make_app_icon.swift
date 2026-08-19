#!/usr/bin/env swift
// Generates Fader's app icon into
// app/Sources/Fader/Resources/Assets.xcassets/AppIcon.appiconset.
//
// Run from the repo root:  swift scripts/make_app_icon.swift
//
// Rasterises straight into NSBitmapImageRep at exact pixel sizes (drawing into
// an NSImage inherits the Retina backing scale and silently doubles every
// file, which actool then rejects). One appearance: near-black tile, three
// white fader tracks with orange caps — reads as "mixer" at 16 px.

import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = URL(fileURLWithPath: "app/Sources/Fader/Resources/Assets.xcassets/AppIcon.appiconset")

func draw(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    // Tile with macOS-style continuous corner radius (~22.4% of size).
    let inset = s * 0.05
    let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                            xRadius: s * 0.224, yRadius: s * 0.224)
    let g = NSGradient(colors: [NSColor(calibratedWhite: 0.13, alpha: 1), NSColor(calibratedWhite: 0.05, alpha: 1)])!
    g.draw(in: tile, angle: -90)

    // Three vertical fader tracks.
    let trackW = s * 0.055
    let trackH = s * 0.52
    let baseY = (s - trackH) / 2
    let xs: [CGFloat] = [0.32, 0.5, 0.68].map { $0 * s }
    let caps: [CGFloat] = [0.62, 0.36, 0.78] // knob positions along the track
    for (i, x) in xs.enumerated() {
        let track = NSBezierPath(roundedRect: NSRect(x: x - trackW / 2, y: baseY, width: trackW, height: trackH),
                                 xRadius: trackW / 2, yRadius: trackW / 2)
        NSColor(calibratedWhite: 1, alpha: 0.28).setFill()
        track.fill()
        // filled part
        let fillH = trackH * caps[i]
        let fill = NSBezierPath(roundedRect: NSRect(x: x - trackW / 2, y: baseY, width: trackW, height: fillH),
                                xRadius: trackW / 2, yRadius: trackW / 2)
        NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
        fill.fill()
        // knob
        let knobW = s * 0.15, knobH = s * 0.075
        let knob = NSBezierPath(roundedRect: NSRect(x: x - knobW / 2, y: baseY + fillH - knobH / 2, width: knobW, height: knobH),
                                xRadius: knobH / 2, yRadius: knobH / 2)
        NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.16, alpha: 1).setFill()
        knob.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for px in sizes {
    let rep = draw(px: px)
    let data = rep.representation(using: .png, properties: [:])!
    let url = outDir.appendingPathComponent("icon_\(px).png")
    try! data.write(to: url)
    print("wrote \(url.lastPathComponent) (\(px)px)")
}
