import AppKit
import CoreText

// 문서 → PDF 조판 엔진 (Core Text 기반 자체 레이아웃)
//
// 이전에는 AppKit TextKit(NSTextBlock/NSTextTable)으로 조판했는데, 코드 상자나 표가 페이지 경계에
// 걸리면 레이아웃 호출이 끝나지 않는 경우가 있었다(변환이 특정 %에서 멈춤). 그래서 직접 배치한다:
//   1) 블록(제목·문단·목록·인용·코드·표…)을 줄/행 단위 "조각"으로 나눈다
//   2) 조각을 위에서부터 차례로 페이지에 놓는다 — 한 번에 하나씩 놓으므로 반드시 끝난다
//   3) 페이지마다 장식(코드 상자 배경, 인용 막대)을 먼저 그리고, 그 위에 글자를 그린다
// Core Text는 스레드 안전하므로 변환 작업 스레드에서 실행해도 된다.

/// 조판 단위 블록
enum DocBlock {
    case heading(level: Int, text: NSAttributedString)
    case paragraph(NSAttributedString, style: ParaStyle)
    case listItem(marker: String, level: Int, text: NSAttributedString)
    case quote(NSAttributedString)
    case code(String)
    case rule
    case table(header: [NSAttributedString], rows: [[NSAttributedString]])
    case spacer(CGFloat)
}

struct ParaStyle {
    var lineHeight: CGFloat = 1.35
    var spaceAfter: CGFloat = 8
    var headIndent: CGFloat = 0
    var firstIndent: CGFloat = 0
    var alignment: NSTextAlignment = .left
}

enum DocumentPDF {
    static let maxPages = 3000
    
    // MARK: 조각

    fileprivate enum DecoKind { case codeBox, quoteBar }

    fileprivate struct Deco {
        let id: Int
        let kind: DecoKind
    }

    fileprivate struct Fragment {
        var height: CGFloat
        var isSpacer = false            // 페이지 맨 위나 페이지 끝에서는 버려도 되는 간격
        var keepWithNext: CGFloat = 0   // 이 조각 뒤에 최소한 이만큼 공간이 있어야 같은 페이지에 둠 (제목)
        var baselineFromTop: CGFloat = 0
        var deco: Deco?
        /// (컨텍스트, 본문 왼쪽 x, 조각 위쪽 y) — PDF 좌표(아래가 0)
        var draw: (CGContext, CGFloat, CGFloat) -> Void = { _, _, _ in }
    }

    fileprivate struct Placed {
        let fragment: Fragment
        let top: CGFloat
    }

    // MARK: 진입점

    static func render(blocks: [DocBlock], title: String, to url: URL,
                       progress: ProgressHandler = { _ in }) throws {
        let paper = Prefs.paperSize.size
        let marginTop: CGFloat = 78, marginBottom: CGFloat = 74, marginLeft: CGFloat = 64, marginRight: CGFloat = 64
        let width = paper.width - marginLeft - marginRight

        // 1) 블록 → 조각 (0~30%)
        var fragments: [Fragment] = []
        var decoCounter = 0
        let content = blocks.isEmpty ? [DocBlock.paragraph(NSAttributedString(string: " "), style: ParaStyle())] : blocks
        for (i, block) in content.enumerated() {
            try checkCancelled()
            fragments += makeFragments(block, width: width, nextDeco: &decoCounter)
            progress(0.3 * Double(i + 1) / Double(content.count))
        }

        // 2) 페이지에 배치 — 조각을 하나씩 놓으므로 항상 끝난다
        let top = paper.height - marginTop
        let bottom = marginBottom
        var pages: [[Placed]] = [[]]
        var cursor = top
        for f in fragments {
            let pageEmpty = pages[pages.count - 1].isEmpty
            if f.isSpacer && pageEmpty { continue }
            let need = f.height + (f.isSpacer ? 0 : f.keepWithNext)
            if cursor - need < bottom && !pageEmpty {
                if f.isSpacer { continue }
                pages.append([])
                cursor = top
                if pages.count > maxPages { throw ConvertError.tooManyPages }
            }
            pages[pages.count - 1].append(Placed(fragment: f, top: cursor))
            cursor -= f.height
        }

        // 3) 그리기 (30~100%)
        var mediaBox = CGRect(origin: .zero, size: paper)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "ShakeConvert"]
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ConvertError.writeFailed("")
        }
        let date = DateFormatter()
        date.locale = Locale(identifier: AppLanguage.current)
        date.dateStyle = .medium
        date.timeStyle = .none
        let dateText = date.string(from: Date())
        let bodyRect = CGRect(x: marginLeft - 2, y: bottom - 2, width: width + 4, height: top - bottom + 4)

        for (index, page) in pages.enumerated() {
            if Task.isCancelled {
                ctx.closePDF()
                throw CancellationError()
            }
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity

            ctx.saveGState()
            ctx.clip(to: bodyRect) // 한 페이지보다 큰 조각은 본문 영역 밖으로 넘치지 않게
            drawDecorations(page, ctx: ctx, left: marginLeft, width: width)
            for p in page { p.fragment.draw(ctx, marginLeft, p.top) }
            ctx.restoreGState()

            drawChrome(ctx: ctx, page: index + 1, total: pages.count, title: title, date: dateText,
                       paper: paper, left: marginLeft, right: paper.width - marginRight,
                       top: top, bottom: bottom)
            ctx.endPDFPage()
            progress(0.3 + 0.7 * Double(index + 1) / Double(pages.count))
        }
        ctx.closePDF()
    }

    // MARK: 블록 → 조각

    private static func makeFragments(_ block: DocBlock, width: CGFloat, nextDeco: inout Int) -> [Fragment] {
        switch block {
        case let .heading(level, text):
            var out = [Fragment(height: level == 1 ? 14 : 10, isSpacer: true)]
            var lines = lineFragments(text, width: width, style: ParaStyle(lineHeight: 1.15, spaceAfter: 0))
            if !lines.isEmpty { lines[lines.count - 1].keepWithNext = 42 } // 제목만 페이지 끝에 홀로 남지 않게
            out += lines
            if level <= 2 {
                let color = level == 1 ? DocStyle.strongRule : DocStyle.rule
                let weight: CGFloat = level == 1 ? 1.2 : 0.6
                out.append(Fragment(height: 9, draw: { ctx, x, top in
                    hline(ctx, x: x, width: width, y: top - 5, weight: weight, color: color)
                }))
            }
            out.append(Fragment(height: level <= 2 ? 6 : 4, isSpacer: true))
            return out

        case let .paragraph(text, style):
            return lineFragments(text, width: width, style: style) + [Fragment(height: style.spaceAfter, isSpacer: true)]

        case let .listItem(marker, level, text):
            let indent = 20 + CGFloat(level) * 16
            var lines = lineFragments(text, width: width,
                                      style: ParaStyle(lineHeight: 1.35, spaceAfter: 0, headIndent: indent, firstIndent: indent))
            if !lines.isEmpty {
                let markerLine = CTLineCreateWithAttributedString(coreTextReady(NSAttributedString(
                    string: marker, attributes: [.font: DocStyle.body, .foregroundColor: DocStyle.dim])))
                let firstDraw = lines[0].draw
                let baseline = lines[0].baselineFromTop
                lines[0].draw = { ctx, x, top in
                    firstDraw(ctx, x, top)
                    drawLine(markerLine, ctx: ctx, x: x + indent - 16, baseline: top - baseline)
                }
            }
            return lines + [Fragment(height: 3, isSpacer: true)]

        case let .quote(text):
            nextDeco += 1
            let deco = Deco(id: nextDeco, kind: .quoteBar)
            let lines = lineFragments(text, width: width, style: ParaStyle(lineHeight: 1.35, spaceAfter: 0),
                                      xOffset: 14, deco: deco)
            return [Fragment(height: 2, deco: deco)] + lines + [Fragment(height: 2, deco: deco),
                                                                  Fragment(height: 8, isSpacer: true)]

        case let .code(code):
            nextDeco += 1
            let deco = Deco(id: nextDeco, kind: .codeBox)
            let pad: CGFloat = 10
            var out = [Fragment(height: 2, isSpacer: true), Fragment(height: pad, deco: deco)]
            let style = ParaStyle(lineHeight: 1.25, spaceAfter: 0)
            for line in (code.isEmpty ? " " : code).components(separatedBy: "\n") {
                let attr = NSAttributedString(string: line.isEmpty ? " " : line,
                                              attributes: [.font: DocStyle.mono, .foregroundColor: DocStyle.ink])
                out += lineFragments(attr, width: width - pad, style: style, xOffset: pad, deco: deco)
            }
            out.append(Fragment(height: pad, deco: deco))
            out.append(Fragment(height: 10, isSpacer: true))
            return out

        case .rule:
            return [Fragment(height: 6, isSpacer: true),
                    Fragment(height: 10, draw: { ctx, x, top in
                        hline(ctx, x: x, width: width, y: top - 5, weight: 0.75, color: DocStyle.rule)
                    }),
                    Fragment(height: 8, isSpacer: true)]

        case let .table(header, rows):
            return tableFragments(header: header, rows: rows, width: width)

        case let .spacer(h):
            return [Fragment(height: h, isSpacer: true)]
        }
    }

    /// 문단을 줄 조각으로. 줄마다 한 조각이므로 페이지 경계 어디서든 나뉠 수 있다.
    private static func lineFragments(_ text: NSAttributedString, width: CGFloat, style: ParaStyle,
                                      xOffset: CGFloat = 0, deco: Deco? = nil) -> [Fragment] {
        let items = breakLines(text, width: width - xOffset, firstIndent: style.firstIndent, headIndent: style.headIndent)
        if items.isEmpty {
            return [Fragment(height: DocStyle.bodySize * style.lineHeight, deco: deco)]
        }
        return items.map { item in
            let m = metrics(item.line)
            let glyphHeight = m.ascent + m.descent
            let height = max(glyphHeight + m.leading, glyphHeight * style.lineHeight)
            let baseline = (height - glyphHeight) / 2 + m.ascent
            let line = item.line
            let indent = item.indent
            let available = width - xOffset - indent
            let alignment = style.alignment
            return Fragment(height: height, baselineFromTop: baseline, deco: deco, draw: { ctx, x, top in
                var pen = x + xOffset + indent
                if alignment == .center || alignment == .right {
                    pen += CGFloat(CTLineGetPenOffsetForFlush(line, alignment == .center ? 0.5 : 1, Double(available)))
                }
                drawLine(line, ctx: ctx, x: pen, baseline: top - baseline)
            })
        }
    }

    private static func tableFragments(header: [NSAttributedString], rows: [[NSAttributedString]],
                                       width: CGFloat) -> [Fragment] {
        let all = [header] + rows
        let columns = min(max(all.map(\.count).max() ?? 0, 1), 20)
        let pad: CGFloat = 5

        // 열 너비: 내용 길이에 비례하되 너무 좁은 열은 최소 폭 보장
        var natural = [CGFloat](repeating: 24, count: columns)
        for row in all {
            for c in 0..<min(row.count, columns) {
                let w = metrics(CTLineCreateWithAttributedString(coreTextReady(row[c]))).width + 2 * pad
                natural[c] = max(natural[c], min(w, width))
            }
        }
        let naturalTotal = natural.reduce(0, +)
        var widths = natural.map { max($0 / naturalTotal * width, min(48, width / CGFloat(columns))) }
        let scale = width / widths.reduce(0, +)
        widths = widths.map { $0 * scale }

        var out = [Fragment(height: 4, isSpacer: true)]
        for (r, row) in all.enumerated() {
            var cells: [[(line: CTLine, baseline: CGFloat)]] = []
            var rowHeight: CGFloat = 20
            for c in 0..<columns {
                let text = c < row.count ? row[c] : NSAttributedString(string: "")
                var y = pad
                var placed: [(line: CTLine, baseline: CGFloat)] = []
                for item in breakLines(text, width: widths[c] - 2 * pad, firstIndent: 0, headIndent: 0) {
                    let m = metrics(item.line)
                    let glyphHeight = m.ascent + m.descent
                    let h = glyphHeight * 1.25
                    placed.append((item.line, y + (h - glyphHeight) / 2 + m.ascent))
                    y += h
                }
                cells.append(placed)
                rowHeight = max(rowHeight, y + pad)
            }
            let isHeader = r == 0
            let columnWidths = widths
            let h = rowHeight
            out.append(Fragment(height: h, draw: { ctx, x, top in
                var cx = x
                for c in 0..<columns {
                    let rect = CGRect(x: cx, y: top - h, width: columnWidths[c], height: h)
                    if isHeader {
                        ctx.setFillColor(DocStyle.tableHeader.cgColor)
                        ctx.fill(rect)
                    }
                    ctx.setStrokeColor(DocStyle.rule.cgColor)
                    ctx.setLineWidth(0.6)
                    ctx.stroke(rect)
                    for cell in cells[c] {
                        drawLine(cell.line, ctx: ctx, x: cx + pad, baseline: top - cell.baseline)
                    }
                    cx += columnWidths[c]
                }
            }))
        }
        out.append(Fragment(height: 10, isSpacer: true))
        return out
    }

    // MARK: 줄 나누기 · 그리기

    private static func breakLines(_ text: NSAttributedString, width: CGFloat,
                                   firstIndent: CGFloat, headIndent: CGFloat) -> [(line: CTLine, indent: CGFloat)] {
        let attr = coreTextReady(text)
        let length = attr.length
        guard length > 0 else { return [] }
        let typesetter = CTTypesetterCreateWithAttributedString(attr)
        var result: [(line: CTLine, indent: CGFloat)] = []
        var start = 0
        while start < length {
            let indent = result.isEmpty ? firstIndent : headIndent
            let available = Double(max(width - indent, 24))
            var count = CTTypesetterSuggestLineBreak(typesetter, start, available)
            if count <= 0 { count = CTTypesetterSuggestClusterBreak(typesetter, start, available) }
            if count <= 0 { count = 1 } // 어떤 경우에도 앞으로 나아간다
            result.append((CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)), indent))
            start += count
        }
        return result
    }

    private static func metrics(_ line: CTLine) -> (ascent: CGFloat, descent: CGFloat, leading: CGFloat, width: CGFloat) {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (ascent, descent, leading, CGFloat(width))
    }

    /// 인라인 코드 배경·취소선은 Core Text가 그리지 않으므로 직접 그린 뒤 글자를 그린다
    private static func drawLine(_ line: CTLine, ctx: CGContext, x: CGFloat, baseline: CGFloat) {
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let range = CTRunGetStringRange(run)
            let offset = CTLineGetOffsetForStringIndex(line, range.location, nil)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let w = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil))
            if let bg = attrs[NSAttributedString.Key.backgroundColor.rawValue] as? NSColor {
                ctx.setFillColor(bg.cgColor)
                let rect = CGRect(x: x + offset - 1.5, y: baseline - descent - 1, width: w + 3, height: ascent + descent + 2)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
                ctx.fillPath()
            }
            if let strike = attrs[NSAttributedString.Key.strikethroughStyle.rawValue] as? NSNumber, strike.intValue != 0 {
                let color = (attrs[NSAttributedString.Key.foregroundColor.rawValue] as? NSColor) ?? DocStyle.ink
                hline(ctx, x: x + offset, width: w, y: baseline + ascent * 0.3, weight: 0.8, color: color)
            }
        }
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
    }

    private static func hline(_ ctx: CGContext, x: CGFloat, width: CGFloat, y: CGFloat, weight: CGFloat, color: NSColor) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(weight)
        ctx.move(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: x + width, y: y))
        ctx.strokePath()
    }

    private static let ctColorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    /// Core Text용 준비: 글꼴이 없으면 본문 글꼴, 글자색은 고정 색(CGColor)으로.
    /// 시스템 동적 색(다크 모드에서 흰색이 되는 색)은 인쇄물에서 안 보일 수 있어 기본 잉크색으로 바꾼다.
    static func coreTextReady(_ text: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: m.length)
        guard full.length > 0 else { return m }
        var missingFont: [NSRange] = []
        m.enumerateAttribute(.font, in: full) { value, range, _ in
            if value == nil { missingFont.append(range) }
        }
        for r in missingFont { m.addAttribute(.font, value: DocStyle.body, range: r) }

        var colors: [(NSRange, CGColor)] = []
        m.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            var color = DocStyle.ink
            if let c = value as? NSColor, c.type != .catalog, let srgb = c.usingColorSpace(.sRGB) { color = srgb }
            colors.append((range, color.cgColor))
        }
        for (r, c) in colors { m.addAttribute(ctColorKey, value: c, range: r) }
        return m
    }

    // MARK: 장식 · 머리글 · 바닥글

    private static func drawDecorations(_ page: [Placed], ctx: CGContext, left: CGFloat, width: CGFloat) {
        var spans: [Int: (kind: DecoKind, top: CGFloat, bottom: CGFloat)] = [:]
        for p in page {
            guard let deco = p.fragment.deco else { continue }
            let bottom = p.top - p.fragment.height
            if let s = spans[deco.id] {
                spans[deco.id] = (s.kind, max(s.top, p.top), min(s.bottom, bottom))
            } else {
                spans[deco.id] = (deco.kind, p.top, bottom)
            }
        }
        for span in spans.values {
            let rect = CGRect(x: left, y: span.bottom, width: width, height: span.top - span.bottom)
            switch span.kind {
            case .codeBox:
                let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
                ctx.setFillColor(DocStyle.codeBackground.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
                ctx.setStrokeColor(DocStyle.codeBorder.cgColor)
                ctx.setLineWidth(0.75)
                ctx.addPath(path)
                ctx.strokePath()
            case .quoteBar:
                ctx.setFillColor(DocStyle.quoteBar.cgColor)
                ctx.fill(CGRect(x: left, y: rect.minY, width: 3, height: rect.height))
            }
        }
    }

    private static func chromeLine(_ s: String, digits: Bool = false) -> CTLine {
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
                          : NSFont.systemFont(ofSize: 8.5, weight: .medium)
        return CTLineCreateWithAttributedString(coreTextReady(NSAttributedString(
            string: s, attributes: [.font: font, .foregroundColor: DocStyle.dim])))
    }

    private static func drawChrome(ctx: CGContext, page: Int, total: Int?, title: String, date: String,
                                   paper: CGSize, left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        // 머리글: 포인트 막대 + 제목(왼쪽) · 날짜(오른쪽) + 구분선
        let headerRule = top + 14
        let headerBaseline = headerRule + 8
        ctx.setFillColor(DocStyle.accent.cgColor)
        ctx.fill(CGRect(x: left, y: headerBaseline + 12, width: 18, height: 2))

        let shownTitle = title.count > 70 ? String(title.prefix(68)) + "…" : title
        drawLine(chromeLine(shownTitle), ctx: ctx, x: left, baseline: headerBaseline)
        let dateLine = chromeLine(date)
        drawLine(dateLine, ctx: ctx, x: right - metrics(dateLine).width, baseline: headerBaseline)
        hline(ctx, x: left, width: right - left, y: headerRule, weight: 0.5, color: DocStyle.rule)

        // 바닥글: 구분선 + 가운데 쪽 번호
        let footerRule = bottom - 20
        hline(ctx, x: left, width: right - left, y: footerRule, weight: 0.5, color: DocStyle.rule)
        let pageLine = chromeLine(total.map { "\(page) / \($0)" } ?? "\(page)", digits: true)
        drawLine(pageLine, ctx: ctx, x: (paper.width - metrics(pageLine).width) / 2, baseline: footerRule - 14)
    }
}

// MARK: - 일반 서식 문서(RTF/DOCX) → 블록

extension DocumentPDF {
    /// 문단 단위로 나누고, 각 문단의 정렬·들여쓰기·간격을 살린다. 문서 안의 표/텍스트 블록 지정은 일반 문단으로 다룬다.
    static func blocks(from attributed: NSAttributedString) -> [DocBlock] {
        var out: [DocBlock] = []
        let ns = attributed.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            if range.length == 0 {
                out.append(.spacer(DocStyle.bodySize * 1.3))
                return
            }
            let sub = attributed.attributedSubstring(from: range)
            var style = ParaStyle(lineHeight: 1.25, spaceAfter: 4)
            if let ps = sub.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                style.alignment = ps.alignment
                style.firstIndent = ps.firstLineHeadIndent
                style.headIndent = ps.headIndent
                style.spaceAfter = max(ps.paragraphSpacing, 2)
                if ps.lineHeightMultiple > 0 { style.lineHeight = ps.lineHeightMultiple }
            }
            out.append(.paragraph(sub, style: style))
        }
        return out
    }
}


// MARK: - 대용량 문서: 페이지를 만드는 즉시 파일에 써 내려가는 조판기

extension DocumentPDF {
    /// 블록을 차례로 받아 페이지가 차면 바로 PDF에 기록하고 메모리에서 비운다.
    /// 문서 길이와 상관없이 메모리에는 "지금 쓰는 한 쪽 + 한 번에 받은 블록 묶음"만 남는다.
    /// 전체 쪽수는 끝나기 전에는 알 수 없으므로 바닥글에는 "n"만 표시한다.
    final class StreamWriter {
        private static let marginTop: CGFloat = 78
        private static let marginBottom: CGFloat = 74
        private static let marginLeft: CGFloat = 64
        private static let marginRight: CGFloat = 64

        private let paper: CGSize
        private let width: CGFloat
        private let top: CGFloat
        private let bottom: CGFloat = StreamWriter.marginBottom
        private let ctx: CGContext
        private let title: String
        private let dateText: String
        private let bodyRect: CGRect
        private var page: [Placed] = []
        private var cursor: CGFloat
        private var pageNumber = 0
        private var decoCounter = 0
        private var closed = false
        private let directory: URL

        init(url: URL, title: String) throws {
            directory = url.deletingLastPathComponent()
            let size = Prefs.paperSize.size
            paper = size
            width = size.width - Self.marginLeft - Self.marginRight
            top = size.height - Self.marginTop
            cursor = size.height - Self.marginTop
            self.title = title
            bodyRect = CGRect(x: Self.marginLeft - 2, y: Self.marginBottom - 2,
                              width: size.width - Self.marginLeft - Self.marginRight + 4,
                              height: size.height - Self.marginTop - Self.marginBottom + 4)
            var box = CGRect(origin: .zero, size: size)
            let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "ShakeConvert"]
            guard let c = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
                throw ConvertError.writeFailed("")
            }
            ctx = c
            let date = DateFormatter()
            date.locale = Locale(identifier: AppLanguage.current)
            date.dateStyle = .medium
            date.timeStyle = .none
            dateText = date.string(from: Date())
        }

        var pagesWritten: Int { pageNumber }

        func add(_ blocks: [DocBlock]) throws {
            for block in blocks {
                try checkCancelled()
                for fragment in DocumentPDF.makeFragments(block, width: width, nextDeco: &decoCounter) {
                    try place(fragment)
                }
            }
        }

        func finish() throws {
            if pageNumber == 0 && page.isEmpty {
                try add([.paragraph(NSAttributedString(string: " "), style: ParaStyle())])
            }
            if !page.isEmpty { try flush() }
            if !closed { ctx.closePDF(); closed = true }
        }

        /// 오류·취소 시 열린 PDF를 닫는다.
        func abort() {
            if !closed { ctx.closePDF(); closed = true }
        }

        private func place(_ f: Fragment) throws {
            let pageEmpty = page.isEmpty
            if f.isSpacer && pageEmpty { return }
            let need = f.height + (f.isSpacer ? 0 : f.keepWithNext)
            if cursor - need < bottom && !pageEmpty {
                if f.isSpacer { return }
                try flush()
            }
            page.append(Placed(fragment: f, top: cursor))
            cursor -= f.height
        }

        private func flush() throws {
            try checkCancelled()
            if pageNumber % 50 == 0 { // 디스크가 가득 차기 전에 깔끔하게 중단
                do { try DiskGuard.check(directory) } catch { abort(); throw error }
            }
            pageNumber += 1
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity
            ctx.saveGState()
            ctx.clip(to: bodyRect)
            DocumentPDF.drawDecorations(page, ctx: ctx, left: Self.marginLeft, width: width)
            for p in page { p.fragment.draw(ctx, Self.marginLeft, p.top) }
            ctx.restoreGState()
            DocumentPDF.drawChrome(ctx: ctx, page: pageNumber, total: nil, title: title, date: dateText,
                                   paper: paper, left: Self.marginLeft, right: paper.width - Self.marginRight,
                                   top: top, bottom: bottom)
            ctx.endPDFPage()
            page.removeAll(keepingCapacity: true)
            cursor = top
        }
    }

    /// 이미 메모리에 있는 블록(RTF/DOCX 입력 등)을 묶음으로 나눠 스트리밍 조판기에 넣는다.
    static func renderStreaming(blocks: [DocBlock], title: String, to url: URL,
                                progress: ProgressHandler = { _ in }) throws {
        let writer = try StreamWriter(url: url, title: title)
        do {
            var start = 0
            while start < blocks.count {
                try checkCancelled()
                let end = min(start + 500, blocks.count)
                try writer.add(Array(blocks[start..<end]))
                progress(Double(end) / Double(blocks.count))
                start = end
            }
            try writer.finish()
        } catch {
            writer.abort()
            throw error
        }
    }
}
