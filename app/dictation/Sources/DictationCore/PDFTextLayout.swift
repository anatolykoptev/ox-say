import Foundation

/// Turns the text PDFKit reads page by page into paragraphs. A PDF stores lines,
/// not paragraphs, so the paragraph ends are inferred; the running header and
/// footer, page numbers and hyphenated line breaks are layout, not speech.
enum PDFTextLayout {
    /// Fewer pages cannot show a line that repeats.
    static let minPagesForRunningLines = 2
    /// A running header or footer is among the first or last lines of a page.
    static let edgeLinesPerPageEnd = 2
    /// Only a page with clearly more lines than its two edge windows can have a
    /// running header or footer: on a shorter page every line is an edge, and a
    /// repeated verse, refrain or list item would be taken for one.
    static let minLinesForRunningLines = 2 * edgeLinesPerPageEnd + 2
    /// On a page without blank lines, a line shorter than this share of the usual
    /// line length ends its paragraph (a wrapped line runs to the right margin).
    static let shortLineRatio = 0.7
    /// "The usual line length": this share of the page's lines are not longer.
    static let usualLengthPercentile = 0.9
    /// A page number is at most this many digits (a four-digit line is a year).
    static let maxPageNumberDigits = 3
    /// A bare number at the edge of a page is dropped as a page number only when at
    /// least this many pages show one at the same edge, going on as the pages do:
    /// one such line alone is as likely to be the last word of the page ("Serves" / "4").
    static let minPagesForPageNumbers = 2

    private static let terminalPunctuation = Set(".!?…»”\"')")
    private static let pageNumber = try! NSRegularExpression(
        pattern: #"^(?:(?:page|p\.?|стр\.?|страница|с\.)\s*)?(?:[-–—]\s*)?[0-9]{1,\#(maxPageNumberDigits)}(?:\s*[-–—])?(?:\s*(?:of|/|из)\s*[0-9]{1,\#(maxPageNumberDigits)})?$"#,
        options: .caseInsensitive)

    /// `pages` hold normalised text (line breaks are "\n"). Paragraphs are
    /// separated by one blank line.
    static func paragraphs(_ pages: [String]) -> String {
        let lines = dropPageNumbers(pages.map { page in
            page.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        })
        var out: [String] = []
        for var page in dropRunningLines(lines).map(pageParagraphs) {
            guard !page.isEmpty else { continue }
            if let last = out.last, continues(last, with: page[0]) { out[out.count - 1] = join(last, page.removeFirst()) }
            out += page
        }
        return out.joined(separator: "\n\n")
    }

    static func isPageNumber(_ line: String) -> Bool {
        pageNumber.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private enum Edge: CaseIterable { case top, bottom }

    /// A page number found at the top or bottom of a page.
    private struct Candidate {
        var page: Int
        var line: Int
        var value: Int
    }

    /// The page numbers the pages print at their top or bottom, taken out. A bare
    /// number there is a page number only on evidence: at least
    /// `minPagesForPageNumbers` pages show one at the same edge and the numbers go
    /// on as the pages do (a page of pictures may print none, but then the next
    /// number is still its page's: value minus page index stays the same). A number
    /// that breaks the sequence is text ("the final score was" / "42"), and so is one
    /// that repeats on the next or the previous page: a chapter number opening each
    /// page of its chapter is not a page counter. A PDF of one page keeps what it has
    /// at its edge. Numbering that restarts is a second sequence, judged on its own. A
    /// number anywhere else is text too, and so is one beside another number (a list
    /// of "1", "2", "3" is not three page numbers).
    private static func dropPageNumbers(_ pages: [[String]]) -> [[String]] {
        var dropped = pages.map { _ in Set<Int>() }
        for edge in Edge.allCases {
            let candidates = pages.indices.flatMap { pageNumberCandidates(pages[$0], page: $0, edge: edge) }
            let valueOnPage = Dictionary(candidates.map { ($0.page, $0.value) }, uniquingKeysWith: { first, _ in first })
            let repeats = { (c: Candidate) in valueOnPage[c.page - 1] == c.value || valueOnPage[c.page + 1] == c.value }
            // One pass: the candidates that go on as the pages do share the same value - page.
            let sequences = Dictionary(grouping: candidates.filter { !repeats($0) }, by: { $0.value - $0.page })
            for sequence in sequences.values where sequence.count >= minPagesForPageNumbers {
                for candidate in sequence { dropped[candidate.page].insert(candidate.line) }
            }
        }
        return zip(pages, dropped).map { page, gone in page.indices.filter { !gone.contains($0) }.map { page[$0] } }
    }

    /// The page number at `edge` of one page, if its first or last non-blank line is
    /// one. A page with a single line has it at both edges.
    private static func pageNumberCandidates(_ page: [String], page index: Int, edge: Edge) -> [Candidate] {
        let filled = page.indices.filter { !page[$0].isEmpty }
        guard let line = edge == .top ? filled.first : filled.last, isPageNumber(page[line]) else { return [] }
        let neighbour = edge == .top ? filled.dropFirst().first : filled.dropLast().last
        if let neighbour, isPageNumber(page[neighbour]) { return [] }
        guard let value = pageNumberValue(page[line]) else { return [] }
        return [Candidate(page: index, line: line, value: value)]
    }

    private static let digits = try! NSRegularExpression(pattern: "[0-9]+")

    /// The number a page-number line prints: the first one in it ("Page 3 of 10" is 3).
    private static func pageNumberValue(_ line: String) -> Int? {
        guard let match = digits.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return Int((line as NSString).substring(with: match.range))
    }

    /// Header and footer lines that repeat on most of the pages long enough to have
    /// them, removed from the edges of those pages.
    private static func dropRunningLines(_ pages: [[String]]) -> [[String]] {
        let long = pages.map { $0.filter { !$0.isEmpty }.count >= minLinesForRunningLines }
        let longCount = long.filter { $0 }.count
        guard longCount >= minPagesForRunningLines else { return pages }
        var seen: [String: Int] = [:]
        for (page, isLong) in zip(pages, long) where isLong {
            for key in Set(edgeIndices(page).map { runningKey(page[$0]) }) where !key.isEmpty { seen[key, default: 0] += 1 }
        }
        let repeated = Set(seen.filter { $0.value * 2 > longCount }.keys)
        return zip(pages, long).map { page, isLong in
            guard isLong else { return page }
            let edges = Set(edgeIndices(page))
            return page.enumerated().filter { !(edges.contains($0.offset) && repeated.contains(runningKey($0.element))) }.map(\.element)
        }
    }

    /// The first and last non-blank lines of a page.
    private static func edgeIndices(_ page: [String]) -> [Int] {
        let filled = page.indices.filter { !page[$0].isEmpty }
        return Array(filled.prefix(edgeLinesPerPageEnd) + filled.suffix(edgeLinesPerPageEnd))
    }

    /// A line compared across pages: case and spacing do not matter, and the one
    /// thing allowed to differ is the page counter. A number is a page counter
    /// when it follows a page word ("page 3", "стр. 3") or is set apart by a bar
    /// or dash at either end of the line ("Report | 3", "3 — Acme"). A number
    /// after any other word ("Chapter 3", "Verse 2") is what the page says, and
    /// stays: "Chapter 1" and "Chapter 2" opening two pages are two headings.
    private static func runningKey(_ line: String) -> String {
        var key = line.lowercased()
        for (pattern, template) in counterPatterns {
            key = pattern.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: template)
        }
        return key.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let counterPatterns: [(NSRegularExpression, String)] = [
        (#"\b(page|p\.?|стр\.?|страница|с\.)\s*[0-9]{1,\#(maxPageNumberDigits)}\b"#, "$1 #"),
        (#"^[0-9]{1,\#(maxPageNumberDigits)}(?=\s*[|·•—–-]\s*\S)"#, "#"),
        (#"([|·•—–-]\s*)[0-9]{1,\#(maxPageNumberDigits)}$"#, "$1#"),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }

    /// One page's paragraphs, each a single line of text. A page with blank lines
    /// keeps them as the paragraph ends; one without is cut after short lines.
    private static func pageParagraphs(_ lines: [String]) -> [String] {
        var groups: [[String]] = [[]]
        let hasBlankLines = lines.contains("")
        let usual = usualLength(lines)
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                if !groups[groups.count - 1].isEmpty { groups.append([]) }
                continue
            }
            groups[groups.count - 1].append(line)
            let endsShort = !hasBlankLines && Double(line.count) < Double(usual) * shortLineRatio
            if endsShort, index < lines.count - 1 { groups.append([]) }
        }
        return groups.filter { !$0.isEmpty }.map { $0.dropFirst().reduce($0[0], join) }
    }

    private static func usualLength(_ lines: [String]) -> Int {
        let lengths = lines.filter { !$0.isEmpty }.map(\.count).sorted()
        guard !lengths.isEmpty else { return 0 }
        return lengths[Int(Double(lengths.count - 1) * usualLengthPercentile)]
    }

    /// The paragraph that ended a page goes on in the first one of the next page
    /// when it stops without a full stop and the next one starts in lower case.
    private static func continues(_ previous: String, with next: String) -> Bool {
        guard let last = previous.last, let first = next.first else { return false }
        return !terminalPunctuation.contains(last) && first.isLetter && first.isLowercase
    }

    /// Joins two lines of one paragraph: `informa-` + `tion` is one word; a
    /// hyphen after a letter and before a capital stays (`Ivanov-Petrov`).
    static func join(_ head: String, _ tail: String) -> String {
        let chars = Array(head)
        guard chars.last == "-", chars.count >= 2, chars[chars.count - 2].isLetter, let first = tail.first, first.isLetter else {
            return head + " " + tail
        }
        return first.isLowercase ? String(head.dropLast()) + tail : head + tail
    }
}
