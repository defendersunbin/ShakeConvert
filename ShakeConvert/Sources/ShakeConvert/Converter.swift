import Foundation
import AppKit
import ImageIO
import PDFKit
import AVFoundation
import CoreMedia
import CoreText
import UniformTypeIdentifiers

// 모든 변환은 macOS 시스템 프레임워크만 사용하며 네트워크/외부 프로세스를 쓰지 않는다.

enum ConvertError: LocalizedError {
    case notRegularFile
    case tooLarge
    case tooManyPixels
    case tooManyPages
    case unsupported(String)
    case readFailed
    case locked
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRegularFile: return L("일반 파일만 변환할 수 있습니다 (심볼릭 링크/폴더 제외)")
        case .tooLarge: return L("파일이 너무 큽니다")
        case .tooManyPixels: return L("이미지 해상도가 너무 큽니다")
        case .tooManyPages: return L("페이지 수가 너무 많습니다")
        case .unsupported(let m): return m.isEmpty ? L("지원하지 않는 변환입니다") : m
        case .readFailed: return L("파일을 읽을 수 없습니다")
        case .locked: return L("암호로 보호된 파일입니다")
        case .writeFailed(let m): return m.isEmpty ? L("결과 파일을 저장하지 못했습니다") : L("저장 실패: %@", m)
        }
    }
}

/// 변환 진행률 (0...1). 변환 스레드에서 호출된다.
typealias ProgressHandler = @Sendable (Double) -> Void

/// 취소 요청이 들어왔으면 중단 (변환 중 단계마다 확인)
func checkCancelled() throws {
    if Task.isCancelled { throw CancellationError() }
}

enum Converter {
    /// 변환 후 생성된 파일 URL 목록을 반환한다 (원본은 절대 수정/삭제하지 않음).
    /// 화면이 멈추지 않도록 반드시 메인 스레드가 아닌 곳에서 호출한다 (PanelModel이 별도 작업으로 실행).
    static func convert(_ url: URL, to format: OutputFormat,
                        progress: @escaping ProgressHandler = { _ in }) async throws -> [URL] {
        guard let category = Catalog.kind(of: url), category == format.category else {
            throw ConvertError.unsupported(L("%@: 이 형식으로는 변환할 수 없습니다", url.lastPathComponent))
        }
        try validateInput(url, category: category)
        try checkCancelled()

        let work = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let out = work.appendingPathComponent("out.\(format.ext)")

        switch category {
        case .image:
            try ImageConverter.convert(url, format: format, out: out, progress: progress)
            try checkCancelled()
            return [try finalize(out, source: url, suffix: "", ext: format.ext)]

        case .text:
            try TextConverter.convert(url, key: format.key, to: out, progress: progress)
            try checkCancelled()
            return [try finalize(out, source: url, suffix: "", ext: format.ext)]

        case .pdf:
            let pieces = try PDFConverter.convert(url, format: format, work: work, progress: progress)
            try checkCancelled()
            return try pieces.map { try finalize($0.file, source: url, suffix: $0.suffix, ext: format.ext) }

        case .audio:
            switch format.key {
            case "m4a": try await AVConverter.export(url, preset: AVAssetExportPresetAppleM4A, type: .m4a, out: out, progress: progress)
            case "wav": try await AVConverter.linearPCM(url, type: .wav, out: out, progress: progress)
            case "aiff": try await AVConverter.linearPCM(url, type: .aiff, out: out, progress: progress)
            case "caf": try await AVConverter.linearPCM(url, type: .caf, out: out, progress: progress)
            default: throw ConvertError.unsupported("")
            }
            try checkCancelled()
            return [try finalize(out, source: url, suffix: "", ext: format.ext)]

        case .video:
            switch format.key {
            case "mp4": try await AVConverter.export(url, preset: AVAssetExportPresetHighestQuality, type: .mp4, out: out, progress: progress)
            case "mov": try await AVConverter.export(url, preset: AVAssetExportPresetHighestQuality, type: .mov, out: out, progress: progress)
            case "m4a": try await AVConverter.export(url, preset: AVAssetExportPresetAppleM4A, type: .m4a, out: out, progress: progress)
            default: throw ConvertError.unsupported("")
            }
            try checkCancelled()
            return [try finalize(out, source: url, suffix: "", ext: format.ext)]
        }
    }

    // MARK: 입력 검증

    static func validateInput(_ url: URL, category: Category) throws {
        guard url.isFileURL else { throw ConvertError.notRegularFile }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true || values.isRegularFile != true { throw ConvertError.notRegularFile }
        if let size = values.fileSize, Int64(size) > category.maxInputBytes { throw ConvertError.tooLarge }
    }

    // MARK: 출력 처리

    /// 소유자만 접근 가능한 임시 작업 폴더
    static func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShakeConvert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// 임시 결과물을 저장 위치(설정: 원본 옆 / 다운로드)에 놓는다. 원본 옆에 쓸 수 없으면 다운로드 폴더로.
    ///
    /// 덮어쓰기 방지는 "확인 후 이동"이 아니라 커널의 원자적 연산으로 보장한다:
    /// - 같은 볼륨: renamex_np(RENAME_EXCL) — 대상 이름이 있으면(심볼릭 링크 포함) 실패, 경쟁 조건 없음
    /// - 다른 볼륨: 대상 폴더 안에 무작위 이름으로 복사한 뒤 같은 방식으로 이름 변경
    static func finalize(_ temp: URL, source: URL, suffix: String, ext: String) throws -> URL {
        let fm = FileManager.default
        let base = safeBaseName(source.deletingPathExtension().lastPathComponent + suffix)
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let beside = source.deletingLastPathComponent()
        let dirs = (Prefs.saveLocation == .downloads ? [downloads, beside] : [beside, downloads]).compactMap { $0 }
        var lastError: Error?

        for dir in dirs {
            var from = temp
            var staged: URL?
            defer { if let staged { try? fm.removeItem(at: staged) } } // 실패 시 남은 임시 복사본 정리
            var n = 1
            var placed: URL?

            while n <= 999 {
                let name = n == 1 ? "\(base).\(ext)" : "\(base) \(n).\(ext)"
                let dest = dir.appendingPathComponent(name)
                if renameExclusive(from, to: dest) == 0 {
                    placed = dest
                    break
                }
                let err = errno
                if err == EEXIST { n += 1; continue }
                if err == EXDEV, staged == nil {
                    // 예측할 수 없는 무작위 이름이라 미리 심볼릭 링크를 심어 둘 수 없고, copyItem은 기존 대상을 덮어쓰지 않음
                    let s = dir.appendingPathComponent(".shakeconvert-\(UUID().uuidString).tmp")
                    do {
                        try fm.copyItem(at: temp, to: s)
                        staged = s
                        from = s
                        continue // 같은 이름으로 다시 시도
                    } catch {
                        lastError = error
                        break
                    }
                }
                lastError = POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
                break
            }
            if let placed {
                staged = nil // 이름이 바뀌었으므로 정리 대상 아님
                return placed
            }
        }
        throw ConvertError.writeFailed(lastError?.localizedDescription ?? "")
    }

    /// 대상이 있으면(심볼릭 링크 포함) EEXIST로 실패하는 원자적 이름 변경
    private static func renameExclusive(_ from: URL, to: URL) -> Int32 {
        from.withUnsafeFileSystemRepresentation { f in
            to.withUnsafeFileSystemRepresentation { t in
                renamex_np(f, t, UInt32(RENAME_EXCL))
            }
        }
    }

    /// 출력 파일 이름 정리: 제어 문자·양방향(RLO 등) 문자 제거로 확장자 위장 방지, 길이 제한
    static func safeBaseName(_ raw: String) -> String {
        let bidi: ClosedRange<UInt32> = 0x202A...0x202E
        let isolates: ClosedRange<UInt32> = 0x2066...0x2069
        var scalars = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            let isControl = u.properties.generalCategory == .control
            let isDirectional = bidi.contains(u.value) || isolates.contains(u.value) || u.value == 0x200E || u.value == 0x200F
            if isControl || isDirectional { continue }
            if u == "/" || u == ":" { scalars.append("_"); continue }
            scalars.append(u)
        }
        var name = String(scalars).trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.hasPrefix(".") { name = "converted" + name }
        while name.utf8.count > 200 { name.removeLast() } // 이름 길이 제한(255바이트) 안에 번호·확장자 여유
        return name
    }
}

// MARK: - 이미지

enum ImageConverter {
    static func loadCGImage(_ url: URL) throws -> CGImage {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { throw ConvertError.readFailed }

        // 조작된 헤더의 거대한 가로·세로 값으로 곱셈이 넘쳐 앱이 죽지 않도록 오버플로를 검사
        let (pixels, overflow) = w.multipliedReportingOverflow(by: h)
        if overflow || pixels > 250_000_000 { throw ConvertError.tooManyPixels }

        // 썸네일 API를 원본 크기로 호출하면 EXIF 회전이 적용된 이미지를 얻고, 메타데이터(GPS 등)는 결과에 이어지지 않는다.
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
        else { throw ConvertError.readFailed }
        return img
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// 알파가 있는 이미지를 흰 배경 위에 합성 (JPEG/BMP 변환 시 검은 배경 방지)
    static func flattenOnWhite(_ img: CGImage) throws -> CGImage {
        guard hasAlpha(img) else { return img }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConvertError.writeFailed("") }
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        guard let result = ctx.makeImage() else { throw ConvertError.writeFailed("") }
        return result
    }

    static func writeRaster(_ img: CGImage, uti: String, to url: URL, quality: Double? = nil) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil)
        else { throw ConvertError.unsupported(L("이 Mac에서는 해당 형식으로 저장할 수 없습니다")) }
        var props: [CFString: Any] = [:]
        if let q = quality { props[kCGImageDestinationLossyCompressionQuality] = q }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.writeFailed("") }
    }

    static func encodePNG(_ img: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw ConvertError.writeFailed("") }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.writeFailed("") }
        return data as Data
    }

    static func convert(_ url: URL, format: OutputFormat, out: URL, progress: ProgressHandler) throws {
        progress(0.05)
        let img = try loadCGImage(url)
        progress(0.45)
        try checkCancelled()
        defer { progress(1) }

        switch format.key {
        case "jpeg": try writeRaster(try flattenOnWhite(img), uti: UTType.jpeg.identifier, to: out, quality: Prefs.imageQuality)
        case "png": try writeRaster(img, uti: UTType.png.identifier, to: out)
        case "heic": try writeRaster(img, uti: UTType.heic.identifier, to: out, quality: Prefs.imageQuality)
        case "tiff": try writeRaster(img, uti: UTType.tiff.identifier, to: out)
        case "gif": try writeRaster(img, uti: UTType.gif.identifier, to: out)
        case "bmp": try writeRaster(try flattenOnWhite(img), uti: UTType.bmp.identifier, to: out)
        case "jp2": try writeRaster(img, uti: "public.jpeg-2000", to: out, quality: Prefs.imageQuality)

        case "pdf":
            // 약 150dpi 기준 페이지 크기
            let scale = 72.0 / 150.0
            let size = NSSize(width: Double(img.width) * scale, height: Double(img.height) * scale)
            let image = NSImage(cgImage: img, size: size)
            guard let page = PDFPage(image: image) else { throw ConvertError.writeFailed("") }
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            guard doc.write(to: out) else { throw ConvertError.writeFailed("") }

        case "svg":
            // 주의: 벡터화(트레이싱)가 아니라 PNG 데이터를 SVG 안에 포함하는 방식이다.
            let b64 = try encodePNG(img).base64EncodedString()
            let w = img.width, h = img.height
            let svg = """
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
              <image width="\(w)" height="\(h)" xlink:href="data:image/png;base64,\(b64)"/>
            </svg>
            """
            do { try svg.write(to: out, atomically: false, encoding: .utf8) }
            catch { throw ConvertError.writeFailed(error.localizedDescription) }

        default:
            throw ConvertError.unsupported("")
        }
    }
}

// MARK: - 텍스트/문서

enum TextConverter {
    /// 입력 종류(md / txt / rtf / docx)에 맞춰 가장 자연스러운 형태로 변환한다.
    /// 텍스트 시스템 객체를 이 작업 안에서만 만들고 쓰므로 백그라운드에서 실행해도 안전하다.
    static func convert(_ url: URL, key: String, to out: URL, progress: @escaping ProgressHandler) throws {
        let ext = url.pathExtension.lowercased()
        let title = url.deletingPathExtension().lastPathComponent
        // 문서 준비 10%, 조판·저장 90%
        let renderProgress: ProgressHandler = { progress(0.1 + 0.9 * $0) }
        progress(0.02)
        defer { progress(1) }
        do {
            switch ext {
            case "md", "markdown":
                let blocks = MarkdownParser.parse(try readText(url))
                switch key {
                case "pdf": try DocumentPDF.render(blocks: MarkdownRenderer.layoutBlocks(blocks), title: title, to: out, progress: renderProgress)
                case "html": try writeString(MarkdownRenderer.html(blocks, title: title), to: out)
                case "txt": try writeString(MarkdownRenderer.plain(blocks), to: out)
                case "rtf", "docx": try writeAttributed(MarkdownRenderer.attributed(blocks), key: key, to: out)
                default: throw ConvertError.unsupported("")
                }

            case "rtf", "docx":
                // 신뢰할 수 없는 문서: 위험한 링크(javascript:, file: 등)와 HTML에서의 첨부를 제거
                let attributed = RichTextSanitizer.clean(try loadRich(url, ext: ext), forHTML: key == "html")
                switch key {
                case "pdf": try DocumentPDF.render(blocks: DocumentPDF.blocks(from: attributed), title: title, to: out, progress: renderProgress)
                case "txt": try writeString(attributed.string, to: out)
                default: try writeAttributed(attributed, key: key, to: out)
                }

            default: // txt
                let text = try readText(url)
                switch key {
                case "pdf": try DocumentPDF.render(blocks: PlainRenderer.layoutBlocks(text), title: title, to: out, progress: renderProgress)
                case "html": try writeString(PlainRenderer.html(text, title: title), to: out)
                case "rtf", "docx": try writeAttributed(PlainRenderer.attributed(text), key: key, to: out)
                default: throw ConvertError.unsupported("")
                }
            }
        } catch let e as ConvertError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConvertError.writeFailed(error.localizedDescription)
        }
    }

    static func readText(_ url: URL) throws -> String {
        let text = decode(try Data(contentsOf: url, options: .mappedIfSafe))
        guard text.utf16.count <= DocumentPDF.maxCharacters else { throw ConvertError.tooManyPages }
        return text
    }

    static func loadRich(_ url: URL, ext: String) throws -> NSAttributedString {
        let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .officeOpenXML
        let text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        guard text.length <= DocumentPDF.maxCharacters else { throw ConvertError.tooManyPages }
        return text
    }

    /// UTF-8 → UTF-16 → CP949(한글 Windows) → Latin-1 순서로 디코딩 시도
    static func decode(_ data: Data) -> String {
        var text: String?
        if let s = String(data: data, encoding: .utf8) { text = s }
        else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
                let s = String(data: data, encoding: .utf16) { text = s }
        else {
            let cfEnc = CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
            text = String(data: data, encoding: enc)
        }
        var result = text ?? (String(data: data, encoding: .isoLatin1) ?? "")
        if result.hasPrefix("\u{FEFF}") { result.removeFirst() }
        return result
    }

    static func writeString(_ s: String, to out: URL) throws {
        try s.write(to: out, atomically: false, encoding: .utf8)
    }

    static func writeAttributed(_ text: NSAttributedString, key: String, to out: URL) throws {
        let range = NSRange(location: 0, length: text.length)
        let type: NSAttributedString.DocumentType
        switch key {
        case "rtf": type = .rtf
        case "docx": type = .officeOpenXML
        case "html": type = .html
        default: throw ConvertError.unsupported("")
        }
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if type == .html { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
        var data = try text.data(from: range, documentAttributes: attrs)
        if type == .html { data = RichTextSanitizer.addCSP(to: data) }
        try data.write(to: out)
    }
}

// MARK: - 신뢰할 수 없는 서식 문서 정리

enum RichTextSanitizer {
    /// 링크는 http / https / mailto만 남기고, HTML로 내보낼 때는 첨부(로컬 파일 경로가 될 수 있음)를 제거
    static func clean(_ text: NSAttributedString, forHTML: Bool) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: m.length)

        var unsafeLinks: [NSRange] = []
        m.enumerateAttribute(.link, in: full) { value, range, _ in
            guard let value else { return }
            let url = (value as? URL) ?? (value as? String).flatMap { URL(string: $0) }
            if url.map(Inline.isSafe) != true { unsafeLinks.append(range) }
        }
        for r in unsafeLinks { m.removeAttribute(.link, range: r) }

        if forHTML {
            var attachments: [NSRange] = []
            m.enumerateAttribute(.attachment, in: full) { value, range, _ in
                if value != nil { attachments.append(range) }
            }
            for r in attachments.reversed() { m.deleteCharacters(in: r) }
        }
        return m
    }

    /// 내보낸 HTML에 외부 리소스·스크립트를 막는 CSP를 넣는다
    static func addCSP(to data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8) else { return data }
        let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:\">"
        if let head = html.range(of: "<head>", options: .caseInsensitive) {
            html.insert(contentsOf: "\n" + csp, at: head.upperBound)
        } else {
            html = csp + "\n" + html
        }
        return Data(html.utf8)
    }
}

// MARK: - PDF 입력

enum PDFConverter {
    struct Piece { let file: URL; let suffix: String }

    static func convert(_ url: URL, format: OutputFormat, work: URL, progress: ProgressHandler) throws -> [Piece] {
        guard let doc = PDFDocument(url: url) else { throw ConvertError.readFailed }
        if doc.isLocked { throw ConvertError.locked }

        if format.key == "txt" {
            guard doc.pageCount <= 5000 else { throw ConvertError.tooManyPages }
            let out = work.appendingPathComponent("out.txt")
            // 페이지마다 구분선을 넣어 어디서 페이지가 바뀌는지 알 수 있게
            var parts: [String] = []
            for i in 0..<doc.pageCount {
                try checkCancelled()
                progress(Double(i + 1) / Double(doc.pageCount))
                let pageText = (doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if doc.pageCount > 1 { parts.append("──────── " + L("페이지 %ld / %ld", i + 1, doc.pageCount) + " ────────") }
                parts.append(pageText)
                parts.append("")
            }
            let text = parts.joined(separator: "\n")
            do { try text.write(to: out, atomically: false, encoding: .utf8) }
            catch { throw ConvertError.writeFailed(error.localizedDescription) }
            return [Piece(file: out, suffix: "")]
        }

        let count = doc.pageCount
        guard count > 0 else { throw ConvertError.readFailed }
        guard count <= 500 else { throw ConvertError.tooManyPages }

        var pieces: [Piece] = []
        for i in 0..<count {
            try checkCancelled()
            defer { progress(Double(i + 1) / Double(count)) }
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            guard box.width > 0, box.height > 0 else { continue }

            var scale: CGFloat = 2
            let longest = max(box.width, box.height)
            if longest * scale > 6000 { scale = 6000 / longest }
            let size = CGSize(width: box.width * scale, height: box.height * scale)

            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { throw ConvertError.readFailed }

            let out = work.appendingPathComponent("page-\(i + 1).\(format.ext)")
            if format.key == "jpeg" {
                try ImageConverter.writeRaster(try ImageConverter.flattenOnWhite(cg), uti: UTType.jpeg.identifier, to: out, quality: Prefs.imageQuality)
            } else {
                try ImageConverter.writeRaster(cg, uti: UTType.png.identifier, to: out)
            }
            pieces.append(Piece(file: out, suffix: count == 1 ? "" : "-p\(i + 1)"))
        }
        guard !pieces.isEmpty else { throw ConvertError.readFailed }
        return pieces
    }
}

// MARK: - 오디오/비디오

enum AVConverter {
    static func export(_ url: URL, preset: String, type: AVFileType, out: URL, progress: ProgressHandler) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError.unsupported(L("이 파일은 해당 형식으로 내보낼 수 없습니다"))
        }
        guard session.supportedFileTypes.contains(type) else {
            throw ConvertError.unsupported(L("이 파일은 해당 형식으로 내보낼 수 없습니다"))
        }
        session.outputURL = out
        session.outputFileType = type
        session.exportAsynchronously {}
        // 0.1초마다 진행률을 읽고, 취소 요청이 오면 내보내기를 중단
        let running: [AVAssetExportSession.Status] = [.unknown, .waiting, .exporting]
        repeat {
            try? await Task.sleep(nanoseconds: 100_000_000)
            progress(Double(session.progress))
            if Task.isCancelled { session.cancelExport() }
        } while running.contains(session.status)
        if Task.isCancelled { throw CancellationError() }
        guard session.status == .completed else {
            throw ConvertError.writeFailed(session.error?.localizedDescription ?? "")
        }
    }

    /// WAV / AIFF / CAF (16-bit 선형 PCM)
    static func linearPCM(_ url: URL, type: AVFileType, out: URL, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw ConvertError.unsupported(L("오디오 트랙이 없습니다")) }

        let formats = try await track.load(.formatDescriptions)
        var rate: Double = 44100
        var channels = 2
        if let desc = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            if asbd.mSampleRate > 0 { rate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { channels = Int(asbd.mChannelsPerFrame) }
        }
        guard channels <= 2 else { throw ConvertError.unsupported(L("3채널 이상 오디오는 아직 지원하지 않습니다")) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: type == .aiff,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(readerOutput) else { throw ConvertError.unsupported("") }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: out, fileType: type)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        guard writer.canAdd(input) else { throw ConvertError.unsupported("") }
        writer.add(input)

        guard reader.startReading(), writer.startWriting() else {
            throw ConvertError.writeFailed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)

        // 세 객체는 아래 전용 큐 하나에서만 사용되므로 동시 접근이 없다 (AudioPump 참고)
        let pump = AudioPump(reader: reader, output: readerOutput, input: input)
        await withTaskCancellationHandler {
          await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "shakeconvert.audio.writer")
            pump.input.requestMediaDataWhenReady(on: queue) {
                while pump.input.isReadyForMoreMediaData {
                    if pump.isCancelled {
                        pump.reader.cancelReading()
                        pump.input.markAsFinished()
                        c.resume()
                        return
                    }
                    if let buffer = pump.output.copyNextSampleBuffer() {
                        if duration > 0 {
                            progress(CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration)
                        }
                        if !pump.input.append(buffer) {
                            pump.reader.cancelReading()
                            pump.input.markAsFinished()
                            c.resume()
                            return
                        }
                    } else {
                        pump.input.markAsFinished()
                        c.resume()
                        return
                    }
                }
            }
          }
        } onCancel: {
            pump.cancel()
        }
        await writer.finishWriting()
        if Task.isCancelled { throw CancellationError() }

        guard writer.status == .completed, reader.status != .failed else {
            throw ConvertError.writeFailed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "")
        }
    }
}

/// AVAssetReader / Writer 객체 묶음.
/// requestMediaDataWhenReady에 넘긴 전용 직렬 큐 하나에서만 접근하므로 동시 접근이 일어나지 않는다.
/// (AVFoundation 클래스가 Sendable로 표시돼 있지 않아 생기는 컴파일러 경고를 이 보장으로 해소)
private final class AudioPump: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    private let lock = NSLock()
    private var cancelled = false

    /// 취소 요청 (어느 스레드에서 불러도 안전)
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
        self.reader = reader
        self.output = output
        self.input = input
    }
}
