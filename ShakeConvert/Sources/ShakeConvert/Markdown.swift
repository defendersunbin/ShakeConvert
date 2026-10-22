import AppKit

// 마크다운 → 블록 구조 → (인쇄용 서식 문자열 / HTML / 일반 텍스트)
// 외부 리소스(이미지, 원격 링크)는 절대 불러오지 않는다. 링크는 http/https/mailto만 링크로 남긴다.

enum ListMarker {
    case bullet
    case number(Int)
    case task(Bool)
}

enum MDBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: ListMarker, level: Int, text: String)
    case quote(String)
    case code(String)
    case rule
    case table(header: [String], rows: [[String]])
}

// MARK: - 파서

enum MarkdownParser {
    static func parse(_ source: String) -> [MDBlock] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [MDBlock] = []
        var para: [String] = []
        var quote: [String] = []

        func flushPara() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))); quote = [] }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 코드 블록 ``` / ~~~
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushPara(); flushQuote()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { flushPara(); flushQuote(); i += 1; continue }

            if let h = heading(trimmed) { flushPara(); flushQuote(); blocks.append(h); i += 1; continue }

            if isRule(trimmed) { flushPara(); flushQuote(); blocks.append(.rule); i += 1; continue }

            if trimmed.hasPrefix(">") {
                flushPara()
                var q = String(trimmed.dropFirst())
                if q.hasPrefix(" ") { q.removeFirst() }
                quote.append(q)
                i += 1
                continue
            }

            if let item = listItem(line) { flushPara(); flushQuote(); blocks.append(item); i += 1; continue }

            // 표: | 가 있는 줄 + 다음 줄이 구분선(|---|---|)
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushPara(); flushQuote()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|") else { break }
                    rows.append(cells(t))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            flushQuote()
            para.append(trimmed)
            i += 1
        }
        flushPara(); flushQuote()
        return blocks
    }

    private static func heading(_ s: String) -> MDBlock? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ s: String) -> Bool {
        let chars = s.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> MDBlock? {
        var spaces = 0
        for ch in line {
            if ch == " " { spaces += 1 } else if ch == "\t" { spaces += 4 } else { break }
        }
        let level = min(spaces / 2, 4)
        let body = line.trimmingCharacters(in: .whitespaces)

        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            let text = String(body.dropFirst(2))
            if text.hasPrefix("[ ] ") { return .listItem(marker: .task(false), level: level, text: String(text.dropFirst(4))) }
            if text.lowercased().hasPrefix("[x] ") { return .listItem(marker: .task(true), level: level, text: String(text.dropFirst(4))) }
            return .listItem(marker: .bullet, level: level, text: text)
        }

        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = body.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") "), let n = Int(digits) else { return nil }
        return .listItem(marker: .number(n), level: level, text: String(rest.dropFirst(2)))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - 인라인 서식 (굵게, 기울임, 코드, 취소선, 링크)

enum Inline {
    struct Span {
        let text: String
        let bold: Bool
        let italic: Bool
        let code: Bool
        let strike: Bool
        let link: URL?
        let isImage: Bool
    }

    static func spans(_ s: String) -> [Span] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: s, options: options) else {
            return [Span(text: s, bold: false, italic: false, code: false, strike: false, link: nil, isImage: false)]
        }
        return parsed.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            let link = run.link.flatMap { isSafe($0) ? $0 : nil }
            return Span(text: String(parsed[run.range].characters),
                        bold: intent.contains(.stronglyEmphasized),
                        italic: intent.contains(.emphasized),
                        code: intent.contains(.code),
                        strike: intent.contains(.strikethrough),
                        link: link,
                        isImage: run.imageURL != nil)
        }
    }

    static func plain(_ s: String) -> String {
        spans(s).map(\.text).joined()
    }

    static func isSafe(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }
}

// MARK: - 인쇄용 서식 (PDF / RTF / DOCX)

enum DocStyle {
    static let ink = NSColor(hex: 0x1F2328)
    static let dim = NSColor(hex: 0x59636E)
    static let accent = NSColor(hex: 0x2F6FD0)
    static let rule = NSColor(hex: 0xD8DCE1)
    static let strongRule = NSColor(hex: 0x1F2328)
    static let codeBackground = NSColor(hex: 0xF5F6F8)
    static let codeBorder = NSColor(hex: 0xE3E6EA)
    static let inlineCode = NSColor(hex: 0xEEF0F3)
    static let tableHeader = NSColor(hex: 0xF0F2F5)
    static let quoteBar = NSColor(hex: 0xC9D1DA)

    static let bodySize: CGFloat = 10.5
    static var body: NSFont { .systemFont(ofSize: bodySize) }
    static var mono: NSFont { .monospacedSystemFont(ofSize: 9.2, weight: .regular) }

    static func paragraph(before: CGFloat = 0, after: CGFloat = 7, lineHeight: CGFloat = 1.35,
                          head: CGFloat = 0, firstHead: CGFloat? = nil,
                          blocks: [NSTextBlock] = [], tabs: [NSTextTab] = []) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.lineHeightMultiple = lineHeight
        p.headIndent = head
        p.firstLineHeadIndent = firstHead ?? head
        p.textBlocks = blocks
        p.tabStops = tabs
        p.lineBreakMode = .byWordWrapping
        return p
    }

    static func block(padding: CGFloat = 0, background: NSColor? = nil,
                      border: CGFloat = 0, borderColor: NSColor? = nil) -> NSTextBlock {
        let b = NSTextBlock()
        if padding > 0 { b.setWidth(padding, type: .absoluteValueType, for: .padding) }
        if border > 0 {
            b.setWidth(border, type: .absoluteValueType, for: .border)
            b.setBorderColor(borderColor)
        }
        b.backgroundColor = background
        return b
    }
}

enum MarkdownRenderer {
    /// 굵게/기울임 적용 (어느 스레드에서나 안전한 글꼴 설명자 방식)
    static func withTraits(_ font: NSFont, _ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    static func inline(_ s: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for span in Inline.spans(s) {
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if span.bold { f = withTraits(f, .bold) }
            if span.italic || span.isImage { f = withTraits(f, .italic) }
            if span.code {
                f = .monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                attrs[.backgroundColor] = DocStyle.inlineCode
            }
            if span.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if span.isImage { attrs[.foregroundColor] = DocStyle.dim }
            if let link = span.link {
                attrs[.link] = link
                attrs[.foregroundColor] = DocStyle.accent
            }
            attrs[.font] = f
            let text = span.isImage ? L("[이미지: %@]", span.text) : span.text
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }

    private static func appendParagraph(_ s: NSMutableAttributedString, style: NSParagraphStyle,
                                        font: NSFont, to out: NSMutableAttributedString) {
        s.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        s.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: s.length))
        out.append(s)
    }

    static func attributed(_ blocks: [MDBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var previousWasList = false

        for block in blocks {
            var isList = false
            let gap: CGFloat = previousWasList ? 6 : 0

            switch block {
            case let .heading(level, text):
                let sizes: [CGFloat] = [22, 16.5, 13.5, 12, 11, 10.5]
                let font = NSFont.systemFont(ofSize: sizes[level - 1], weight: level <= 2 ? .bold : .semibold)
                var decor: [NSTextBlock] = []
                if level <= 2 {
                    // 제목 아래 구분선 (H1 진하게, H2 연하게)
                    let b = NSTextBlock()
                    b.setWidth(level == 1 ? 1.2 : 0.6, type: .absoluteValueType, for: .border, edge: .maxY)
                    b.setBorderColor(level == 1 ? DocStyle.strongRule : DocStyle.rule, for: .maxY)
                    b.setWidth(5, type: .absoluteValueType, for: .padding, edge: .maxY)
                    b.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
                    decor = [b]
                }
                let style = DocStyle.paragraph(before: (level == 1 ? 16 : 12) + gap,
                                               after: level <= 2 ? 4 : 5, lineHeight: 1.15, blocks: decor)
                appendParagraph(inline(text, font: font, color: DocStyle.ink), style: style, font: font, to: out)

            case let .paragraph(text):
                appendParagraph(inline(text, font: DocStyle.body, color: DocStyle.ink),
                                style: DocStyle.paragraph(before: gap, after: 8),
                                font: DocStyle.body, to: out)

            case let .listItem(marker, level, text):
                isList = true
                let indent = 20 + CGFloat(level) * 16
                let markerText: String
                switch marker {
                case .bullet: markerText = level % 2 == 0 ? "•" : "◦"
                case .number(let n): markerText = "\(n)."
                case .task(let done): markerText = done ? "☑" : "☐"
                }
                let s = NSMutableAttributedString(string: markerText + "\t",
                                                  attributes: [.font: DocStyle.body, .foregroundColor: DocStyle.dim])
                s.append(inline(text, font: DocStyle.body, color: DocStyle.ink))
                let style = DocStyle.paragraph(after: 3, head: indent, firstHead: indent - 16,
                                               tabs: [NSTextTab(textAlignment: .left, location: indent)])
                appendParagraph(s, style: style, font: DocStyle.body, to: out)

            case let .quote(text):
                let b = NSTextBlock()
                b.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                b.setBorderColor(DocStyle.quoteBar, for: .minX)
                b.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                b.setWidth(3, type: .absoluteValueType, for: .padding, edge: .minY)
                b.setWidth(3, type: .absoluteValueType, for: .padding, edge: .maxY)
                b.setWidth(8, type: .absoluteValueType, for: .margin, edge: .maxY)
                appendParagraph(inline(text, font: DocStyle.body, color: DocStyle.dim),
                                style: DocStyle.paragraph(before: gap, after: 0, blocks: [b]),
                                font: DocStyle.body, to: out)

            case let .code(code):
                // 같은 NSTextBlock 인스턴스를 공유하는 연속 문단은 하나의 상자로 그려진다
                let b = DocStyle.block(padding: 10, background: DocStyle.codeBackground,
                                       border: 0.75, borderColor: DocStyle.codeBorder)
                b.setWidth(10, type: .absoluteValueType, for: .margin, edge: .maxY)
                b.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .minY)
                let style = DocStyle.paragraph(after: 0, lineHeight: 1.2, blocks: [b])
                let lines = code.isEmpty ? [" "] : code.components(separatedBy: "\n")
                for line in lines {
                    let s = NSMutableAttributedString(string: line.isEmpty ? " " : line,
                                                      attributes: [.font: DocStyle.mono, .foregroundColor: DocStyle.ink])
                    appendParagraph(s, style: style, font: DocStyle.mono, to: out)
                }

            case .rule:
                let b = NSTextBlock()
                b.setWidth(0.75, type: .absoluteValueType, for: .border, edge: .maxY)
                b.setBorderColor(DocStyle.rule, for: .maxY)
                b.setWidth(8, type: .absoluteValueType, for: .margin, edge: .minY)
                b.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
                let tiny = NSFont.systemFont(ofSize: 2)
                appendParagraph(NSMutableAttributedString(string: "\u{200B}", attributes: [.font: tiny]),
                                style: DocStyle.paragraph(after: 0, lineHeight: 1, blocks: [b]),
                                font: tiny, to: out)

            case let .table(header, rows):
                let columns = min(max(header.count, rows.map(\.count).max() ?? 0), 20)
                guard columns > 0 else { break }
                let table = NSTextTable()
                table.numberOfColumns = columns
                table.collapsesBorders = true
                table.layoutAlgorithm = .automaticLayoutAlgorithm
                table.setContentWidth(100, type: .percentageValueType)
                table.setWidth(10, type: .absoluteValueType, for: .margin, edge: .maxY)
                table.setWidth(4 + gap, type: .absoluteValueType, for: .margin, edge: .minY)

                let small = NSFont.systemFont(ofSize: 9.8)
                let smallBold = NSFont.systemFont(ofSize: 9.8, weight: .semibold)
                for (r, row) in ([header] + rows).enumerated() {
                    for c in 0..<columns {
                        let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                                    startingColumn: c, columnSpan: 1)
                        cell.setWidth(0.6, type: .absoluteValueType, for: .border)
                        cell.setBorderColor(DocStyle.rule)
                        cell.setWidth(5, type: .absoluteValueType, for: .padding)
                        if r == 0 { cell.backgroundColor = DocStyle.tableHeader }
                        let font = r == 0 ? smallBold : small
                        let text = c < row.count ? row[c] : ""
                        appendParagraph(inline(text.isEmpty ? " " : text, font: font, color: DocStyle.ink),
                                        style: DocStyle.paragraph(after: 0, lineHeight: 1.2, blocks: [cell]),
                                        font: font, to: out)
                    }
                }
            }
            previousWasList = isList
        }
        return out
    }

    // MARK: PDF 조판용 블록 (DocumentPDF 엔진)

    static func markerText(_ marker: ListMarker, level: Int) -> String {
        switch marker {
        case .bullet: return level % 2 == 0 ? "•" : "◦"
        case .number(let n): return "\(n)."
        case .task(let done): return done ? "☑" : "☐"
        }
    }

    static func layoutBlocks(_ blocks: [MDBlock]) -> [DocBlock] {
        let sizes: [CGFloat] = [22, 16.5, 13.5, 12, 11, 10.5]
        let small = NSFont.systemFont(ofSize: 9.8)
        let smallBold = NSFont.systemFont(ofSize: 9.8, weight: .semibold)
        return blocks.map { block -> DocBlock in
            switch block {
            case let .heading(level, text):
                let font = NSFont.systemFont(ofSize: sizes[level - 1], weight: level <= 2 ? .bold : .semibold)
                return .heading(level: level, text: inline(text, font: font, color: DocStyle.ink))
            case let .paragraph(text):
                return .paragraph(inline(text, font: DocStyle.body, color: DocStyle.ink), style: ParaStyle())
            case let .listItem(marker, level, text):
                return .listItem(marker: markerText(marker, level: level), level: level,
                                 text: inline(text, font: DocStyle.body, color: DocStyle.ink))
            case let .quote(text):
                return .quote(inline(text, font: DocStyle.body, color: DocStyle.dim))
            case let .code(code):
                return .code(code)
            case .rule:
                return .rule
            case let .table(header, rows):
                return .table(header: header.map { inline($0.isEmpty ? " " : $0, font: smallBold, color: DocStyle.ink) },
                              rows: rows.map { row in row.map { inline($0.isEmpty ? " " : $0, font: small, color: DocStyle.ink) } })
            }
        }
    }

    // MARK: HTML (스타일 포함, 라이트/다크 대응, 외부 리소스 금지)

    static func escape(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            case "'": r += "&#39;"
            default: r.append(ch)
            }
        }
        return r
    }

    static func inlineHTML(_ s: String) -> String {
        Inline.spans(s).map { span in
            var t = escape(span.isImage ? L("[이미지: %@]", span.text) : span.text)
            if span.code { t = "<code>\(t)</code>" }
            if span.bold { t = "<strong>\(t)</strong>" }
            if span.italic || span.isImage { t = "<em>\(t)</em>" }
            if span.strike { t = "<del>\(t)</del>" }
            if let link = span.link {
                t = "<a href=\"\(escape(link.absoluteString))\" rel=\"noopener noreferrer\">\(t)</a>"
            }
            return t
        }.joined()
    }

    static func html(_ blocks: [MDBlock], title: String) -> String {
        var body = ""
        for block in blocks {
            switch block {
            case let .heading(level, text):
                body += "<h\(level)>\(inlineHTML(text))</h\(level)>\n"
            case let .paragraph(text):
                body += "<p>\(inlineHTML(text))</p>\n"
            case let .listItem(marker, level, text):
                let m: String
                switch marker {
                case .bullet: m = level % 2 == 0 ? "•" : "◦"
                case .number(let n): m = "\(n)."
                case .task(let done): m = done ? "☑" : "☐"
                }
                body += "<div class=\"li\" style=\"margin-left:\(level * 22)px\"><span class=\"m\">\(m)</span><span>\(inlineHTML(text))</span></div>\n"
            case let .quote(text):
                body += "<blockquote>\(inlineHTML(text))</blockquote>\n"
            case let .code(code):
                body += "<pre><code>\(escape(code))</code></pre>\n"
            case .rule:
                body += "<hr>\n"
            case let .table(header, rows):
                body += "<table>\n<thead><tr>" + header.map { "<th>\(inlineHTML($0))</th>" }.joined() + "</tr></thead>\n<tbody>\n"
                for row in rows {
                    body += "<tr>" + row.map { "<td>\(inlineHTML($0))</td>" }.joined() + "</tr>\n"
                }
                body += "</tbody></table>\n"
            }
        }
        return HTMLTemplate.page(title: title, body: body)
    }

    // MARK: 일반 텍스트

    static func plain(_ blocks: [MDBlock]) -> String {
        var out: [String] = []
        var previousWasList = false
        for block in blocks {
            var isList = false
            switch block {
            case let .heading(level, text):
                let t = Inline.plain(text)
                if !out.isEmpty { out.append("") }
                out.append(t)
                if level <= 2 { out.append(String(repeating: level == 1 ? "=" : "-", count: min(max(t.count, 3), 60))) }
                out.append("")
            case let .paragraph(text):
                if previousWasList { out.append("") }
                out.append(Inline.plain(text))
                out.append("")
            case let .listItem(marker, level, text):
                isList = true
                let m: String
                switch marker {
                case .bullet: m = "•"
                case .number(let n): m = "\(n)."
                case .task(let done): m = done ? "[x]" : "[ ]"
                }
                out.append(String(repeating: "  ", count: level) + m + " " + Inline.plain(text))
            case let .quote(text):
                out.append("│ " + Inline.plain(text))
                out.append("")
            case let .code(code):
                out.append(contentsOf: code.components(separatedBy: "\n").map { "    " + $0 })
                out.append("")
            case .rule:
                out.append(String(repeating: "─", count: 40))
                out.append("")
            case let .table(header, rows):
                out.append(header.map(Inline.plain).joined(separator: " | "))
                out.append(header.map { _ in "---" }.joined(separator: " | "))
                for row in rows { out.append(row.map(Inline.plain).joined(separator: " | ")) }
                out.append("")
            }
            previousWasList = isList
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: - 일반 텍스트(txt) → 서식

enum PlainRenderer {
    /// PDF 조판용: 줄마다 문단, 빈 줄은 간격으로
    static func layoutBlocks(_ text: String) -> [DocBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let style = ParaStyle(lineHeight: 1.35, spaceAfter: 2)
        return normalized.components(separatedBy: "\n").map { line -> DocBlock in
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                return .spacer(DocStyle.bodySize * 1.35)
            }
            return .paragraph(NSAttributedString(string: line, attributes: [.font: DocStyle.body,
                                                                             .foregroundColor: DocStyle.ink]),
                              style: style)
        }
    }

    static func attributed(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let style = DocStyle.paragraph(after: 2, lineHeight: 1.35)
        let attrs: [NSAttributedString.Key: Any] = [.font: DocStyle.body, .foregroundColor: DocStyle.ink, .paragraphStyle: style]
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        out.append(NSAttributedString(string: normalized.hasSuffix("\n") ? normalized : normalized + "\n", attributes: attrs))
        return out
    }

    static func html(_ text: String, title: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .map { "<p>" + MarkdownRenderer.escape($0).replacingOccurrences(of: "\n", with: "<br>") + "</p>" }
        return HTMLTemplate.page(title: title, body: paragraphs.joined(separator: "\n"))
    }
}

enum HTMLTemplate {
    static func page(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="\(AppLanguage.current)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <meta name="generator" content="ShakeConvert">
        <title>\(MarkdownRenderer.escape(title))</title>
        <style>
        :root { color-scheme: light dark; --ink:#1f2328; --dim:#59636e; --rule:#d8dce1; --soft:#f0f2f5; --code:#f5f6f8; --accent:#2f6fd0; --bg:#ffffff; }
        @media (prefers-color-scheme: dark) { :root { --ink:#f2efe8; --dim:#9aa0a8; --rule:#34363c; --soft:#1e1f23; --code:#1a1b1e; --accent:#7cc4ff; --bg:#141416; } }
        * { box-sizing: border-box; }
        body { margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.7 -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Segoe UI", sans-serif; }
        main { max-width: 760px; margin: 0 auto; padding: 56px 28px 80px; }
        header.doc { font-size: 12px; color: var(--dim); letter-spacing: .02em; border-bottom: 1px solid var(--rule); padding-bottom: 10px; margin-bottom: 32px; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.3; margin: 1.6em 0 .6em; }
        h1 { font-size: 30px; border-bottom: 1.5px solid var(--ink); padding-bottom: 8px; margin-top: 0; }
        h2 { font-size: 22px; border-bottom: 1px solid var(--rule); padding-bottom: 6px; }
        p { margin: 0 0 1em; }
        a { color: var(--accent); }
        code { font: .9em ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--soft); border-radius: 4px; padding: 1px 5px; }
        pre { background: var(--code); border: 1px solid var(--rule); border-radius: 8px; padding: 14px 16px; overflow: auto; }
        pre code { background: none; padding: 0; font-size: 13px; line-height: 1.55; }
        blockquote { margin: 0 0 1em; padding: 4px 16px; border-left: 3px solid var(--rule); color: var(--dim); }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 28px 0; }
        table { border-collapse: collapse; width: 100%; margin: 0 0 1.2em; font-size: 14px; }
        th, td { border: 1px solid var(--rule); padding: 7px 10px; text-align: left; vertical-align: top; }
        th { background: var(--soft); font-weight: 600; }
        .li { display: flex; gap: 10px; margin-bottom: .25em; }
        .li .m { color: var(--dim); min-width: 1.2em; }
        </style>
        </head>
        <body><main>
        <header class="doc">\(MarkdownRenderer.escape(title))</header>
        \(body)
        </main></body>
        </html>
        """
    }
}
