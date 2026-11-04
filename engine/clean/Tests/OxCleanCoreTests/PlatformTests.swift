import Foundation
import XCTest
@testable import OxCleanCore

final class PlatformTests: XCTestCase {
    override func tearDown() { unsetenv("OX_CLEAN_ASSUME_MACOS") }

    // Mutation: Platform.swift `minimumMajor = 15` -> 13 turns this red.
    func testMacOSBelowFifteenIsRefusedByTheGate() {
        setenv("OX_CLEAN_ASSUME_MACOS", "14", 1)
        XCTAssertFalse(Platform.supported())
        XCTAssertEqual(Platform.osMajor(), 14)
        XCTAssertEqual(Platform.refusal(), "ox-clean needs macOS 15 or later; this is macOS 14")
    }

    func testTheAssumeKnobCanOnlyLowerTheVersion() {
        let real = OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 0)
        func eff(_ s: String?) -> OperatingSystemVersion { Platform.effectiveVersion(real: real, assume: s) }
        XCTAssertEqual(eff("99").majorVersion, 15)
        XCTAssertEqual(eff("15.3").minorVersion, 2)
        XCTAssertEqual(eff("14.8.1").majorVersion, 14)
        XCTAssertEqual(eff("14.8.1").patchVersion, 1)
        for junk in ["", "abc", "14.x", "-1", "14.-2", "1.2.3.4", "14..1", ".", nil] as [String?] {
            XCTAssertEqual(eff(junk).majorVersion, 15, "\(junk ?? "nil") must be ignored")
        }
    }

    func testAnUnsetKnobLeavesThisMacSupportedOrNot() {
        unsetenv("OX_CLEAN_ASSUME_MACOS")
        XCTAssertEqual(Platform.supported(), ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15)
    }

    func testExitCodesAreTheDocumentedNumbers() {
        XCTAssertEqual([ExitCode.ok, .failure, .usage, .models, .input, .unsupportedOS].map(\.rawValue), [0, 1, 2, 3, 4, 5])
    }

    func testTheVersionLineNamesTheModelPin() {
        XCTAssertEqual(Pins.modelsRevision.count, 40)
        XCTAssertEqual(Pins.version, "ox-clean 1 (model da0d6b45)")
    }
}
