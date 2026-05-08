#!/usr/bin/env swift
// Generates a Retina DMG background image (660x400 @2x = 1320x800).
// Dark gradient with a subtle arrow and "Drag to Applications" hint.

import AppKit
import CoreGraphics
import CoreText
import Foundation

let width = 1320  // 660pt @2x
let height = 800  // 400pt @2x
let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "dist/dmg-background.png"

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// --- Dark gradient background ---
let gradColors = [
    CGColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0),
    CGColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1.0),
]
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: gradColors as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: Double(height)),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// --- Arrow from app icon area to Applications area ---
// Icon centers at ~180pt and ~480pt → 360px and 960px @2x
let arrowY = Double(height) / 2.0 + 10  // slightly above center
let arrowLeft = 480.0
let arrowRight = 840.0
let arrowHeadSize = 24.0

// Arrow line
ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.25))
ctx.setLineWidth(3.0)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: arrowLeft, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowRight, y: arrowY))
ctx.strokePath()

// Arrow head
ctx.setFillColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.25))
ctx.move(to: CGPoint(x: arrowRight, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowRight - arrowHeadSize, y: arrowY + arrowHeadSize * 0.6))
ctx.addLine(to: CGPoint(x: arrowRight - arrowHeadSize, y: arrowY - arrowHeadSize * 0.6))
ctx.closePath()
ctx.fillPath()

// --- "Drag to Applications" text ---
let fontSize: CGFloat = 26.0
let font = CTFontCreateWithName("Helvetica Neue" as CFString, fontSize, nil)
let textColor = CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.35)

let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: textColor,
]
let text = NSAttributedString(string: "Drag to Applications", attributes: attrs)
let line = CTLineCreateWithAttributedString(text)
let textBounds = CTLineGetBoundsWithOptions(line, [])
let textX = (Double(width) - textBounds.width) / 2.0
let textY = arrowY - 70.0

ctx.textPosition = CGPoint(x: textX, y: textY)
CTLineDraw(line, ctx)

// --- Write PNG ---
let image = ctx.makeImage()!
let url = URL(fileURLWithPath: output)
try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
// Set DPI to 144 (72 * 2) so macOS treats it as @2x
let properties: [CFString: Any] = [
    kCGImagePropertyDPIWidth: 144,
    kCGImagePropertyDPIHeight: 144,
]
CGImageDestinationAddImage(dest, image, properties as CFDictionary)
CGImageDestinationFinalize(dest)

print("Generated DMG background: \(output) (\(width)x\(height) @2x)")
