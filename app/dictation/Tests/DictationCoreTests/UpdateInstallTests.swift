import XCTest
@testable import DictationCore

final class UpdateInstallTests: XCTestCase {
    func testDownloadIsAStandaloneCurlWithItsOwnExitStatus() {
        let argv = UpdateInstaller.downloadCommand(to: "/tmp/x.sh")
        XCTAssertEqual(argv.first, "/usr/bin/curl")
        XCTAssertTrue(argv[1].contains("f"), "curl must fail on HTTP errors")
        XCTAssertEqual(Array(argv.suffix(3)), ["-o", "/tmp/x.sh", UpdateInstaller.scriptURL])
    }

    func testNoCommandIsAShellPipeline() {
        let all = UpdateInstaller.downloadCommand(to: "/tmp/x.sh") + UpdateInstaller.installCommand(script: "/tmp/x.sh", tag: "v1.2.3")
        for arg in all {
            XCTAssertFalse(arg.contains("|"), "a pipe hides curl's exit status: \(arg)")
        }
        XCTAssertFalse(all.contains("-c"), "no sh -c script string")
    }

    func testInstallRunsTheFileNotStdinAndPinsTheTag() {
        XCTAssertEqual(UpdateInstaller.installCommand(script: "/tmp/x.sh", tag: "v0.1.21"),
                       ["/bin/sh", "/tmp/x.sh", "--version", "v0.1.21"])
    }

    func testScriptCheck() {
        XCTAssertTrue(UpdateInstaller.isScript(head: Data("#!/bin/sh\necho".utf8)))
        XCTAssertFalse(UpdateInstaller.isScript(head: Data()))
        XCTAssertFalse(UpdateInstaller.isScript(head: Data("<html>404".utf8)))
    }

    func testVersionMatchIgnoresTheVPrefix() {
        XCTAssertNil(UpdateInstaller.verifyInstalled(version: "0.1.21", target: "v0.1.21"))
        XCTAssertNil(UpdateInstaller.verifyInstalled(version: "v0.1.21", target: "0.1.21"))
    }

    func testUnchangedVersionIsAFailureNamingBothVersions() {
        let f = UpdateInstaller.verifyInstalled(version: "0.1.20", target: "v0.1.21")
        XCTAssertEqual(f, .versionUnchanged(expected: "v0.1.21", found: "0.1.20"))
        XCTAssertEqual(f?.message, "The version did not change: expected v0.1.21 after the install, found v0.1.20.")
    }

    func testUnreadableInstalledVersionIsAFailure() {
        XCTAssertEqual(UpdateInstaller.verifyInstalled(version: nil, target: "v0.1.21"),
                       .versionUnchanged(expected: "v0.1.21", found: nil))
    }

    func testFailureMessages() {
        XCTAssertEqual(UpdateInstaller.Failure.downloadFailed(status: 22).message,
                       "Downloading the installer failed (curl exited with status 22).")
        XCTAssertEqual(UpdateInstaller.Failure.installerFailed(status: 1).message, "The installer exited with status 1.")
        XCTAssertEqual(UpdateInstaller.Failure.couldNotStart("no such file").message, "The installer could not start: no such file.")
    }

    func testCheckIsRefusedWhileInstalling() {
        XCTAssertEqual(UpdateGate.decide(installing: true), .installInProgress)
        XCTAssertEqual(UpdateGate.decide(installing: false), .proceed)
    }
}
