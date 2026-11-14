// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@Suite("Energy engine isolation")
struct FLEnergyCoreTests {
    @Test("engine has no package dependencies or health and activity inputs")
    func moduleGraph() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(contentsOf: package.appendingPathComponent("Package.swift"), encoding: .utf8)
        let declaration = try #require(manifest.range(of: #"\.target\(name: "FLEnergyCore"[^)]*\)"#, options: .regularExpression))
        #expect(String(manifest[declaration]) == #".target(name: "FLEnergyCore")"#)
        let source = package.appendingPathComponent("Sources/FLEnergyCore")
        let files = try #require(FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil))
        var checked = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            checked += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: .newlines) {
                let code = line.components(separatedBy: "//")[0]
                if code.contains("import ") { #expect(code.trimmingCharacters(in: .whitespaces) == "import Foundation") }
                #expect(code.range(of: #"\b(HK\w*|HealthKit|\w*[Ww]orkout\w*|\w*[Aa]ctivity\w*)\b"#, options: .regularExpression) == nil)
            }
        }
        #expect(checked > 0)
    }
}
