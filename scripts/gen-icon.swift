#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

// MARK: - Design tokens

let canvas: CGFloat = 1024
let cornerRatio: CGFloat = 0.2237   // classic macOS squircle-ish
let bgTop = NSColor(srgbRed: 0x1E/255.0, green: 0x1F/255.0, blue: 0x24/255.0, alpha: 1)
let bgBottom = NSColor(srgbRed: 0x0E/255.0, green: 0x0F/255.0, blue: 0x12/255.0, alpha: 1)
let rimHighlight = NSColor(white: 1, alpha: 0.08)
let innerShadow = NSColor(white: 0, alpha: 0.45)
let inkColor = NSColor(srgbRed: 0xEA/255.0, green: 0xE4/255.0, blue: 0xD4/255.0, alpha: 1)

// MARK: - Icon draw

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: px * 4,
        bitsPerPixel: 32
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Scale drawing to this size
    let scale = size / canvas
    ctx.scaleBy(x: scale, y: scale)

    let rect = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    let r = canvas * cornerRatio
    let bgPath = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)

    // Clip + fill gradient
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [bgTop.cgColor, bgBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: canvas),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Soft radial highlight, top-left
    let radial = CGGradient(
        colorsSpace: space,
        colors: [
            NSColor(white: 1, alpha: 0.10).cgColor,
            NSColor(white: 1, alpha: 0).cgColor
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        radial,
        startCenter: CGPoint(x: canvas * 0.3, y: canvas * 0.78),
        startRadius: 0,
        endCenter: CGPoint(x: canvas * 0.3, y: canvas * 0.78),
        endRadius: canvas * 0.65,
        options: []
    )

    ctx.restoreGState()

    // Inner hairline rim (1px @ source scale, scaled with canvas)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setLineWidth(2)
    ctx.setStrokeColor(rimHighlight.cgColor)
    ctx.strokePath()
    ctx.restoreGState()

    // MARK: - Glyph: stylized "N"
    //
    // Three strokes: left vertical, diagonal (top-left -> bottom-right), right vertical.
    // Rounded line caps. Proportions tuned to feel premium and legible at ≥64pt.

    let glyphInset: CGFloat = canvas * 0.26
    let glyphRect = CGRect(x: glyphInset,
                           y: glyphInset + canvas * 0.01,
                           width: canvas - glyphInset * 2,
                           height: canvas - glyphInset * 2 - canvas * 0.02)
    let strokeWidth = canvas * 0.095

    ctx.saveGState()
    ctx.setStrokeColor(inkColor.cgColor)
    ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let left = glyphRect.minX + strokeWidth * 0.5
    let right = glyphRect.maxX - strokeWidth * 0.5
    let top = glyphRect.maxY - strokeWidth * 0.5
    let bottom = glyphRect.minY + strokeWidth * 0.5

    // Left stroke
    ctx.move(to: CGPoint(x: left, y: bottom))
    ctx.addLine(to: CGPoint(x: left, y: top))
    // Diagonal
    ctx.move(to: CGPoint(x: left, y: top))
    ctx.addLine(to: CGPoint(x: right, y: bottom))
    // Right stroke
    ctx.move(to: CGPoint(x: right, y: bottom))
    ctx.addLine(to: CGPoint(x: right, y: top))

    ctx.strokePath()

    // Accent dot — captured thought — lower right, subtle warm highlight
    let dotR = canvas * 0.028
    let dotCenter = CGPoint(x: glyphRect.maxX + canvas * 0.028,
                            y: glyphRect.minY - canvas * 0.005)
    ctx.setFillColor(inkColor.cgColor)
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotR,
                               y: dotCenter.y - dotR,
                               width: dotR * 2, height: dotR * 2))
    ctx.restoreGState()

    // Subtle inner shadow at bottom to ground the shape
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bottomShade = CGGradient(
        colorsSpace: space,
        colors: [
            NSColor(white: 0, alpha: 0).cgColor,
            NSColor(white: 0, alpha: 0.25).cgColor
        ] as CFArray,
        locations: [0.75, 1]
    )!
    ctx.drawLinearGradient(
        bottomShade,
        start: CGPoint(x: 0, y: canvas),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    _ = innerShadow
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()

    // Ensure the bitmap rep reports the correct pixel size (avoid 2x retina behavior)
    rep.size = NSSize(width: px, height: px)
    return rep
}

// MARK: - Emit

struct Slot {
    let filename: String
    let pixels: CGFloat
}

let slots: [Slot] = [
    Slot(filename: "icon_16x16.png",      pixels: 16),
    Slot(filename: "icon_16x16@2x.png",   pixels: 32),
    Slot(filename: "icon_32x32.png",      pixels: 32),
    Slot(filename: "icon_32x32@2x.png",   pixels: 64),
    Slot(filename: "icon_128x128.png",    pixels: 128),
    Slot(filename: "icon_128x128@2x.png", pixels: 256),
    Slot(filename: "icon_256x256.png",    pixels: 256),
    Slot(filename: "icon_256x256@2x.png", pixels: 512),
    Slot(filename: "icon_512x512.png",    pixels: 512),
    Slot(filename: "icon_512x512@2x.png", pixels: 1024),
]

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("Usage: gen-icon.swift <output-appiconset-dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])

// Render each unique size once, write a PNG per slot.
var cache: [Int: Data] = [:]
for slot in slots {
    let key = Int(slot.pixels)
    let data: Data
    if let cached = cache[key] {
        data = cached
    } else {
        let rep = drawIcon(size: slot.pixels)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fputs("Failed to encode PNG for \(key)\n", stderr)
            exit(1)
        }
        cache[key] = png
        data = png
    }
    let url = outDir.appendingPathComponent(slot.filename)
    try data.write(to: url)
    print("Wrote \(slot.filename) (\(key)px, \(data.count)B)")
}

// Update Contents.json to reference the new files.
let contentsJSON = """
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",     "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",     "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",     "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",     "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128",   "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128",   "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256",   "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256",   "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512",   "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512",   "filename" : "icon_512x512@2x.png" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
let contentsURL = outDir.appendingPathComponent("Contents.json")
try contentsJSON.data(using: .utf8)!.write(to: contentsURL)
print("Updated Contents.json")
