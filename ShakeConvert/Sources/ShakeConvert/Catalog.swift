import Foundation
import UniformTypeIdentifiers

/// 지원하는 입력 파일 분류
enum Category: String, CaseIterable {
    case image, text, pdf, audio, video

    var displayName: String {
        switch self {
        case .image: return L("이미지")
        case .text: return L("문서/텍스트")
        case .pdf: return "PDF"
        case .audio: return L("오디오")
        case .video: return L("비디오")
        }
    }

}

/// 변환 결과 형식 하나
struct OutputFormat: Identifiable, Hashable {
    let category: Category
    let key: String        // 변환 엔진이 분기에 쓰는 키 (예: "jpeg")
    let label: String      // 화면 표시 이름
    let ext: String        // 출력 확장자
    let note: String?      // 짧은 부연 설명
    let aliases: [String]  // 검색용 별칭

    var id: String { "\(category.rawValue)-\(key)" }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        let haystack = [key, label, ext, note ?? ""] + aliases
        return haystack.contains { $0.lowercased().contains(q) }
    }
}

enum Catalog {
    // MARK: 분류

    static func kind(of url: URL) -> Category? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }

        // 문서류는 확장자로 직접 판별 (HTML은 보안상 입력에서 제외: 로더가 WebKit을 사용해 네트워크 접근 가능)
        if ["txt", "text", "md", "markdown", "rtf", "docx"].contains(ext) { return .text }

        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .svg) { return nil } // ImageIO가 SVG를 읽지 못함
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }

    /// 동의어 확장자를 하나로 정규화 (같은 형식으로의 변환 제안을 걸러내기 위함)
    static func normalized(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpe", "jfif": return "jpeg"
        case "tif": return "tiff"
        case "htm": return "html"
        case "aif": return "aiff"
        case "m4v": return "mp4"
        case "text": return "txt"
        case "markdown": return "md"
        default: return ext.lowercased()
        }
    }

    // MARK: 형식 목록

    private static func f(_ c: Category, _ key: String, _ label: String,
                          ext: String? = nil, note: String? = nil,
                          aliases: [String] = []) -> OutputFormat {
        OutputFormat(category: c, key: key, label: label, ext: ext ?? key, note: note, aliases: aliases)
    }

    private static let table: [Category: [OutputFormat]] = [
        .image: [
            f(.image, "jpeg", "JPEG", ext: "jpg", aliases: ["jpg"]),
            f(.image, "png", "PNG"),
            f(.image, "heic", "HEIC", aliases: ["heif"]),
            f(.image, "pdf", "PDF"),
            f(.image, "svg", "SVG", note: L("래스터 임베드"), aliases: [L("벡터"), "vector"]),
            f(.image, "tiff", "TIFF", aliases: ["tif"]),
            f(.image, "gif", "GIF"),
            f(.image, "bmp", "BMP"),
            f(.image, "jp2", "JPEG 2000", aliases: ["jpeg2000", "j2k"]),
        ],
        .text: [
            f(.text, "pdf", "PDF"),
            f(.text, "rtf", "RTF", aliases: [L("리치")]),
            f(.text, "html", "HTML", aliases: ["web", L("웹")]),
            f(.text, "docx", "Word", aliases: ["word", L("워드"), "docx"]),
            f(.text, "txt", L("텍스트"), aliases: ["txt", "text", "plain"]),
        ],
        .pdf: [
            f(.pdf, "docx", "Word", aliases: ["word", L("워드"), "docx"]),
            f(.pdf, "png", "PNG", note: L("페이지별")),
            f(.pdf, "jpeg", "JPEG", ext: "jpg", note: L("페이지별"), aliases: ["jpg"]),
            f(.pdf, "txt", L("텍스트"), aliases: ["txt", "text", L("추출")]),
        ],
        .audio: [
            f(.audio, "m4a", "M4A", aliases: ["aac"]),
            f(.audio, "wav", "WAV", aliases: ["pcm"]),
            f(.audio, "aiff", "AIFF", aliases: ["aif"]),
            f(.audio, "caf", "CAF"),
        ],
        .video: [
            f(.video, "mp4", "MP4"),
            f(.video, "mov", "MOV", aliases: ["quicktime"]),
            f(.video, "m4a", "M4A", note: L("오디오만"), aliases: ["audio", L("소리"), L("음원")]),
        ],
    ]

    /// 카테고리에서 “먼저 제안할” 순서
    private static let preferredOrder: [Category: [String]] = [
        .image: ["jpeg", "png", "heic", "pdf", "svg", "tiff", "gif", "bmp", "jp2"],
        .text: ["pdf", "rtf", "html", "docx", "txt"],
        .pdf: ["txt", "docx", "png", "jpeg"],
        .audio: ["m4a", "wav", "aiff", "caf"],
        .video: ["mp4", "mov", "m4a"],
    ]

    /// etc 목록에 쓰는 전체 형식 (원본과 같은 형식은 제외)
    static func formats(for category: Category, excludingSourceOf url: URL) -> [OutputFormat] {
        let src = normalized(url.pathExtension)
        return (table[category] ?? []).filter { normalized($0.ext) != src }
    }

    /// 파일 좌우에 바로 보여줄 추천 형식 (최대 limit개)
    static func suggestions(for url: URL, category: Category, limit: Int = 4) -> [OutputFormat] {
        let all = formats(for: category, excludingSourceOf: url)
        let order = preferredOrder[category] ?? []
        let sorted = order.compactMap { key in all.first { $0.key == key } }
        return Array(sorted.prefix(limit))
    }
}
