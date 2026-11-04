import Foundation

enum Fixture {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("testdata")

    static func floats(_ name: String) throws -> [Float] {
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func maxAbsDiff(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "length mismatch \(a.count) vs \(b.count)")
        return zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }
}
