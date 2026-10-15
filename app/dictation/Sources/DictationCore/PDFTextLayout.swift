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

    private static let terminalPunctuation = Set(".!?…»”\"')")
    private static let pageNumber = try! NSRegularExpression(
        pattern: #"^(?:(?:page|p\.?|стр\.?|страница|с\.)\s*)?(?:[-–—]\s*)?[0-9]{1,\#(maxPageNumberDigits)}(?:\s*[-–—])?(?:\s*(?:of|/|из)\s*[0-9]{1,\#(maxPageNumberDigits)})?$"#,
        options: .caseInsensitive)

    /// `pages` hold normalised text (line breaks are "\n"). Paragraphs are
    /// separated by one blank line.
    static func paragraphs(_ pages: [String]) -> String {
        let lines = pages.map { page in
            dropPageNumbers(page.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) })
        }
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

    /// The page number a page prints at its top or bottom: the first or last
    /// non-blank line when it is a page number. A number anywhere else is text
    /// ("the answer is" / "42"), and so is one beside another number (a list of
    /// "1", "2", "3" is not three page numbers).
    private static func dropPageNumbers(_ page: [String]) -> [String] {
        let filled = page.indices.filter { !page[$0].isEmpty }
        guard let first = filled.first, let last = filled.last else { return page }
        var dropped = Set<Int>()
        func consider(_ index: Int, neighbour: Int?) {
            guard isPageNumber(page[index]), neighbour.map({ !isPageNumber(page[$0]) }) ?? true else { return }
            dropped.insert(index)
        }
        consider(first, neighbour: filled.count > 1 ? filled[1] : nil)
        if last != first { consider(last, neighbour: filled[filled.count - 2]) }
        return page.indices.filter { !dropped.contains($0) }.map { page[$0] }
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
