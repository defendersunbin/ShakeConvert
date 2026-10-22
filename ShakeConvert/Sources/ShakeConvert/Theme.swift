import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// 라이트/다크 모드에 따라 자동으로 바뀌는 색
private func adaptive(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
    })
}

/// 그라데이션 없이 단색만 사용하는 팔레트 (라이트 / 다크)
enum Theme {
    static let panel = adaptive(0xF7F5F0, 0x141416)
    static let hub = adaptive(0xECE9E2, 0x0B0B0D)
    static let surface = adaptive(0xEDEAE3, 0x1E1F23)
    static let surfaceHi = adaptive(0xE2DED6, 0x2A2C31)
    static let hairline = adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.08)
    static let text = adaptive(0x1A1B1F, 0xF2EFE8)
    static let textDim = adaptive(0x6B6E76, 0x8B8E96)

    // 링 메뉴 조각: 모노톤 + 선택 시 반전, 방향 표시만 포인트 컬러
    static let ring = adaptive(0xE6E3DC, 0x222328)
    static let ringEtc = adaptive(0xDAD6CE, 0x18191C)
    static let ringHi = adaptive(0x1A1B1F, 0xF2EFE8)

    static let accent = adaptive(0x2A7FD4, 0x7CC4FF)
    static let success = adaptive(0x2E9E6A, 0x8FD1B0)
    static let danger = adaptive(0xC9503F, 0xE5867A)
}

enum Ease {
    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }

    static func outCubic(_ x: Double) -> Double {
        let p = 1 - clamp(x)
        return 1 - p * p * p
    }

    static func outBack(_ x: Double) -> Double {
        let c1 = 1.70158
        let c3 = c1 + 1
        let p = clamp(x) - 1
        return 1 + c3 * p * p * p + c1 * p * p
    }
}
