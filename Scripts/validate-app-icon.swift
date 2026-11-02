#!/usr/bin/swift
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Checks an app icon PNG against the rules App Store upload and the Watch's
// circular mask need: 1024x1024, 8-bit RGB with no alpha channel, and every
// pixel outside the central safe circle left as the flat background colour.

import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
        "app-icon-validator: FAIL: \(message)\n".data(using: .utf8)!
    )
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: swift validate-app-icon.swift <icon.png>")
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("cannot decode \(url.path)")
}

let width = 1024
let height = 1024
guard image.width == width, image.height == height else {
    fail("expected \(width)x\(height), got \(image.width)x\(image.height)")
}

switch image.alphaInfo {
case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast:
    fail("alpha channel is not allowed (CGImageAlphaInfo \(image.alphaInfo.rawValue))")
default:
    break
}

guard image.colorSpace?.model == .rgb, image.bitsPerComponent == 8 else {
    fail("expected 8-bit RGB, got \(image.bitsPerComponent)-bit \(String(describing: image.colorSpace?.model))")
}

// The context draws into the array's own buffer, so it only lives inside
// withUnsafeMutableBytes.
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let drewPixels = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        return false
    }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
guard drewPixels else {
    fail("cannot allocate inspection bitmap")
}

// The background is whatever fills the top-left corner. Every pixel outside
// the safe circle (46% of the canvas, Burly's margin) must match it exactly.
func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
    let offset = (y * width + x) * 4
    return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
}
let background = pixel(0, 0)
let centre = Double(width) / 2
let safeRadius = 0.46 * Double(width)
var markPixelsInside = 0

for y in 0..<height {
    for x in 0..<width {
        let dx = Double(x) + 0.5 - centre
        let dy = Double(y) + 0.5 - centre
        let isBackground = pixel(x, y) == background
        if dx * dx + dy * dy > safeRadius * safeRadius {
            if !isBackground {
                fail("mark pixel outside the safe circle at (\(x), \(y))")
            }
        } else if !isBackground {
            markPixelsInside += 1
        }
    }
}

guard markPixelsInside > 0 else {
    fail("icon is a flat background with no mark")
}

print("app-icon-validator: PASS: \(url.path)")
