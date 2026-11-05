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

extension Fixture {
    static func mse(_ a: [Float], _ b: [Float]) -> Double {
        precondition(a.count == b.count, "length mismatch \(a.count) vs \(b.count)")
        var s = 0.0
        for i in 0..<a.count { let d = Double(a[i]) - Double(b[i]); s += d * d }
        return s / Double(max(a.count, 1))
    }

    /// Scale-invariant SDR in dB of `est` against `ref`, both mean-removed (convert/metrics.py `si_sdr`).
    static func siSdr(_ est: [Float], _ ref: [Float]) -> Double {
        precondition(est.count == ref.count, "length mismatch \(est.count) vs \(ref.count)")
        let n = Double(est.count)
        let me = est.reduce(0.0) { $0 + Double($1) } / n, mr = ref.reduce(0.0) { $0 + Double($1) } / n
        var er = 0.0, rr = 0.0
        for i in 0..<est.count { er += (Double(est[i]) - me) * (Double(ref[i]) - mr); rr += (Double(ref[i]) - mr) * (Double(ref[i]) - mr) }
        let a = er / (rr + 1e-12)
        var tt = 0.0, ee = 0.0
        for i in 0..<est.count {
            let t = a * (Double(ref[i]) - mr), e = (Double(est[i]) - me) - t
            tt += t * t; ee += e * e
        }
        return 10 * log10((tt + 1e-12) / (ee + 1e-12))
    }
}
