import Dispatch
import Foundation

/// SIGINT and SIGTERM while a run is in flight: remove the `.part` file and leave with 128 + signal. Nothing else.
///
/// Design (the one this tool uses, so the CLI contract can be reasoned about): the default disposition is replaced by
/// SIG_IGN and a `DispatchSourceSignal` per signal. The source's handler runs on an ordinary global queue, never in
/// signal context, so it may take a lock, call `unlink` and `_exit`; there is no flag that a long model call has to
/// notice, so the latency is the dispatch hop, not "the next window" (a 20 s window takes about 7 s on an Intel Mac).
///
/// The race that matters is the last step. `commit()` is taken under the same lock right before the rename: once it
/// returns the output is about to exist whole, and a later signal is ignored rather than allowed to unlink a file the
/// caller is already publishing. A signal that wins the lock first removes the `.part` and ends the process, so `commit()` never returns.
final class Interrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var part: String?
    private var committed = false
    private var sources: [DispatchSourceSignal] = []

    func install() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler { [self] in
                lock.lock()
                if committed { lock.unlock(); return }
                if let part { unlink(part) }
                lock.unlock()
                _exit(128 + sig)
            }
            source.resume()
            sources.append(source)
        }
    }

    /// From now on a signal removes this path. Call it only after this process created the file (`O_EXCL`), so it can
    /// never delete a `.part` that belongs to someone else.
    func arm(part path: String) {
        lock.lock(); part = path; lock.unlock()
    }

    /// Right before the rename. A signal that took the lock first has already unlinked the `.part` and ended the
    /// process, so this is never reached; one that arrives afterwards is ignored.
    func commit() {
        lock.lock(); committed = true; lock.unlock()
    }

    /// The publish failed after `commit()`: signals count again and the path is gone.
    func disarm() {
        lock.lock(); part = nil; committed = false; lock.unlock()
    }
}
