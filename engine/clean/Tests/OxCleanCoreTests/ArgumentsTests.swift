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

    func testAnythingButTheExactShapeIsUsage() {
        for argv in [
            [], ["a.wav", "b.wav"], ["a.wav", "b.wav", "--models"], ["a.wav", "--models", "/m", "b.wav"],
            ["a.wav", "b.wav", "--model", "/m"], ["a.wav", "b.wav", "--models", "/m", "extra"],
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
