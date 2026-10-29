import Foundation
import XCTest

/// Repo-wide drift guard (#333): an English string literal handed straight to a user-facing sink in the app sources
/// reaches a Russian user as English. The words of every alert, button, menu row, file panel, pill and notice come from
/// `L10nKey` (or from a DictationCore helper that resolves one). The scan reads `app/dictation/Sources/**` as text.
/// An error's own description is the same leak (#337, #346): `String(describing: error)`, `"\(error)"` and
/// `error.localizedDescription` handed to a sink show the app's English log text (or a system reason), so they are
/// findings too, as is a bare variable bound to either an English literal or such a description before the sink.
final class UserFacingLiteralGuardTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources")

    /// Literals that may stay English, one reason each. Key: `<path under Sources>: <literal text, interpolations removed>`.
    /// A call whose literal is not here is a finding; an entry that matches nothing fails `testTheAllowlistHasNoStaleEntry`.
    static let allowlist: [String: String] = [
        "OxSayDictation/AppDelegate.swift: q": "the Cmd+Q key equivalent of the Quit row, not text",
        "OxSayDictation/Overlay.swift: esc": "the Esc key cap on the pill; macOS Russian labels the key esc too",
        "OxSayDictation/AppDelegate.swift: .localizedDescription": "the macOS sign-in error (SMAppService), worded by the system in the user's language, inside the localized noticeLoginFailed sentence",
        "DictationCore/DictationController.swift: .localizedDescription": "the AVFoundation recorder error, worded by the system in the user's language, inside the localized noticeRecordFailed sentence",
    ]

    struct Finding: Equatable, CustomStringConvertible {
        var file: String
        var line: Int
        var literal: String
        var sink: String
        var description: String { "\(file):\(line) \(sink) <- \"\(literal)\"" }
        var key: String { "\(file): \(literal)" }
    }

    // MARK: scanner

    /// One string literal: scalar offsets of its quotes, and its text with every `\( … )` removed.
    struct Literal { var start: Int; var end: Int; var text: String }

    /// The source with comments blanked and every top-level string literal replaced by U+0001 (so a bracket or a keyword
    /// inside a string never confuses the sink search), plus every literal found, nested ones included.
    static func skeleton(_ source: String) -> (code: [Unicode.Scalar], literals: [Literal]) {
        let (code, literals, _) = skeletonAndText(source)
        return (code, literals)
    }

    /// `skeleton`, plus the source with only its comments blanked (strings intact): what the error-description scan reads.
    static func skeletonAndText(_ source: String) -> (code: [Unicode.Scalar], literals: [Literal], text: [Unicode.Scalar]) {
        let s = Array(source.unicodeScalars)
        var code = s
        var literals: [Literal] = []
        func blank(_ from: Int, _ to: Int) { for k in from..<to where code[k] != "\n" { code[k] = "\u{1}" } }

        /// `i` is at an opening quote. Returns the index after the closing quote.
        func string(_ i: Int) -> Int {
            var j = i
            var hashes = 0
            while j > 0, s[j - 1] == "#" { hashes += 1; j -= 1 }
            let triple = i + 2 < s.count && s[i + 1] == "\"" && s[i + 2] == "\""
            var k = i + (triple ? 3 : 1)
            var text = String.UnicodeScalarView()
            let closer = "\"" + String(repeating: "#", count: hashes)
            while k < s.count {
                if s[k] == "\\" , hashes == 0 || (k + hashes < s.count && s[(k + 1)...(k + hashes)].allSatisfy { $0 == "#" }) {
                    let after = k + 1 + hashes
                    if after < s.count, s[after] == "(" {
                        k = interpolation(after)
                        continue
                    }
                    k = after + 1
                    continue
                }
                let ahead = String(String.UnicodeScalarView(s[k..<min(s.count, k + closer.unicodeScalars.count + (triple ? 2 : 0))]))
                let end = triple ? "\"\"\"" + String(repeating: "#", count: hashes) : closer
                if ahead.hasPrefix(end) {
                    let after = k + end.unicodeScalars.count
                    literals.append(Literal(start: i, end: after, text: String(text)))
                    return after
                }
                text.append(s[k])
                k += 1
            }
            return s.count
        }
        /// `i` is at the `(` of `\(`. Returns the index after the matching `)`.
        func interpolation(_ i: Int) -> Int {
            var depth = 0
            var k = i
            while k < s.count {
                if s[k] == "\"" { k = string(k); continue }
                if s[k] == "(" { depth += 1 }
                if s[k] == ")" { depth -= 1; if depth == 0 { return k + 1 } }
                k += 1
            }
            return s.count
        }

        var i = 0
        while i < s.count {
            if s[i] == "/", i + 1 < s.count, s[i + 1] == "/" {
                var k = i
                while k < s.count, s[k] != "\n" { code[k] = " "; k += 1 }
                i = k
            } else if s[i] == "/", i + 1 < s.count, s[i + 1] == "*" {
                var k = i, depth = 0
                while k < s.count {
                    if s[k] == "/", k + 1 < s.count, s[k + 1] == "*" { depth += 1; code[k] = " "; code[k + 1] = " "; k += 2; continue }
                    if s[k] == "*", k + 1 < s.count, s[k + 1] == "/" { depth -= 1; code[k] = " "; code[k + 1] = " "; k += 2; if depth == 0 { break }; continue }
                    if s[k] != "\n" { code[k] = " " }
                    k += 1
                }
                i = k
            } else if s[i] == "\"" {
                let end = string(i)
                blank(i, end)
                i = end
            } else {
                i += 1
            }
        }
        var text = s
        for k in 0..<s.count where code[k] == " " && s[k] != " " { text[k] = " " }
        return (code, literals, text)
    }

    private static let callSink = try! NSRegularExpression(
        pattern: #"(?<!func )(?<![\w.])(?:self\.)?notice\(|(?<!func )(?<![\w])(?:\w+\.)*(?:showMessage|leaveMessage|setWorkingText|runAlert|addButton|addItem|submenuItem|alert|pill|notify|onError|onNotice|disabled|header|end|setAccessibilityLabel|setAccessibilityTitle|setAccessibilityHelp)\??\(|(?<![\w])\.item\((?=title:)|(?<![\w])Item\((?=title:)|(?<![\w])NSTextField\(|(?<![\w.])(?:NSMenuItem|NSButton|NSMenu|UpdateDialog)\("#)
    private static let describingError = try! NSRegularExpression(
        pattern: #"String\((?:describing|reflecting):|\.localizedDescription\b|\\\((?:error|err|e|failure)\)|\b(?:error|err|failure)\.description\b"#)
    private static let funcKeyword = try! NSRegularExpression(pattern: #"\bfunc\s"#)
    private static let assignSink = try! NSRegularExpression(pattern: #"\.(?:messageText|informativeText|message|title)\s=\s(?!=)|\.(?:placeholderString|toolTip|stringValue|accessibilityLabel|accessibilityTitle|accessibilityHelp)\s=\s(?!=)|\bstatic let \w*(?:Title|Text|Header)\s=\s"#)

    /// Every English literal handed directly to a sink in `source`.
    static func findings(in source: String, file: String) -> [Finding] {
        let (code, literals, plain) = skeletonAndText(source)
        let text = String(String.UnicodeScalarView(code))
        let ns = text as NSString
        // Offsets are in scalars; the regex works in UTF-16. Map by walking once.
        var utf16ToScalar: [Int] = []
        for (k, scalar) in code.enumerated() { utf16ToScalar.append(contentsOf: Array(repeating: k, count: scalar.utf16.count)) }
        utf16ToScalar.append(code.count)
        func scalarIndex(_ u: Int) -> Int { utf16ToScalar[min(u, utf16ToScalar.count - 1)] }
        var lineStarts = [0]
        for (k, c) in code.enumerated() where c == "\n" { lineStarts.append(k + 1) }
        func line(_ offset: Int) -> Int { lineStarts.lastIndex(where: { $0 <= offset })! + 1 }

        var out: [Finding] = []
        func collect(_ range: Range<Int>, sink: String) {
            for literal in literals where literal.start >= range.lowerBound && literal.end <= range.upperBound {
                guard literal.text.range(of: "[A-Za-z]", options: .regularExpression) != nil else { continue }
                out.append(Finding(file: file, line: line(literal.start), literal: literal.text, sink: sink))
            }
        }
        /// An error's own words inside a sink: `String(describing:)`, `"\(error)"`, `.localizedDescription`.
        func describing(_ range: Range<Int>, sink: String) {
            let part = String(String.UnicodeScalarView(plain[range])) as NSString
            for m in describingError.matches(in: part as String, range: NSRange(location: 0, length: part.length)) {
                let before = part.substring(to: m.range.location)
                let breaks = before.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
                out.append(Finding(file: file, line: line(range.lowerBound) + breaks, literal: part.substring(with: m.range), sink: sink))
            }
        }
        /// A bare identifier argument: look up its nearest `let`/`var` in the same function and scan the initializer.
        func bound(_ argument: String, before sinkStart: Int, sink: String) {
            let name = argument.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"^\w+:\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "self.", with: "")
            guard name.range(of: #"^[a-z_]\w*$"#, options: .regularExpression) != nil else { return }
            var floor = 0
            for m in funcKeyword.matches(in: text, range: all) { let at = scalarIndex(m.range.location); if at < sinkStart { floor = at } }
            let binding = try! NSRegularExpression(pattern: #"\b(?:let|var)\s+"# + name + #"\b[^=\n]*=(?!=)\s*"#)
            guard let m = binding.matches(in: text, range: all).last(where: {
                let at = scalarIndex($0.range.location); return at > floor && at < sinkStart
            }) else { return }
            let from = scalarIndex(m.range.location + m.range.length)
            var depth = 0, k = from
            while k < code.count {
                let c = code[k]
                if c == "(" || c == "{" || c == "[" { depth += 1 }
                if c == ")" || c == "}" || c == "]" { depth -= 1 }
                if c == "\n", depth <= 0 {
                    var n = k - 1
                    while n > from, code[n] == " " { n -= 1 }
                    let tail = code[n]
                    var m2 = k + 1
                    while m2 < code.count, code[m2] == " " { m2 += 1 }
                    let lead = m2 < code.count ? code[m2] : "x"
                    if tail != "?" && tail != ":" && lead != "?" && lead != ":" { break }
                }
                k += 1
            }
            collect(from..<k, sink: sink + " via " + name)
            describing(from..<k, sink: sink + " via " + name)
        }
        let all = NSRange(location: 0, length: ns.length)
        for m in callSink.matches(in: text, range: all) {
            let open = scalarIndex(m.range.location + m.range.length) - 1
            guard open >= 0, code[open] == "(" else { continue }
            var depth = 0, k = open
            while k < code.count {
                if code[k] == "(" { depth += 1 }
                if code[k] == ")" { depth -= 1; if depth == 0 { break } }
                k += 1
            }
            let name = ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: "("))
            collect(open..<min(k + 1, code.count), sink: name)
            describing(open..<min(k + 1, code.count), sink: name)
            // Top-level arguments that are a bare identifier.
            var argStart = open + 1, nest = 0, j = open + 1
            while j <= min(k, code.count - 1) {
                let c = code[j]
                if c == "(" || c == "[" || c == "{" { nest += 1 }
                if c == ")" || c == "]" || c == "}" { nest -= 1 }
                if (c == "," && nest == 0) || nest < 0 {
                    bound(String(String.UnicodeScalarView(code[argStart..<j])), before: open, sink: name)
                    argStart = j + 1
                }
                j += 1
            }
        }
        for m in assignSink.matches(in: text, range: all) {
            let from = scalarIndex(m.range.location + m.range.length)
            var depth = 0, k = from
            while k < code.count {
                let c = code[k]
                if c == "(" || c == "{" || c == "[" { depth += 1 }
                if c == ")" || c == "}" || c == "]" { depth -= 1 }
                if c == "\n", depth <= 0 { break }
                k += 1
            }
            let name = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            collect(from..<k, sink: name)
            describing(from..<k, sink: name)
            bound(String(String.UnicodeScalarView(code[from..<k])), before: from, sink: name)
        }
        return out
    }

    static func sourceFiles() -> [(path: String, text: String)] {
        let root = sources.standardizedFileURL
        var files: [(String, String)] = []
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            if let text = try? String(contentsOf: url, encoding: .utf8) { files.append((relative, text)) }
        }
        return files.sorted { $0.0 < $1.0 }
    }

    // MARK: the guard

    /// RED today on main: the Studio flow, the status menu and the notices still pass English literals. Mutation: put
    /// `"Stop Voiceover"` back in StudioController.stopVoiceover's host.alert call -> RED here.
    func testNoEnglishLiteralReachesAUserFacingSink() {
        let files = Self.sourceFiles()
        XCTAssertGreaterThan(files.count, 60, "the scan found the app sources")
        var found: [Finding] = []
        for (path, text) in files { found += Self.findings(in: text, file: path) }
        let unlisted = found.filter { Self.allowlist[$0.key] == nil }
        XCTAssertTrue(unlisted.isEmpty, "English literals at user-facing sinks (use an L10nKey, or allowlist with a reason): "
                      + unlisted.map(\.description).joined(separator: " | "))
    }

    func testTheAllowlistHasNoStaleEntry() {
        var seen = Set<String>()
        for (path, text) in Self.sourceFiles() { for f in Self.findings(in: text, file: path) { seen.insert(f.key) } }
        for (key, reason) in Self.allowlist {
            XCTAssertTrue(seen.contains(key), "allowlist entry \(key) matches nothing; drop it")
            XCTAssertFalse(reason.isEmpty, "allowlist entry \(key) needs a reason")
        }
    }

    // MARK: the scanner itself

    func testTheScannerFlagsEachSinkKind() {
        let sample = """
        let a = NSAlert()
        a.messageText = "Something broke"
        a.informativeText = isBig ? "Big" : L10nKey.x.text
        a.addButton(withTitle: "Keep Going")
        let i = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "")
        panel.title = "Choose a file"
        panel.message = "Pick one"
        overlay.showMessage(problem ?? "Nothing selected")
        notice("\\(key.title) is taken")
        host.alert("Oops", "Try again", ["OK"])
        host.pill(task, "Reading…")
        overlay.setWorkingText("Speaking…")
        statusLine.title = lastNotice ?? active.map { key in
            "Hold \\(key)"
        } ?? "Idle"
        let d = UpdateDialog(title: "Stop it?", text: "Really stop", buttons: ["Yes please", "No thanks"])
        field.stringValue = "Hello there"
        let m = NSMenu(title: "Voices")
        panel.setAccessibilityLabel("Recording now")
        view.setAccessibilityHelp("Press to stop")
        view.accessibilityLabel = "Level meter"
        """
        let hits = Self.findings(in: sample, file: "t.swift").map(\.literal)
        for want in ["Something broke", "Big", "Keep Going", "Quit", "Choose a file", "Pick one", "Nothing selected", " is taken",
                     "Oops", "Try again", "OK", "Reading…", "Speaking…", "Hold ", "Idle",
                     "Stop it?", "Really stop", "Yes please", "No thanks", "Hello there", "Voices", "Recording now", "Press to stop",
                     "Level meter"] {
            XCTAssertTrue(hits.contains(want), "missed \(want) in \(hits)")
        }
    }

    /// An English-describing error is as bad as a literal (#337, #346.4): one case per spelling and per sink kind.
    /// Mutation: findings(in:), delete the `describing(open..<…)` call in the call-sink loop -> RED.
    func testTheScannerFlagsAnErrorsOwnWordsAtASink() {
        let sample = """
        notice(String(describing: error))
        notice("\\(error)")
        overlay.showMessage(error.localizedDescription)
        onError?(String(describing: e))
        notice(String(reflecting: failure))
        overlay.showMessage(failure.description)
        a.informativeText = error.localizedDescription
        host.alert("\\(title)", String(describing: err), [])
        notice(L10nKey.noticeLoginFailed.text(error.localizedDescription))
        self.notice(String(describing: error))
        """
        let hits = Self.findings(in: sample, file: "t.swift")
        let lines = Set(hits.map(\.line))
        for want in 1...10 { XCTAssertTrue(lines.contains(want), "line \(want) not flagged: \(hits)") }
    }

    /// A literal or a description bound to a variable and handed to a sink later is the same leak (#337).
    /// Mutation: findings(in:), delete the `bound(...)` call in the call-sink loop -> RED.
    func testTheScannerFollowsAVariableBoundBeforeTheSink() {
        let sample = """
        func a() {
            let message = "Could not start"
            notice(message)
        }
        func b() {
            let reason = String(describing: error)
            overlay.showMessage(reason)
        }
        func c() {
            let line = ok ? L10nKey.a.text
                : "Plain English"
            notice(line, kind: .outcome)
        }
        func d() {
            var title = "Tail"
            panel.title = title
        }
        """
        let hits = Self.findings(in: sample, file: "t.swift")
        for want in ["Could not start", "String(describing:", "Plain English", "Tail"] {
            XCTAssertTrue(hits.contains { $0.literal == want && $0.sink.contains(" via ") }, "missed \(want) in \(hits)")
        }
    }

    func testTheScannerIgnoresAVariableThatHoldsLocalizedText() {
        let sample = """
        func a() {
            let message = L10nKey.hello.text
            notice(message)
        }
        func b() {
            let failure = "English"
        }
        func c() {
            notice(failure)
        }
        func d(_ message: String) {
            notice(message)
        }
        func e() {
            let text = String(format: L10nKey.x.text, "1")
            overlay.showMessage(text)
        }
        """
        XCTAssertEqual(Self.findings(in: sample, file: "t.swift"), [])
    }

    func testTheScannerIgnoresLocalizedTextLogsComments() {
        let sample = """
        a.messageText = L10nKey.title.text
        a.addButton(withTitle: L10nKey.commonOk.text)
        // notice("commented out")
        /* host.alert("block comment", "x", []) */
        timingLog.notice("paste took too long", privacy: .public)
        self.log.notice("also a log line, not a sink")
        func notice(_ message: String, kind: Kind = .unrelated) {}
        notice(.init(message: message, kind: .outcome))
        let s = "host.alert(\\"inside a string\\")"
        notice(L10nKey.updateCheckingPill.text("1.2"))
        item.title = "…"
        log.error("failed: \\(String(describing: error), privacy: .public)")
        let shown = L10nKey.playFailed.text
        notice(shown)
        notice(L10nKey.noticeLoginFailed.text)
        field.stringValue = L10nKey.hello.text
        let d = UpdateDialog(title: text(.a), text: "\\(x) \\(y)", buttons: [text(.commonOk)])
        let menu = NSMenu()
        panel.setAccessibilityLabel(L10nKey.badgeA11yPanel.text)
        view.accessibilityLabel = L10nKey.badgeA11yDot.text
        """
        XCTAssertEqual(Self.findings(in: sample, file: "t.swift"), [])
    }
}
