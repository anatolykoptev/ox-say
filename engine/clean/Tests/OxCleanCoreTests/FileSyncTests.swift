import Foundation
import XCTest
@testable import OxCleanCore

final class FileSyncTests: XCTestCase {
    /// A sync call that fails with `error` (or succeeds on nil) and records that it ran.
    private final class Call {
        let error: Int32?
        var ran = false
        init(_ error: Int32?) { self.error = error }
        func run(_ fd: Int32) -> Int32 {
            ran = true
            guard let error else { return 0 }
            errno = error
            return -1
        }
    }

    func testAFullSyncThatWorksNeedsNoFallback() {
        let full = Call(nil), plain = Call(nil)
        XCTAssertNil(FileSync.durably(0, full: full.run, plain: plain.run))
        XCTAssertFalse(plain.ran)
    }

    /// A volume that does not implement F_FULLFSYNC (exFAT, some network shares) falls back to fsync.
    func testAVolumeWithoutFullSyncFallsBackToPlainFsync() {
        for unsupported in [ENOTSUP, EINVAL] {
            let full = Call(unsupported), plain = Call(nil)
            XCTAssertNil(FileSync.durably(0, full: full.run, plain: plain.run), "errno \(unsupported)")
            XCTAssertTrue(plain.ran, "errno \(unsupported)")
        }
        // ... and the fallback's own failure is the error reported.
        let full = Call(ENOTSUP), plain = Call(EIO)
        XCTAssertEqual(FileSync.durably(0, full: full.run, plain: plain.run), EIO)
    }

    /// #498: a real I/O error from F_FULLFSYNC must not be masked by a plain fsync that then returns 0 — the copy would
    /// be published although the drive reported a failed flush.
    /// Mutation: FileSync.durably, the `unsupported` check dropped (any failure falls back) -> RED.
    func testARealIOErrorFromFullSyncIsNotMaskedByTheFallback() {
        for failure in [EIO, ENOSPC, EBADF] {
            let full = Call(failure), plain = Call(nil)
            XCTAssertEqual(FileSync.durably(0, full: full.run, plain: plain.run), failure, "errno \(failure)")
            XCTAssertFalse(plain.ran, "errno \(failure): no fallback over a real failure")
        }
    }
}
