#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks the committed app icons: the generator is deterministic, both
# committed copies match a fresh generation, every copy passes the validator,
# and the validator rejects icons it should reject.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$REPO_ROOT/Scripts/generate-app-icon.swift"
VALIDATOR="$REPO_ROOT/Scripts/validate-app-icon.swift"
PHONE_ICON="$REPO_ROOT/FreeLunchPhone/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
WATCH_ICON="$REPO_ROOT/FreeLunchWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
TEST_DIR="$(mktemp -d -t free-lunch-app-icon-test)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  echo "app-icon-test: FAIL: $*" >&2
  exit 1
}

[[ -f "$GENERATOR" ]] || fail "missing generator: $GENERATOR"
[[ -f "$VALIDATOR" ]] || fail "missing validator: $VALIDATOR"
[[ -f "$PHONE_ICON" ]] || fail "missing iPhone icon: $PHONE_ICON"
[[ -f "$WATCH_ICON" ]] || fail "missing Watch icon: $WATCH_ICON"

for set_dir in "$(dirname "$PHONE_ICON")" "$(dirname "$WATCH_ICON")"; do
  grep -q '"filename" : "AppIcon.png"' "$set_dir/Contents.json" \
    || fail "$set_dir/Contents.json does not name AppIcon.png"
done

swift "$GENERATOR" "$TEST_DIR/first.png"
swift "$GENERATOR" "$TEST_DIR/second.png"

# On a byte mismatch, report how many decoded pixels differ, which separates
# a real drawing change from a PNG encoder difference between macOS versions.
describe_pixel_difference() {
  swift - "$1" "$2" <<'SWIFT' || true
import CoreGraphics
import Foundation
import ImageIO

func rgba(_ path: String) -> [UInt8]? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == 1024, image.height == 1024 else { return nil }
    var pixels = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
    let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: 1024, height: 1024, bitsPerComponent: 8,
            bytesPerRow: 1024 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        return true
    }
    return drew ? pixels : nil
}

guard let fresh = rgba(CommandLine.arguments[1]),
      let committed = rgba(CommandLine.arguments[2]) else {
    print("app-icon-test: cannot decode both images as 1024x1024")
    exit(0)
}
var differing = 0
for index in stride(from: 0, to: fresh.count, by: 4)
    where fresh[index..<index + 3] != committed[index..<index + 3] {
    differing += 1
}
print("app-icon-test: \(differing) of \(1024 * 1024) decoded pixels differ")
SWIFT
}

check_same() {
  local label="$1"
  local fresh="$2"
  local other="$3"
  if ! cmp -s "$fresh" "$other"; then
    describe_pixel_difference "$fresh" "$other"
    fail "$label"
  fi
}

check_same "two fresh generations differ" \
  "$TEST_DIR/first.png" "$TEST_DIR/second.png"
check_same "iPhone AppIcon.png is stale; regenerate it with Scripts/generate-app-icon.swift" \
  "$TEST_DIR/first.png" "$PHONE_ICON"
check_same "Watch AppIcon.png is stale; regenerate it with Scripts/generate-app-icon.swift" \
  "$TEST_DIR/first.png" "$WATCH_ICON"

for icon in "$TEST_DIR/first.png" "$PHONE_ICON" "$WATCH_ICON"; do
  swift "$VALIDATOR" "$icon"
  file "$icon" | grep -q 'PNG image data, 1024 x 1024, 8-bit/color RGB,' \
    || fail "$icon is not a 1024x1024 8-bit RGB PNG"
done

# Fixtures the validator must reject, each derived from the fresh icon.
swift - "$TEST_DIR/first.png" "$TEST_DIR" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputDirectory = CommandLine.arguments[2]
guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let icon = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Could not read fixture source")
}

func write(_ name: String, size: Int, alpha: CGImageAlphaInfo, draw: (CGContext) -> Void) {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: alpha.rawValue
    ) else {
        fatalError("Could not prepare fixture \(name)")
    }
    draw(context)
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(name)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL,
              "public.png" as CFString,
              1,
              nil
          ) else {
        fatalError("Could not create fixture \(name)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write fixture \(name)")
    }
}

let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)

// A transparent corner makes sure the encoder keeps the alpha channel.
write("with-alpha.png", size: 1024, alpha: .premultipliedLast) { context in
    context.draw(icon, in: full)
    context.clear(CGRect(x: 0, y: 0, width: 8, height: 8))
}
write("wrong-size.png", size: 512, alpha: .noneSkipLast) { context in
    context.draw(icon, in: CGRect(x: 0, y: 0, width: 512, height: 512))
}
// A dark patch near the bottom-right corner, well outside the safe circle.
write("outside-safe-circle.png", size: 1024, alpha: .noneSkipLast) { context in
    context.draw(icon, in: full)
    context.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
    context.fill(CGRect(x: 900, y: 40, width: 40, height: 40))
}
// The icon's top-left background pixel stretched over the whole canvas.
write("no-mark.png", size: 1024, alpha: .noneSkipLast) { context in
    guard let corner = icon.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)) else {
        fatalError("Could not crop the background pixel")
    }
    context.interpolationQuality = .none
    context.draw(corner, in: full)
}
SWIFT

expect_rejection() {
  local fixture="$TEST_DIR/$1"
  local expected="$2"
  local log="$fixture.log"
  if swift "$VALIDATOR" "$fixture" >"$log" 2>&1; then
    fail "validator accepted $1"
  fi
  grep -q "FAIL: $expected" "$log" \
    || { cat "$log" >&2; fail "validator rejected $1 for the wrong reason"; }
  echo "app-icon-test: validator rejects $1 as expected"
}

expect_rejection with-alpha.png 'alpha channel is not allowed'
expect_rejection wrong-size.png 'expected 1024x1024, got 512x512'
expect_rejection outside-safe-circle.png 'mark pixel outside the safe circle'
expect_rejection no-mark.png 'icon is a flat background with no mark'

echo "app-icon-test: PASS"
