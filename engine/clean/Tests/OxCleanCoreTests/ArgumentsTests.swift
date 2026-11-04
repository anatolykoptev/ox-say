import Foundation
import XCTest
@testable import OxCleanCore

final class ArgumentsTests: XCTestCase {
    func testArgumentsNeedInputOutputAndModels() throws {
        XCTAssertThrowsError(try Arguments.parse(["a.wav"]))
        XCTAssertEqual(try Arguments.parse(["a.wav", "b.wav", "--models", "/m"]).modelsDir.path, "/m")
        let a = try Arguments.parse(["a.wav", "b.wav", "--models", "/m"])
        XCTAssertEqual(a.input.lastPathComponent, "a.wav")
        XCTAssertEqual(a.output.lastPathComponent, "b.wav")
    }

    // Fix round 6: --models may sit anywhere, `--` ends the options (a file named "-x.wav" needs it), a trailing slash is
    // remembered because URL would drop it. Mutation: Arguments.swift, the `--` branch removed -> the second case is red.
    func testModelsMayComeFirstOrMiddleAndDoubleDashEndsOptions() throws {
        for argv in [["--models", "/m", "a.wav", "b.wav"], ["a.wav", "--models", "/m", "b.wav"], ["a.wav", "b.wav", "--models", "/m"],
                     ["--models", "/m", "--", "a.wav", "b.wav"], ["a.wav", "b.wav", "--models", "/m", "--"]] {
            let a = try Arguments.parse(argv)
            XCTAssertEqual([a.input.lastPathComponent, a.output.lastPathComponent, a.modelsDir.path], ["a.wav", "b.wav", "/m"], "\(argv)")
        }
        let dash = try Arguments.parse(["--models", "/m", "--", "-in.wav", "--out.wav"])
        XCTAssertEqual([dash.input.lastPathComponent, dash.output.lastPathComponent], ["-in.wav", "--out.wav"])
        XCTAssertThrowsError(try Arguments.parse(["-in.wav", "b.wav", "--models", "/m"]), "an option-looking name needs `--`")
        XCTAssertThrowsError(try Arguments.parse(["--models", "/m", "--models", "/n", "a.wav", "b.wav"]), "twice")
    }

    // Mutation: Arguments.swift, outputIsDirectoryPath always false -> red.
    func testATrailingSlashOrDotOutputIsRememberedAsADirectoryPath() throws {
        for (out, dir) in [("d/", true), ("d//", true), ("d/.", true), ("d/..", true), (".", true), ("d/o.wav", false), ("d/.hidden", false)] {
            XCTAssertEqual(try Arguments.parse(["a.wav", out, "--models", "/m"]).outputIsDirectoryPath, dir, out)
        }
    }

    func testAnythingButTheExactShapeIsUsage() {
        for argv in [
            [], ["a.wav", "b.wav"], ["a.wav", "b.wav", "--models"],             ["a.wav", "b.wav", "--model", "/m"], ["a.wav", "b.wav", "--models", "/m", "extra"],
            ["", "b.wav", "--models", "/m"], ["a.wav", "", "--models", "/m"], ["a.wav", "b.wav", "--models", ""],
            ["--version"],
        ] {
            XCTAssertThrowsError(try Arguments.parse(argv), "\(argv)") { err in
                guard case Arguments.Failure.usage(let line)? = err as? Arguments.Failure else { return XCTFail("\(err)") }
                XCTAssertTrue(line.hasPrefix("usage: ox-clean"))
            }
        }
    }
}
