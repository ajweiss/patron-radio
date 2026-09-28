import Foundation
import Testing

/// Test vectors shared with the Plasma widget's C++ tests (`tests/data/` at the
/// repo root), so both implementations are held to one set of rules.
enum SharedVectors {
    /// The repository root, found from this file's location
    /// (macos/Tests/PatronRadioCoreTests/SharedVectors.swift).
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PatronRadioCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // macos
        .deletingLastPathComponent()

    struct EntityCase: Decodable, CustomTestStringConvertible, Sendable {
        let name: String
        let input: String
        let expected: String
        var testDescription: String { name }
    }

    struct GainCase: Decodable, CustomTestStringConvertible, Sendable {
        let name: String
        let measured: Double
        let target: Double
        let gain: Double
        var testDescription: String { name }
    }

    private struct File<Case: Decodable>: Decodable { let cases: [Case] }

    static func load<Case: Decodable>(_ name: String, as: Case.Type = Case.self) -> [Case] {
        let url = repoRoot.appendingPathComponent("tests/data/\(name)")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File<Case>.self, from: data) else { return [] }
        return file.cases
    }

    static let htmlEntities: [EntityCase] = load("html_entities.json")
    static let loudnessGain: [GainCase] = load("loudness_gain.json")
}
