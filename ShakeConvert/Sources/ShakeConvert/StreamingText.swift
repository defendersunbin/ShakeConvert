import Foundation
import AppKit

// 큰 텍스트·마크다운 문서를 크기와 상관없이 끝까지 변환하는 스트리밍 처리
//
// 원리: 파일을 1MB씩 읽어 "문단 경계(빈 줄)"에서 잘라 조각 단위로 변환하고, 결과를 바로 파일에 이어 쓴다.
// 메모리에는 언제나 한 조각분만 남으므로 파일이 수백 MB~수 GB여도 메모리가 늘어나지 않는다.
// - 마크다운은 빈 줄이 곧 블록 경계이므로(코드 블록 안은 제외) 조각으로 나눠도 결과가 통째로 변환한 것과 같다.
// - 코드 블록이 너무 길어 경계를 못 찾으면 코드 블록을 둘로 나눠 이어 붙인다(내용은 그대로).
// - 오래 걸릴 수 있지만 진행률이 표시되고 언제든 취소할 수 있다.

// MARK: - CRC32 (docx = zip 만들 때 필요)

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    /// 이어서 계산 가능: update(update(0, a), b) == update(0, a + b)
    static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = ~crc
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return ~c
    }
}

// MARK: - 버퍼를 둔 파일 쓰기

/// 작은 쓰기를 모아서 파일에 쓰고, 쓴 바이트 수와 CRC32를 함께 센다.
/// deflate를 켜면 쓰는 즉시 압축해서 저장한다 (docx 본문처럼 큰 XML을 작게 저장).
/// 일정 분량마다 디스크 여유를 확인해, 가득 차기 전에 깔끔히 중단한다.
final class BufferedWriter {
    private let handle: FileHandle
    private let directory: URL
    private var codec: StreamCodec?
    private var buffer = Data()
    private var isClosed = false
    private var sinceCheck: UInt64 = 0
    private(set) var crc: UInt32 = 0
    private(set) var byteCount: UInt64 = 0      // 압축 전(논리) 크기
    private(set) var storedCount: UInt64 = 0    // 파일에 실제로 쓴 크기

    init(url: URL, deflate: Bool = false) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let h = try? FileHandle(forWritingTo: url)
        else { throw ConvertError.writeFailed("") }
        handle = h
        directory = url.deletingLastPathComponent()
        buffer.reserveCapacity(1 << 18)
        if deflate { codec = try StreamCodec(.encode) }
    }

    func write(_ s: String) throws {
        buffer.append(contentsOf: s.utf8)
        if buffer.count >= 1 << 18 { try flush() }
    }

    func write(data: Data) throws {
        buffer.append(data)
        if buffer.count >= 1 << 18 { try flush() }
    }

    private func store(_ data: Data) throws {
        do { try handle.write(contentsOf: data) } catch { throw ConvertError.wrapping(error) }
        storedCount += UInt64(data.count)
    }

    private func push(_ data: Data, finalize: Bool) throws {
        if let codec { try codec.process(data, finalize: finalize) { try store($0) } }
        else { try store(data) }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        crc = CRC32.update(crc, buffer)
        byteCount += UInt64(buffer.count)
        sinceCheck += UInt64(buffer.count)
        try push(buffer, finalize: false)
        buffer.removeAll(keepingCapacity: true)
        if sinceCheck >= 64 << 20 {
            sinceCheck = 0
            try DiskGuard.check(directory)
        }
    }

    func close() throws {
        guard !isClosed else { return }
        try flush()
        if codec != nil { try push(Data(), finalize: true) }
        isClosed = true
        try? handle.close()
    }

    deinit {
        if !isClosed { try? handle.close() }
    }
}

// MARK: - 조각 단위 파일 읽기

/// 파일을 줄 경계에서 잘라 문자열 조각으로 돌려준다. UTF-8 / UTF-16(BOM) / CP949 / Latin-1을 지원한다.
final class ChunkReader {
    private enum Encoding { case utf8, utf16le, utf16be, cp949, latin1 }

    private static let pieceBytes = 1 << 20
    /// 줄바꿈이 이만큼 이어지지 않으면(한 줄이 너무 길면) 중간에서 자른다.
    private static let maxLineBytes = 64 << 20

    private static let cp949Encoding: String.Encoding = {
        let cf = CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }()

    private let handle: FileHandle
    private let skip: UInt64
    private var encoding: Encoding = .utf8
    private var pending = Data()
    private var reachedEnd = false
    let total: Int64
    private(set) var consumed: Int64 = 0

    var fraction: Double { total > 0 ? min(1, Double(consumed) / Double(total)) : 0 }

    init(url: URL) throws {
        total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard let h = try? FileHandle(forReadingFrom: url) else { throw ConvertError.readFailed }
        handle = h

        let head = (try? h.read(upToCount: 4)) ?? Data()
        var skipBytes: UInt64 = 0
        var known = true
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { encoding = .utf8; skipBytes = 3 }
        else if head.starts(with: [0xFF, 0xFE]) { encoding = .utf16le; skipBytes = 2 }
        else if head.starts(with: [0xFE, 0xFF]) { encoding = .utf16be; skipBytes = 2 }
        else { known = false }
        skip = skipBytes
        try rewind()

        if !known {
            // 한 번 훑어서 UTF-8로 온전히 읽히는지, 아니면 한글 Windows(CP949)인지 정한다.
            var utf8OK = true
            var cp949OK = true
            while utf8OK || cp949OK, let bytes = try readBytes() {
                if utf8OK, String(data: bytes, encoding: .utf8) == nil { utf8OK = false }
                if cp949OK, String(data: bytes, encoding: Self.cp949Encoding) == nil { cp949OK = false }
                try checkCancelled()
            }
            encoding = utf8OK ? .utf8 : (cp949OK ? .cp949 : .latin1)
            try rewind()
        }
    }

    deinit { try? handle.close() }

    private func rewind() throws {
        do { try handle.seek(toOffset: skip) } catch { throw ConvertError.readFailed }
        pending = Data()
        reachedEnd = false
        consumed = Int64(skip)
    }

    /// 다음 조각 (줄바꿈 문자는 "\n"으로 통일). 끝이면 nil.
    func nextPiece() throws -> String? {
        guard let bytes = try readBytes() else { return nil }
        let text = decode(bytes)
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private func decode(_ data: Data) -> String {
        switch encoding {
        case .utf8: return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        case .utf16le: return String(data: data, encoding: .utf16LittleEndian) ?? ""
        case .utf16be: return String(data: data, encoding: .utf16BigEndian) ?? ""
        case .cp949: return String(data: data, encoding: Self.cp949Encoding) ?? String(data: data, encoding: .isoLatin1) ?? ""
        case .latin1: return String(data: data, encoding: .isoLatin1) ?? ""
        }
    }

    /// 줄 끝(개행 바로 뒤)에서 끊긴 다음 바이트 덩어리.
    private func readBytes() throws -> Data? {
        while true {
            if !reachedEnd {
                let chunk: Data
                do { chunk = (try handle.read(upToCount: Self.pieceBytes)) ?? Data() }
                catch { throw ConvertError.readFailed }
                if chunk.isEmpty { reachedEnd = true }
                else { pending.append(chunk); consumed += Int64(chunk.count) }
            }
            if reachedEnd {
                if pending.isEmpty { return nil }
                let out = pending
                pending = Data()
                return out
            }
            if let cut = lastNewlineEnd(in: pending) {
                let out = Data(pending[0..<cut])
                pending = Data(pending[cut...])
                return out
            }
            if pending.count > Self.maxLineBytes {
                let cut = forcedCut(in: pending)
                let out = Data(pending[0..<cut])
                pending = Data(pending[cut...])
                return out
            }
        }
    }

    private func lastNewlineEnd(in d: Data) -> Int? {
        switch encoding {
        case .utf16le, .utf16be:
            var i = (d.count & ~1) - 2
            while i >= 0 {
                let a = d[i], b = d[i + 1]
                if (encoding == .utf16le && a == 0x0A && b == 0x00) || (encoding == .utf16be && a == 0x00 && b == 0x0A) {
                    return i + 2
                }
                i -= 2
            }
            return nil
        default:
            if let idx = d.lastIndex(of: 0x0A) { return idx + 1 }
            return nil
        }
    }

    /// 줄바꿈 없이 너무 길어진 경우의 강제 분할 위치 (글자 중간은 피한다)
    private func forcedCut(in d: Data) -> Int {
        switch encoding {
        case .utf16le, .utf16be:
            return d.count & ~1
        case .utf8:
            var cut = d.count
            var back = 0
            while back < 4, cut - 1 - back >= 0, d[cut - 1 - back] & 0x80 != 0 {
                if d[cut - 1 - back] & 0xC0 != 0x80 { cut = cut - 1 - back; break } // 시작 바이트 → 그 글자는 다음 조각으로
                back += 1
            }
            return max(cut, 1)
        default:
            return d.count
        }
    }
}

// MARK: - 서식 있는 출력(RTF / DOCX)용 공통 형태

struct Run {
    var text: String
    var bold = false
    var italic = false
    var code = false
    var strike = false
}

protocol RichSink: AnyObject {
    func heading(_ level: Int, _ runs: [Run]) throws
    func paragraph(_ runs: [Run]) throws
    func listItem(marker: String, level: Int, _ runs: [Run]) throws
    func quote(_ runs: [Run]) throws
    func code(_ lines: [String]) throws
    func rule() throws
    /// 표는 행 단위로 이어서 받는다 (header: 머리글 행). 표가 끝나면 endTable.
    func tableRow(_ cells: [[Run]], header: Bool) throws
    func endTable() throws
    func finish() throws
}

enum RichFeed {
    static func runs(_ s: String) -> [Run] {
        Inline.spans(s).map { span in
            var text = span.isImage ? L("[이미지: %@]", span.text) : span.text
            if let link = span.link, link.absoluteString != span.text { text += " (\(link.absoluteString))" }
            return Run(text: text, bold: span.bold, italic: span.italic || span.isImage, code: span.code, strike: span.strike)
        }
    }

    /// 열 수를 맞춘다: 모자라면 빈 칸을 채우고, 넘치면 마지막 칸에 이어 붙여 내용이 사라지지 않게 한다.
    static func padded(_ cells: [[Run]], _ columns: Int) -> [[Run]] {
        var out = Array(cells.prefix(columns))
        if cells.count > columns {
            for extra in cells[columns...] { out[columns - 1] += [Run(text: " | ")] + extra }
        }
        while out.count < columns { out.append([]) }
        return out
    }

    static func feed(_ blocks: [MDBlock], to sink: RichSink) throws {
        for block in blocks {
            switch block {
            case let .heading(level, text): try sink.heading(level, runs(text))
            case let .paragraph(text): try sink.paragraph(runs(text))
            case let .listItem(marker, level, text):
                try sink.listItem(marker: MarkdownRenderer.markerText(marker, level: level), level: level, runs(text))
            case let .quote(text): try sink.quote(runs(text))
            case let .code(code): try sink.code(code.components(separatedBy: "\n"))
            case .rule: try sink.rule()
            case let .table(header, rows):
                let columns = min(max(header.count, rows.map(\.count).max() ?? 0, 1), 20)
                try sink.tableRow(padded(header.map(runs), columns), header: true)
                for row in rows { try sink.tableRow(padded(row.map(runs), columns), header: false) }
                try sink.endTable()
            }
        }
    }

    /// txt: 줄마다 문단, 빈 줄은 빈 문단
    static func feedPlain(_ text: String, to sink: RichSink) throws {
        for line in text.components(separatedBy: "\n") {
            try sink.paragraph(line.isEmpty ? [] : [Run(text: line)])
        }
    }
}

// MARK: - RTF 스트리밍 출력

final class RTFSink: RichSink {
    private let out: BufferedWriter
    private static let headingSizes = [44, 33, 27, 24, 22, 21] // 반 포인트 단위

    init(url: URL) throws {
        out = try BufferedWriter(url: url)
        try out.write(#"{\rtf1\ansi\ansicpg1252\uc1\deff0{\fonttbl{\f0\fswiss\fcharset0 Helvetica;}{\f1\fmodern\fcharset0 Menlo;}}"#
                      + #"{\colortbl;\red31\green35\blue40;\red89\green99\blue110;\red47\green111\blue208;}\viewkind4\f0\fs21\cf1"# + "\n")
    }

    static func escape(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u.value {
            case 0x5C: r += "\\\\"
            case 0x7B: r += "\\{"
            case 0x7D: r += "\\}"
            case 0x0A: r += "\\line "
            case 0x09: r += "\\tab "
            case 0x00..<0x20: continue
            case 0x20..<0x7F: r.unicodeScalars.append(u)
            default:
                for unit in String(u).utf16 { r += "\\u\(Int16(bitPattern: unit))?" }
            }
        }
        return r
    }

    private func runsText(_ runs: [Run], forceBold: Bool = false) -> String {
        runs.map { run in
            var open = ""
            if run.bold || forceBold { open += "\\b " }
            if run.italic { open += "\\i " }
            if run.strike { open += "\\strike " }
            if run.code { open += "\\f1\\fs19 " }
            let body = RTFSink.escape(run.text)
            return open.isEmpty ? body : "{" + open + body + "}"
        }.joined()
    }

    func heading(_ level: Int, _ runs: [Run]) throws {
        let size = RTFSink.headingSizes[min(max(level, 1), 6) - 1]
        try out.write(#"\pard\sb280\sa140\keepn\b\fs\#(size) "# + runsText(runs) + #"\b0\fs21\par"# + "\n")
    }

    func paragraph(_ runs: [Run]) throws {
        try out.write(#"\pard\sa140\sl310\slmult1 "# + runsText(runs) + #"\par"# + "\n")
    }

    func listItem(marker: String, level: Int, _ runs: [Run]) throws {
        let indent = 360 * (level + 1)
        try out.write(#"\pard\li\#(indent)\fi-300\sa60 "# + RTFSink.escape(marker) + #"\tab "# + runsText(runs) + #"\par"# + "\n")
    }

    func quote(_ runs: [Run]) throws {
        try out.write(#"\pard\li480\sa140\cf2\i "# + runsText(runs) + #"\i0\cf1\par"# + "\n")
    }

    func code(_ lines: [String]) throws {
        for line in lines {
            try out.write(#"\pard\li240\sa0\f1\fs18 "# + RTFSink.escape(line.isEmpty ? " " : line) + #"\f0\fs21\par"# + "\n")
        }
        try out.write(#"\pard\sa120\par"# + "\n")
    }

    func rule() throws {
        try out.write(#"\pard\sa120\brdrb\brdrs\brdrw10\brsp40 \par"# + "\n")
    }

    func tableRow(_ cells: [[Run]], header: Bool) throws {
        let cells = RichFeed.padded(cells, min(max(cells.count, 1), 20))
        let columns = cells.count
        let width = 9000 / columns
        var line = #"\trowd\trgaph100"#
        for c in 1...columns {
            line += #"\clbrdrt\brdrs\brdrw10\clbrdrl\brdrs\brdrw10\clbrdrb\brdrs\brdrw10\clbrdrr\brdrs\brdrw10\cellx\#(width * c)"#
        }
        for cell in cells {
            line += #"\pard\intbl\fs19 "# + runsText(cell, forceBold: header) + #"\cell"#
        }
        try out.write(line + #"\row"# + "\n")
    }

    func endTable() throws {
        try out.write(#"\pard\fs21\sa120\par"# + "\n")
    }

    func finish() throws {
        try out.write("}\n")
        try out.close()
    }
}

// MARK: - DOCX 스트리밍 출력 (본문 XML을 임시 파일에 쓰고 zip으로 묶음)

final class DocxSink: RichSink {
    private let body: BufferedWriter
    private let bodyURL: URL
    private let outURL: URL
    private var tableColumns = 0     // 열려 있는 표의 열 수 (0이면 표 밖)
    private static let headingSizes = [44, 33, 27, 24, 22, 21]
    private static let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""

    init(url: URL) throws {
        outURL = url
        bodyURL = url.deletingLastPathComponent().appendingPathComponent("body.xml.deflate")
        body = try BufferedWriter(url: bodyURL, deflate: true) // 본문 XML은 만드는 즉시 압축해서 저장
        try body.write("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                       + "<w:document \(DocxSink.ns)><w:body>\n")
    }

    // MARK: XML 조각

    /// XML에서 허용되지 않는 문자는 빼고 이스케이프한다.
    static func escape(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u.value {
            case 0x26: r += "&amp;"
            case 0x3C: r += "&lt;"
            case 0x3E: r += "&gt;"
            case 0x22: r += "&quot;"
            case 0x09: r += "    "
            case 0x0A, 0x0D: r += " "
            case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: r.unicodeScalars.append(u)
            default: continue
            }
        }
        return r
    }

    private func runXML(_ run: Run, size: Int? = nil, bold: Bool = false, color: String? = nil, mono: Bool = false) -> String {
        guard !run.text.isEmpty else { return "" }
        var props = ""
        if run.code || mono { props += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/>" }
        if run.bold || bold { props += "<w:b/>" }
        if run.italic { props += "<w:i/>" }
        if run.strike { props += "<w:strike/>" }
        if let color { props += "<w:color w:val=\"\(color)\"/>" }
        if let size { props += "<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/>" }
        else if run.code { props += "<w:sz w:val=\"19\"/><w:szCs w:val=\"19\"/>" }
        if run.code { props += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"EEF0F3\"/>" }
        let rPr = props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
        // 줄바꿈은 <w:br/>, 탭은 <w:tab/>으로 (글자는 그대로 유지)
        var content = ""
        var pending = ""
        func flushText() {
            if !pending.isEmpty { content += "<w:t xml:space=\"preserve\">\(DocxSink.escape(pending))</w:t>"; pending = "" }
        }
        for ch in run.text {
            if ch == "\n" { flushText(); content += "<w:br/>" }
            else if ch == "\t" { flushText(); content += "<w:tab/>" }
            else { pending.append(ch) }
        }
        flushText()
        return "<w:r>\(rPr)\(content)</w:r>"
    }

    private func paragraphXML(_ pPr: String, _ content: String) -> String {
        "<w:p>" + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>") + content + "</w:p>\n"
    }

    // MARK: RichSink

    func heading(_ level: Int, _ runs: [Run]) throws {
        let l = min(max(level, 1), 6)
        let size = DocxSink.headingSizes[l - 1]
        let content = runs.map { runXML($0, size: size, bold: true) }.joined()
        try body.write(paragraphXML("<w:keepNext/><w:spacing w:before=\"280\" w:after=\"120\"/><w:outlineLvl w:val=\"\(l - 1)\"/>", content))
    }

    func paragraph(_ runs: [Run]) throws {
        try body.write(paragraphXML("", runs.map { runXML($0) }.joined()))
    }

    func listItem(marker: String, level: Int, _ runs: [Run]) throws {
        let left = 360 * (level + 1)
        let content = runXML(Run(text: marker), color: "59636E") + "<w:r><w:tab/></w:r>" + runs.map { runXML($0) }.joined()
        try body.write(paragraphXML("<w:spacing w:after=\"60\"/><w:ind w:left=\"\(left)\" w:hanging=\"300\"/>", content))
    }

    func quote(_ runs: [Run]) throws {
        let pPr = "<w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"C9D1DA\"/></w:pBdr><w:ind w:left=\"360\"/>"
        try body.write(paragraphXML(pPr, runs.map { runXML($0, color: "59636E") }.joined()))
    }

    func code(_ lines: [String]) throws {
        for line in lines {
            let pPr = "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F5F6F8\"/><w:spacing w:after=\"0\" w:line=\"260\" w:lineRule=\"auto\"/><w:ind w:left=\"120\" w:right=\"120\"/>"
            try body.write(paragraphXML(pPr, runXML(Run(text: line.isEmpty ? " " : line), size: 18, mono: true)))
        }
        try body.write(paragraphXML("<w:spacing w:after=\"120\"/>", ""))
    }

    func rule() throws {
        try body.write(paragraphXML("<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"D8DCE1\"/></w:pBdr><w:spacing w:after=\"160\"/>", ""))
    }

    func tableRow(_ cells: [[Run]], header: Bool) throws {
        var xml = ""
        if tableColumns == 0 {
            // 첫 행의 열 수로 표를 연다
            tableColumns = min(max(cells.count, 1), 20)
            xml += "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>"
            for side in ["top", "left", "bottom", "right", "insideH", "insideV"] {
                xml += "<w:\(side) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"D8DCE1\"/>"
            }
            xml += "</w:tblBorders></w:tblPr><w:tblGrid>"
            xml += String(repeating: "<w:gridCol w:w=\"\(9000 / tableColumns)\"/>", count: tableColumns) + "</w:tblGrid>\n"
        }
        let width = 9000 / tableColumns
        let row = RichFeed.padded(cells, tableColumns)
        xml += "<w:tr>" + (header ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
        for cell in row {
            let shade = header ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F0F2F5\"/>" : ""
            xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>\(shade)</w:tcPr>"
            xml += "<w:p><w:pPr><w:spacing w:after=\"40\"/></w:pPr>" + cell.map { runXML($0, size: 20, bold: header) }.joined() + "</w:p></w:tc>"
        }
        xml += "</w:tr>\n"
        try body.write(xml)
    }

    func endTable() throws {
        guard tableColumns > 0 else { return }
        tableColumns = 0
        try body.write("</w:tbl>\n")
        try body.write(paragraphXML("<w:spacing w:after=\"120\"/>", "")) // 표 뒤에는 반드시 문단이 있어야 한다
    }

    func finish() throws {
        try endTable()
        let paper = Prefs.paperSize.size
        let (w, h) = paper.width > 600 ? (12240, 15840) : (11906, 16838) // Letter / A4 (twip)
        try body.write("<w:sectPr><w:pgSz w:w=\"\(w)\" w:h=\"\(h)\"/><w:pgMar w:top=\"1440\" w:right=\"1300\" w:bottom=\"1300\" w:left=\"1300\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>")
        try body.close()
        try assemble()
    }

    // MARK: zip 조립 (ZIP64 지원: 4GB가 넘어도 됨)

    private func assemble() throws {
        let zip = try ZipWriter(url: outURL)
        try zip.addStored("[Content_Types].xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
            </Types>
            """.utf8))
        try zip.addStored("_rels/.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
            </Relationships>
            """.utf8))
        try zip.addStored("word/_rels/document.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
            </Relationships>
            """.utf8))
        try zip.addStored("word/styles.xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <w:styles \(DocxSink.ns)><w:docDefaults>\
            <w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Apple SD Gothic Neo" w:cs="Arial"/><w:sz w:val="21"/><w:szCs w:val="21"/></w:rPr></w:rPrDefault>\
            <w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault>\
            </w:docDefaults></w:styles>
            """.utf8))
        // 본문(document.xml)은 이미 압축된 파일(method 8)을 그대로 복사해 넣는다
        try zip.addFile("word/document.xml", from: bodyURL, method: 8, crc: body.crc,
                        size: body.byteCount, compressedSize: body.storedCount)
        try zip.finish()
    }
}

// MARK: - 대용량 텍스트·마크다운 변환

enum StreamingText {
    /// 이 크기를 넘으면 조각 단위로 처리한다. (작은 문서는 기존의 정밀한 방식 그대로)
    static let threshold: Int64 = 2 * 1024 * 1024
    /// 경계(빈 줄)를 이만큼 못 찾으면 강제로 자른다.
    private static let forceSplitMarkdownBytes = 8 << 20
    private static let forceSplitPlainBytes = 2 << 20

    static func shouldStream(_ url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return Int64(size) > threshold
    }

    static func convert(_ url: URL, markdown: Bool, key: String, title: String, to out: URL,
                        progress: @escaping ProgressHandler) throws {
        try DiskGuard.check(out.deletingLastPathComponent())
        let reader = try ChunkReader(url: url)
        let emit: (String) throws -> Void
        let finish: () throws -> Void
        var abort: () -> Void = {}

        switch key {
        case "pdf":
            let writer = try DocumentPDF.StreamWriter(url: out, title: title)
            emit = { chunk in
                try writer.add(markdown ? MarkdownRenderer.layoutBlocks(MarkdownParser.parse(chunk))
                                        : PlainRenderer.layoutBlocks(chunk))
            }
            finish = { try writer.finish() }
            abort = { writer.abort() }

        case "html":
            let file = try BufferedWriter(url: out)
            try file.write(HTMLTemplate.head(title: title) + "\n")
            emit = { chunk in
                try file.write((markdown ? MarkdownRenderer.htmlBody(MarkdownParser.parse(chunk))
                                         : PlainRenderer.htmlBody(chunk)) + "\n")
            }
            finish = { try file.write(HTMLTemplate.tail); try file.close() }

        case "txt":
            let file = try BufferedWriter(url: out)
            emit = { chunk in
                let text = markdown ? MarkdownRenderer.plain(MarkdownParser.parse(chunk)) : chunk
                try file.write(text.hasSuffix("\n") ? text + "\n" : text + "\n\n")
            }
            finish = { try file.close() }

        case "rtf", "docx":
            let sink: RichSink
            if key == "rtf" { sink = try RTFSink(url: out) } else { sink = try DocxSink(url: out) }
            emit = { chunk in
                if markdown { try RichFeed.feed(MarkdownParser.parse(chunk), to: sink) }
                else { try RichFeed.feedPlain(chunk, to: sink) }
            }
            finish = { try sink.finish() }

        default:
            throw ConvertError.unsupported("")
        }

        do {
            var carry = ""
            while let piece = try reader.nextPiece() {
                try checkCancelled()
                carry += piece
                let force = carry.utf8.count > (markdown ? forceSplitMarkdownBytes : forceSplitPlainBytes)
                if let (head, rest) = split(carry, markdown: markdown, force: force) {
                    try emit(head)
                    carry = rest
                }
                progress(0.97 * reader.fraction)
            }
            if !carry.isEmpty { try emit(carry) }
            try finish()
        } catch {
            abort()
            throw error
        }
    }

    /// 문단 경계(빈 줄, 코드 블록 안은 제외)에서 앞부분과 나머지로 나눈다. 경계가 없으면 nil.
    /// force가 true면 경계가 없어도 전부 내보낸다 (코드 블록 안이면 코드 블록을 둘로 나눔).
    static func split(_ text: String, markdown: Bool, force: Bool) -> (head: String, rest: String)? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() } // 끝의 개행이 만든 빈 조각
        guard !lines.isEmpty else { return nil }

        var fence: String?
        var cut: Int?
        for (i, line) in lines.enumerated() {
            if markdown {
                let t = line.trimmingCharacters(in: .whitespaces)
                if let mark = fence {
                    if t.hasPrefix(mark) { fence = nil }
                    continue
                }
                if t.hasPrefix("```") || t.hasPrefix("~~~") { fence = String(t.prefix(3)); continue }
                if t.isEmpty { cut = i + 1 }
            } else if line.isEmpty {
                cut = i + 1
            }
        }

        if let cut {
            let head = lines[0..<cut].joined(separator: "\n")
            let rest = lines[cut...].joined(separator: "\n")
            return (head, rest.isEmpty ? "" : rest + "\n")
        }
        guard force else { return nil }
        var head = lines.joined(separator: "\n")
        var rest = ""
        if let mark = fence { head += "\n" + mark; rest = mark + "\n" } // 코드 블록을 닫고, 다음 조각에서 다시 연다
        return (head, rest)
    }
}
