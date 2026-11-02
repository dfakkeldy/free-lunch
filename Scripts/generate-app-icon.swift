#!/usr/bin/swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Generates Free Lunch's PLACEHOLDER app icon: a cream plate with a dark fork
// resting across it, on a warm apricot field. It stands in until a designed
// icon is commissioned; replace this generator (and the test's expectations)
// when that artwork lands.
//
// Regenerate both target assets from this source rather than editing their
// PNGs by hand:
//
//   swift Scripts/generate-app-icon.swift FreeLunchPhone/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//   cp FreeLunchPhone/Assets.xcassets/AppIcon.appiconset/AppIcon.png \
//      FreeLunchWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// Design rules the placeholder follows (Scripts/validate-app-icon.swift checks
// the measurable ones):
// - 1024x1024, opaque RGB, flat fills only: no text, gradients or shadows.
// - Every mark pixel stays inside a central circle of radius 471 px, so the
//   Watch's circular mask never clips the plate or the fork.
// - The smallest features (tines 34 px, gaps 22 px) stay at least ~2 px wide
//   at 40 pt on a 3x iPhone screen.

import CoreGraphics
import Foundation
import ImageIO

let canvasSize = 1024
let apricot = (r: 0xF2, g: 0x8C, b: 0x45)    // background field
let cream = (r: 0xFF, g: 0xF4, b: 0xE3)      // plate rim
let creamWell = (r: 0xFB, g: 0xE2, b: 0xC4)  // plate well
let warmInk = (r: 0x4A, g: 0x26, b: 0x18)    // fork

let plateRadius: CGFloat = 330
let wellRadius: CGFloat = 242
let forkAngleDegrees: CGFloat = 38

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        "Usage: swift generate-app-icon.swift <output.png>\n".data(using: .utf8)!
    )
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: canvasSize,
    height: canvasSize,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("Could not create CGContext")
}

// Work top-down (y grows downward), like an SVG or a design tool.
context.translateBy(x: 0, y: CGFloat(canvasSize))
context.scaleBy(x: 1, y: -1)

func setFill(_ color: (r: Int, g: Int, b: Int)) {
    context.setFillColor(
        red: CGFloat(color.r) / 255,
        green: CGFloat(color.g) / 255,
        blue: CGFloat(color.b) / 255,
        alpha: 1
    )
}

func fillCircle(radius: CGFloat, color: (r: Int, g: Int, b: Int)) {
    setFill(color)
    let centre = CGFloat(canvasSize) / 2
    context.fillEllipse(in: CGRect(
        x: centre - radius,
        y: centre - radius,
        width: radius * 2,
        height: radius * 2
    ))
}

setFill(apricot)
context.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

fillCircle(radius: plateRadius, color: cream)
fillCircle(radius: wellRadius, color: creamWell)

// The fork is one closed outline (no overlapping shapes, so no antialiasing
// seams), drawn in a local frame centred on the plate with the tines pointing
// up (-y), then rotated clockwise onto the diagonal.
//
// In this y-down frame, clockwise: false sweeps the angle upward, so the tine
// tips (pi -> 2pi) arc over the top and the handle end (0 -> pi) arcs under
// the bottom; clockwise: true sweeps it downward, so the gap bottoms
// (pi -> 0) dip below the tine roots.
let tineRadius: CGFloat = 17      // tines are 34 px wide
let gapRadius: CGFloat = 11       // gaps are 22 px wide
let tineTipCentreY: CGFloat = -283
let gapBottomCentreY: CGFloat = -150
let tineCentres: [CGFloat] = [-56, 0, 56]
let handleEndCentreY: CGFloat = 266
let handleEndRadius: CGFloat = 34

let fork = CGMutablePath()
fork.move(to: CGPoint(x: -handleEndRadius, y: handleEndCentreY))
fork.addLine(to: CGPoint(x: -22, y: -10))
fork.addCurve(
    to: CGPoint(x: -73, y: -120),
    control1: CGPoint(x: -22, y: -50),
    control2: CGPoint(x: -73, y: -55)
)
for (index, tineX) in tineCentres.enumerated() {
    fork.addArc(
        center: CGPoint(x: tineX, y: tineTipCentreY),
        radius: tineRadius,
        startAngle: .pi,
        endAngle: 2 * .pi,
        clockwise: false
    )
    if index < tineCentres.count - 1 {
        let gapX = tineX + tineRadius + gapRadius
        fork.addArc(
            center: CGPoint(x: gapX, y: gapBottomCentreY),
            radius: gapRadius,
            startAngle: .pi,
            endAngle: 0,
            clockwise: true
        )
    }
}
fork.addLine(to: CGPoint(x: 73, y: -120))
fork.addCurve(
    to: CGPoint(x: 22, y: -10),
    control1: CGPoint(x: 73, y: -55),
    control2: CGPoint(x: 22, y: -50)
)
fork.addArc(
    center: CGPoint(x: 0, y: handleEndCentreY),
    radius: handleEndRadius,
    startAngle: 0,
    endAngle: .pi,
    clockwise: false
)
fork.closeSubpath()

context.saveGState()
context.translateBy(x: CGFloat(canvasSize) / 2, y: CGFloat(canvasSize) / 2)
context.rotate(by: forkAngleDegrees * .pi / 180)
setFill(warmInk)
context.addPath(fork)
context.fillPath()
context.restoreGState()

guard let cgImage = context.makeImage() else {
    fatalError("Could not create CGImage from context")
}

let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL,
    "public.png" as CFString,
    1,
    nil
) else {
    fatalError("Could not create image destination at \(outputPath)")
}
CGImageDestinationAddImage(destination, cgImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Could not finalize PNG at \(outputPath)")
}

print("Wrote \(outputPath) (1024x1024 RGB, no alpha, Free Lunch placeholder)")
