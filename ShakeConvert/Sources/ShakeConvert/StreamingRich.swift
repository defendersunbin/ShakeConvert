import Foundation
import AppKit

// 큰 Word(docx)·RTF 문서를 메모리에 통째로 올리지 않고 읽어서 변환하는 스트리밍 처리
//
// - DOCX: zip을 직접 열어 word/document.xml만 조금씩 풀어(CRC 검증) 임시 파일로 두고, SAX 방식 XML 파서로
//   문단 단위로 읽는다. 읽은 문단은 곧바로 출력(PDF/HTML/텍스트/RTF/DOCX)으로 써 내려가 메모리가 문서 크기에 비례하지 않는다.
// - RTF: 바이트 단위 토크나이저로 파일을 조금씩 읽는다.
// - 보안: 외부 엔티티를 열지 않고, 링크·이미지·매크로는 가져오지 않는다(글자와 기본 서식만).

// MARK: - 출력: PDF

final class PDFSink: RichSink {
    private let writer: DocumentPDF.StreamWriter
    private var blocks: [DocBlock] = []
    private var tableHeader: [NSAttributedString]?
    private var tableRows: [[NSAttributedString]] = []
    private static let headingSizes: [CGFloat] = [22, 16.5, 13.5, 12, 11, 10.5]

    init(url: URL, title: String) throws {
        writer = try DocumentPDF.StreamWriter(url: url, title: title)
    }

    func abort() { writer.abort() }

    private func attributed(_ runs: [Run], font: NSFont, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in runs where !run.text.isEmpty {
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if run.bold { f = MarkdownRenderer.withTraits(f, .bold) }
            if run.italic { f = MarkdownRenderer.withTraits(f, .italic) }
            if run.code {
                f = .monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                attrs[.backgroundColor] = DocStyle.inlineCode
            }
            if run.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            attrs[.font] = f
            let text = run.text.replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: "\n", with: " ")
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }

    /// 줄바꿈(\n)을 기준으로 여러 줄로 나눈다 (조판기는 문단 안의 강제 줄바꿈을 따로 다루지 않으므로)
    private func lines(_ runs: [Run]) -> [[Run]] {
        var result: [[Run]] = [[]]
        for run in runs {
            let parts = run.text.components(separatedBy: "\n")
            for (i, part) in parts.enumerated() {
                if i > 0 { result.append([]) }
                if !part.isEmpty {
                    var r = run
                    r.text = part
                    result[result.count - 1].append(r)
                }
            }
        }
        return result
    }

    private func push(_ block: DocBlock) throws {
        blocks.append(block)
        if blocks.count >= 200 { try flushBlocks() }
    }

    private func flushBlocks() throws {
        guard !blocks.isEmpty else { return }
        let batch = blocks
        blocks = []
        try writer.add(batch)
    }

    func heading(_ level: Int, _ runs: [Run]) throws {
        let l = min(max(level, 1), 6)
        let font = NSFont.systemFont(ofSize: Self.headingSizes[l - 1], weight: l <= 2 ? .bold : .semibold)
        try push(.heading(level: l, text: attributed(runs, font: font, color: DocStyle.ink)))
    }

    func paragraph(_ runs: [Run]) throws {
        if runs.isEmpty { try push(.spacer(DocStyle.bodySize * 1.3)); return }
        let all = lines(runs)
        for (i, line) in all.enumerated() {
            var style = ParaStyle(lineHeight: 1.3, spaceAfter: i == all.count - 1 ? 5 : 0)
            style.alignment = .left
            try push(.paragraph(attributed(line, font: DocStyle.body, color: DocStyle.ink), style: style))
        }
    }

    func listItem(marker: String, level: Int, _ runs: [Run]) throws {
        try push(.listItem(marker: marker, level: level,
                           text: attributed(runs, font: DocStyle.body, color: DocStyle.ink)))
    }

    func quote(_ runs: [Run]) throws {
        try push(.quote(attributed(runs, font: DocStyle.body, color: DocStyle.dim)))
    }

    func code(_ lines: [String]) throws {
        try push(.code(lines.joined(separator: "\n")))
    }

    func rule() throws { try push(.rule) }

    func tableRow(_ cells: [[Run]], header: Bool) throws {
        let small = NSFont.systemFont(ofSize: 9.8)
        let smallBold = NSFont.systemFont(ofSize: 9.8, weight: .semibold)
        let row = cells.map { attributed($0.isEmpty ? [Run(text: " ")] : $0, font: header ? smallBold : small, color: DocStyle.ink) }
        if header || tableHeader == nil {
            if tableHeader != nil { try flushTable() }
            tableHeader = row
        } else {
            tableRows.append(row)
            if tableRows.count >= 200 { try flushTable() } // 긴 표는 200행씩 (머리글을 반복)
        }
    }

    private func flushTable() throws {
        guard let header = tableHeader else { return }
        try push(.table(header: header, rows: tableRows))
        tableRows = []
    }

    func endTable() throws {
        try flushTable()
        tableHeader = nil
    }

    func finish() throws {
        try endTable()
        try flushBlocks()
        try writer.finish()
    }
}

// MARK: - 출력: HTML

final class HTMLSink: RichSink {
    private let out: BufferedWriter
    private var tableOpen = false

    init(url: URL, title: String) throws {
        out = try BufferedWriter(url: url)
        try out.write(HTMLTemplate.head(title: title) + "\n")
    }

    private func html(_ runs: [Run]) -> String {
        runs.map { run in
            var t = MarkdownRenderer.escape(run.text)
                .replacingOccurrences(of: "\n", with: "<br>")
                .replacingOccurrences(of: "\t", with: "&emsp;")
            if run.code { t = "<code>\(t)</code>" }
            if run.bold { t = "<strong>\(t)</strong>" }
            if run.italic { t = "<em>\(t)</em>" }
            if run.strike { t = "<del>\(t)</del>" }
            return t
        }.joined()
    }

    func heading(_ level: Int, _ runs: [Run]) throws {
        let l = min(max(level, 1), 6)
        try out.write("<h\(l)>\(html(runs))</h\(l)>\n")
    }

    func paragraph(_ runs: [Run]) throws {
        try out.write(runs.isEmpty ? "<p><br></p>\n" : "<p>\(html(runs))</p>\n")
    }

    func listItem(marker: String, level: Int, _ runs: [Run]) throws {
        try out.write("<div class=\"li\" style=\"margin-left:\(level * 22)px\"><span class=\"m\">\(MarkdownRenderer.escape(marker))</span><span>\(html(runs))</span></div>\n")
    }

    func quote(_ runs: [Run]) throws {
        try out.write("<blockquote>\(html(runs))</blockquote>\n")
    }

    func code(_ lines: [String]) throws {
        try out.write("<pre><code>\(MarkdownRenderer.escape(lines.joined(separator: "\n")))</code></pre>\n")
    }

    func rule() throws { try out.write("<hr>\n") }

    func tableRow(_ cells: [[Run]], header: Bool) throws {
        if !tableOpen {
            tableOpen = true
            try out.write("<table>\n" + (header ? "" : "<tbody>\n"))
            if header { try out.write("<thead>") }
        }
        let tag = header ? "th" : "td"
        try out.write("<tr>" + cells.map { "<\(tag)>\(html($0))</\(tag)>" }.joined() + "</tr>\n")
        if header { try out.write("</thead>\n<tbody>\n") }
    }

    func endTable() throws {
        guard tableOpen else { return }
        tableOpen = false
        try out.write("</tbody></table>\n")
    }

    func finish() throws {
        try endTable()
        try out.write(HTMLTemplate.tail)
        try out.close()
    }
}

// MARK: - 출력: 일반 텍스트

final class TextSink: RichSink {
    private let out: BufferedWriter
    private var tableHasHeader = false

    init(url: URL) throws {
        out = try BufferedWriter(url: url)
    }

    private func text(_ runs: [Run]) -> String { runs.map(\.text).joined() }

    func heading(_ level: Int, _ runs: [Run]) throws {
        let t = text(runs)
        try out.write("\n" + t + "\n")
        if level <= 2 { try out.write(String(repeating: level == 1 ? "=" : "-", count: min(max(t.count, 3), 60)) + "\n") }
        try out.write("\n")
    }

    func paragraph(_ runs: [Run]) throws { try out.write(text(runs) + "\n\n") }

    func listItem(marker: String, level: Int, _ runs: [Run]) throws {
        try out.write(String(repeating: "  ", count: level) + marker + " " + text(runs) + "\n")
    }

    func quote(_ runs: [Run]) throws { try out.write("│ " + text(runs) + "\n\n") }

    func code(_ lines: [String]) throws {
        try out.write(lines.map { "    " + $0 }.joined(separator: "\n") + "\n\n")
    }

    func rule() throws { try out.write(String(repeating: "─", count: 40) + "\n\n") }

    func tableRow(_ cells: [[Run]], header: Bool) throws {
        try out.write(cells.map(text).joined(separator: " | ") + "\n")
        if header { try out.write(cells.map { _ in "---" }.joined(separator: " | ") + "\n") }
    }

    func endTable() throws { try out.write("\n") }

    func finish() throws { try out.close() }
}

// MARK: - 입력: DOCX

/// word/styles.xml에서 "이 스타일은 제목 몇 단계인가"를 뽑는다 (작은 파일이라 한 번에 읽어도 된다)
private final class StylesParser: NSObject, XMLParserDelegate {
    private(set) var headingLevel: [String: Int] = [:]
    private var currentID: String?
    private var currentName: String?
    private var currentOutline: Int?

    static func local(_ name: String) -> String {
        if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
        return name
    }

    static func attribute(_ dict: [String: String], _ key: String) -> String? {
        dict["w:\(key)"] ?? dict[key] ?? dict.first(where: { $0.key.hasSuffix(":\(key)") })?.value
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch Self.local(elementName) {
        case "style":
            currentID = Self.attribute(attributeDict, "styleId")
            currentName = nil
            currentOutline = nil
        case "name":
            if currentID != nil { currentName = Self.attribute(attributeDict, "val") }
        case "outlineLvl":
            if currentID != nil, let v = Self.attribute(attributeDict, "val") { currentOutline = Int(v) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard Self.local(elementName) == "style", let id = currentID else { return }
        let name = (currentName ?? "").lowercased()
        if name.hasPrefix("heading "), let n = Int(name.dropFirst(8)) { headingLevel[id] = min(max(n, 1), 6) }
        else if name == "title" { headingLevel[id] = 1 }
        else if let o = currentOutline, o >= 0, o < 9 { headingLevel[id] = min(o + 1, 6) }
        currentID = nil
    }
}

private final class DocxBodyParser: NSObject, XMLParserDelegate {
    private let sink: RichSink
    private let headingLevel: [String: Int]
    private let stream: InputStream
    private let totalBytes: Double
    private let progress: ProgressHandler
    private(set) var failure: Error?

    private var inRun = false
    private var inText = false
    private var textBuffer = ""
    private var bold = false, italic = false, strike = false, mono = false
    private var runs: [Run] = []
    private var styleID: String?
    private var outline: Int?
    private var hasNumbering = false
    private var listLevel = 0
    private var inNumPr = false
    private var tableDepth = 0
    private var rowCells: [[Run]] = []
    private var cellRuns: [Run] = []
    private var tableHasRows = false
    private var paragraphs = 0

    init(sink: RichSink, headingLevel: [String: Int], stream: InputStream, totalBytes: Double, progress: @escaping ProgressHandler) {
        self.sink = sink
        self.headingLevel = headingLevel
        self.stream = stream
        self.totalBytes = max(totalBytes, 1)
        self.progress = progress
    }

    private func fail(_ error: Error, _ parser: XMLParser) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    private static func isOn(_ dict: [String: String]) -> Bool {
        guard let v = StylesParser.attribute(dict, "val")?.lowercased() else { return true }
        return !(v == "0" || v == "false" || v == "off" || v == "none")
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        if var last = runs.last, last.bold == bold, last.italic == italic, last.strike == strike, last.code == mono {
            last.text += text
            runs[runs.count - 1] = last
        } else {
            runs.append(Run(text: text, bold: bold, italic: italic, code: mono, strike: strike))
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch StylesParser.local(elementName) {
        case "p":
            runs = []; styleID = nil; outline = nil; hasNumbering = false; listLevel = 0
        case "pStyle": styleID = StylesParser.attribute(attributeDict, "val")
        case "outlineLvl":
            if let v = StylesParser.attribute(attributeDict, "val"), let n = Int(v), n < 9 { outline = n }
        case "numPr": inNumPr = true; hasNumbering = true
        case "ilvl":
            if inNumPr, let v = StylesParser.attribute(attributeDict, "val"), let n = Int(v) { listLevel = min(max(n, 0), 5) }
        case "r":
            inRun = true; bold = false; italic = false; strike = false; mono = false
        case "b": if inRun { bold = Self.isOn(attributeDict) }
        case "i": if inRun { italic = Self.isOn(attributeDict) }
        case "strike", "dstrike": if inRun { strike = Self.isOn(attributeDict) }
        case "rFonts":
            if inRun, let f = StylesParser.attribute(attributeDict, "ascii")?.lowercased(),
               f.contains("courier") || f.contains("menlo") || f.contains("consolas") || f.contains("monaco") || f.contains("mono") {
                mono = true
            }
        case "t": inText = true; textBuffer = ""
        case "tab": if inRun { append("\t") }
        case "br", "cr": if inRun { append("\n") }
        case "noBreakHyphen": if inRun { append("-") }
        case "tbl":
            tableDepth += 1
            if tableDepth == 1 { tableHasRows = false }
        case "tr": if tableDepth == 1 { rowCells = [] }
        case "tc": if tableDepth == 1 { cellRuns = [] }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { textBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch StylesParser.local(elementName) {
        case "t":
            if inText { append(textBuffer); textBuffer = ""; inText = false }
        case "r": inRun = false
        case "numPr": inNumPr = false
        case "p": endParagraph(parser)
        case "tc": if tableDepth == 1 { rowCells.append(cellRuns); cellRuns = [] }
        case "tr":
            if tableDepth == 1 {
                do {
                    try sink.tableRow(rowCells, header: !tableHasRows)
                    tableHasRows = true
                } catch { fail(error, parser) }
            }
        case "tbl":
            tableDepth = max(tableDepth - 1, 0)
            if tableDepth == 0 {
                do { try sink.endTable() } catch { fail(error, parser) }
            }
        default: break
        }
    }

    private func endParagraph(_ parser: XMLParser) {
        paragraphs += 1
        if paragraphs % 256 == 0 {
            do { try checkCancelled() } catch { fail(error, parser); return }
            if let offset = stream.property(forKey: .fileCurrentOffsetKey) as? NSNumber {
                progress(min(offset.doubleValue / totalBytes, 1))
            }
        }
        let content = runs
        runs = []
        if tableDepth > 0 {
            // 표 칸 안의 문단은 한 칸에 이어 붙인다 (중첩 표도 바깥 칸으로 합쳐짐)
            if !cellRuns.isEmpty && !content.isEmpty { cellRuns.append(Run(text: " ")) }
            cellRuns += content
            return
        }
        do {
            let level = styleID.flatMap { headingLevel[$0] } ?? outline.map { min($0 + 1, 6) }
            if let level, !content.isEmpty {
                try sink.heading(level, content)
            } else if hasNumbering {
                try sink.listItem(marker: "•", level: listLevel, content)
            } else {
                try sink.paragraph(content)
            }
        } catch { fail(error, parser) }
    }
}

enum DocxStreamReader {
    /// word/document.xml의 압축 해제 후 크기 (docx가 아니거나 읽을 수 없으면 nil)
    static func documentSize(of url: URL) -> UInt64? {
        guard let zip = try? ZipArchive(url: url), let entry = zip.entries["word/document.xml"] else { return nil }
        return entry.size
    }

    static func run(_ url: URL, sink: RichSink, workDir: URL, progress: @escaping ProgressHandler) throws {
        let zip = try ZipArchive(url: url)
        guard let document = zip.entries["word/document.xml"] else { throw ConvertError.readFailed }
        try DiskGuard.check(workDir)

        // 제목 스타일 정보 (있으면)
        var headings: [String: Int] = [:]
        if let styles = zip.entries["word/styles.xml"], styles.size < 64 << 20 {
            let stylesURL = workDir.appendingPathComponent("styles.xml")
            try zip.extract(styles, to: stylesURL)
            if let data = try? Data(contentsOf: stylesURL, options: .mappedIfSafe) {
                let parser = XMLParser(data: data)
                let delegate = StylesParser()
                parser.delegate = delegate
                parser.shouldResolveExternalEntities = false
                parser.parse()
                headings = delegate.headingLevel
            }
        }

        // 본문: 0~30% 풀기, 30~100% 읽기
        let xmlURL = workDir.appendingPathComponent("document.xml")
        try zip.extract(document, to: xmlURL) { progress(0.3 * $0) }

        guard let stream = InputStream(url: xmlURL) else { throw ConvertError.readFailed }
        let parser = XMLParser(stream: stream)
        parser.shouldResolveExternalEntities = false
        let delegate = DocxBodyParser(sink: sink, headingLevel: headings, stream: stream,
                                      totalBytes: Double(document.size)) { progress(0.3 + 0.7 * $0) }
        parser.delegate = delegate
        stream.open()
        defer { stream.close() }
        let ok = parser.parse()
        if let failure = delegate.failure { throw failure }
        if !ok { throw ConvertError.readFailed } // 손상된 XML
    }
}

// MARK: - 입력: RTF

/// RTF를 바이트 단위로 읽는 토크나이저. 글자·굵게·기울임·취소선·문단·탭·표(행/칸)를 가져오고,
/// 글꼴 표·색 표·머리글/바닥글·그림·필드 코드 같은 부가 영역은 건너뛴다.
final class RTFStreamReader {
    private struct Group {
        var bold = false
        var italic = false
        var strike = false
        var skip = false
        var uc = 1
    }

    private enum State { case text, escape, word, param, hex1, hex2 }

    private let sink: RichSink
    private var state = State.text
    private var current = Group()
    private var stack: [Group] = []
    private var word = ""
    private var param = ""
    private var hex1: UInt8 = 0
    private var skipChars = 0
    private var binarySkip = 0
    private var encoding: String.Encoding = .windowsCP1252
    private var byteBuffer: [UInt8] = []
    private var textBuffer = ""
    private var bufferFormat = (false, false, false)
    private var paragraph: [Run] = []
    private var cell: [Run] = []
    private var row: [[Run]] = []
    private var inTable = false
    private var tableOpen = false
    private var highSurrogate: UInt16?

    private static let skippedDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer", "headerl", "headerr", "headerf",
        "footerl", "footerr", "footerf", "footnote", "object", "listtable", "listoverridetable", "rsidtbl",
        "generator", "themedata", "colorschememapping", "latentstyles", "datastore", "xmlnstbl", "fldinst",
        "bkmkstart", "bkmkend", "revtbl", "mmathPr", "pnseclvl",
    ]

    init(sink: RichSink) { self.sink = sink }

    static func run(_ url: URL, sink: RichSink, progress: @escaping ProgressHandler) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ConvertError.readFailed }
        defer { try? handle.close() }
        let total = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1)
        let reader = RTFStreamReader(sink: sink)
        var done = 0.0
        while true {
            try checkCancelled()
            let chunk: Data
            do { chunk = (try handle.read(upToCount: 1 << 20)) ?? Data() } catch { throw ConvertError.readFailed }
            if chunk.isEmpty { break }
            try reader.feed(chunk)
            done += Double(chunk.count)
            progress(min(done / max(total, 1), 1))
        }
        try reader.finish()
    }

    // MARK: 토크나이저

    func feed(_ data: Data) throws {
        for b in data { try consume(b) }
    }

    private func consume(_ b: UInt8) throws {
        if binarySkip > 0 { binarySkip -= 1; return }
        switch state {
        case .text:
            switch b {
            case 0x5C: state = .escape
            case 0x7B: flushText(); stack.append(current)
            case 0x7D:
                flushText()
                if let g = stack.popLast() { current = g }
            case 0x0A, 0x0D: break
            default: literal(b)
            }

        case .escape:
            state = .text
            switch b {
            case 0x61...0x7A, 0x41...0x5A: word = String(UnicodeScalar(b)); param = ""; state = .word
            case 0x27: state = .hex1                                     // \'hh
            case 0x5C, 0x7B, 0x7D: literal(b)
            case 0x2A: current.skip = true                               // \* : 알 수 없는 부가 영역
            case 0x7E: addText("\u{00A0}")
            case 0x5F: addText("\u{2011}")
            case 0x0A, 0x0D: try endParagraph()
            default: break
            }

        case .word:
            switch b {
            case 0x61...0x7A, 0x41...0x5A: word.append(Character(UnicodeScalar(b)))
            case 0x30...0x39, 0x2D: param = String(UnicodeScalar(b)); state = .param
            case 0x20: try processWord(nil); state = .text
            default: try processWord(nil); state = .text; try consume(b)
            }

        case .param:
            switch b {
            case 0x30...0x39: param.append(Character(UnicodeScalar(b)))
            case 0x20: try processWord(Int(param)); state = .text
            default: try processWord(Int(param)); state = .text; try consume(b)
            }

        case .hex1:
            hex1 = Self.hexValue(b); state = .hex2

        case .hex2:
            state = .text
            let value = hex1 << 4 | Self.hexValue(b)
            if current.skip { return }
            if skipChars > 0 { skipChars -= 1; return }
            byteBuffer.append(value)
        }
    }

    private static func hexValue(_ b: UInt8) -> UInt8 {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return 0
        }
    }

    private func literal(_ b: UInt8) {
        if current.skip { return }
        if skipChars > 0 { skipChars -= 1; return }
        if b < 0x80 { addText(String(UnicodeScalar(b))) } else { byteBuffer.append(b) }
    }

    private func processWord(_ value: Int?) throws {
        switch word {
        case "par", "sect": try endParagraph()
        case "pard": inTable = false
        case "intbl": inTable = true
        case "line": addText("\n")
        case "tab": addText("\t")
        case "emdash": addText("—")
        case "endash": addText("–")
        case "bullet": addText("•")
        case "lquote": addText("‘")
        case "rquote": addText("’")
        case "ldblquote": addText("“")
        case "rdblquote": addText("”")
        case "emspace", "enspace": addText(" ")
        case "b": setFormat { $0.bold = (value ?? 1) != 0 }
        case "i": setFormat { $0.italic = (value ?? 1) != 0 }
        case "strike": setFormat { $0.strike = (value ?? 1) != 0 }
        case "plain": setFormat { $0.bold = false; $0.italic = false; $0.strike = false }
        case "uc": current.uc = value ?? 1
        case "u": unicode(value ?? 0)
        case "ansicpg": encoding = Self.encoding(forCodePage: value ?? 1252)
        case "bin": binarySkip = max(value ?? 0, 0)
        case "cell": try endCell()
        case "row": try endRow()
        case "trowd": row = []
        default:
            if Self.skippedDestinations.contains(word) { current.skip = true }
        }
    }

    private func setFormat(_ change: (inout Group) -> Void) {
        flushBytes()
        flushText()
        change(&current)
    }

    private func unicode(_ value: Int) {
        guard !current.skip else { return }
        flushBytes()
        let unit = UInt16(truncatingIfNeeded: value < 0 ? value + 65536 : value)
        if (0xD800...0xDBFF).contains(unit) {
            highSurrogate = unit
        } else if (0xDC00...0xDFFF).contains(unit), let high = highSurrogate {
            highSurrogate = nil
            let scalar = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(unit) - 0xDC00)
            if let u = UnicodeScalar(scalar) { addTextRaw(String(Character(u))) }
        } else if let u = UnicodeScalar(UInt32(unit)) {
            addTextRaw(String(Character(u)))
        }
        skipChars = current.uc // 대체 문자(\uc개)는 건너뜀
    }

    // MARK: 글자 모으기

    private func addText(_ s: String) {
        guard !current.skip else { return }
        flushBytes()
        addTextRaw(s)
    }

    private func addTextRaw(_ s: String) {
        let format = (current.bold, current.italic, current.strike)
        if !textBuffer.isEmpty && (format.0 != bufferFormat.0 || format.1 != bufferFormat.1 || format.2 != bufferFormat.2) {
            flushText()
        }
        bufferFormat = format
        textBuffer += s
    }

    private func flushBytes() {
        guard !byteBuffer.isEmpty else { return }
        let data = Data(byteBuffer)
        byteBuffer = []
        let s = String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1) ?? ""
        addTextRaw(s)
    }

    private func flushText() {
        flushBytes()
        guard !textBuffer.isEmpty else { return }
        paragraph.append(Run(text: textBuffer, bold: bufferFormat.0, italic: bufferFormat.1, code: false, strike: bufferFormat.2))
        textBuffer = ""
    }

    private static func encoding(forCodePage cp: Int) -> String.Encoding {
        func cf(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        switch cp {
        case 949: return cf(.dosKorean)
        case 932: return cf(.dosJapanese)
        case 936: return cf(.dosChineseSimplif)
        case 950: return cf(.dosChineseTrad)
        case 1250: return .windowsCP1250
        case 1251: return .windowsCP1251
        case 1253: return .windowsCP1253
        case 1254: return .windowsCP1254
        case 10000: return .macOSRoman
        default: return .windowsCP1252
        }
    }

    // MARK: 문단 · 표

    private func closeTableIfNeeded() throws {
        if tableOpen { tableOpen = false; try sink.endTable() }
    }

    private func endParagraph() throws {
        flushText()
        let content = paragraph
        paragraph = []
        if inTable {
            if !cell.isEmpty && !content.isEmpty { cell.append(Run(text: " ")) }
            cell += content
            return
        }
        try closeTableIfNeeded()
        try sink.paragraph(content)
    }

    private func endCell() throws {
        flushText()
        if !cell.isEmpty && !paragraph.isEmpty { cell.append(Run(text: " ")) }
        cell += paragraph
        paragraph = []
        row.append(cell)
        cell = []
    }

    private func endRow() throws {
        try sink.tableRow(row, header: !tableOpen)
        tableOpen = true
        row = []
    }

    func finish() throws {
        flushText()
        if !paragraph.isEmpty { try endParagraph() }
        try closeTableIfNeeded()
        try sink.finish()
    }
}

// MARK: - 진입점

enum StreamingRich {
    /// 이 크기를 넘는 RTF/DOCX는 스트리밍으로 처리 (작은 문서는 기존의 정밀한 방식)
    static let fileThreshold: Int64 = 4 << 20
    static let xmlThreshold: UInt64 = 8 << 20

    static func shouldStream(_ url: URL, ext: String) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        if Int64(size) > fileThreshold { return true }
        // 작은 docx라도 풀면 거대한 XML일 수 있다(압축 폭탄): 압축 해제 후 크기로 판단
        if ext == "docx", let xml = DocxStreamReader.documentSize(of: url) { return xml > xmlThreshold }
        return false
    }

    static func convert(_ url: URL, ext: String, key: String, title: String, to out: URL,
                        progress: @escaping ProgressHandler) throws {
        let workDir = out.deletingLastPathComponent()
        try DiskGuard.check(workDir)

        let sink: RichSink
        switch key {
        case "pdf": sink = try PDFSink(url: out, title: title)
        case "html": sink = try HTMLSink(url: out, title: title)
        case "txt": sink = try TextSink(url: out)
        case "rtf": sink = try RTFSink(url: out)
        case "docx": sink = try DocxSink(url: out)
        default: throw ConvertError.unsupported("")
        }

        do {
            if ext == "docx" {
                try DocxStreamReader.run(url, sink: sink, workDir: workDir, progress: { progress(0.97 * $0) })
                try sink.finish()
            } else {
                // RTFStreamReader.run은 끝에서 sink.finish()까지 호출한다
                try RTFStreamReader.run(url, sink: sink, progress: { progress(0.97 * $0) })
            }
        } catch {
            (sink as? PDFSink)?.abort()
            throw error
        }
    }
}
