import AppKit
import ServiceManagement

// MARK: - 설정 값 종류

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L("시스템")
        case .light: return L("라이트")
        case .dark: return L("다크")
        }
    }

    @MainActor static func apply(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum ShakeSensitivity: String, CaseIterable, Identifiable {
    case low, normal, high
    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return L("둔감")
        case .normal: return L("보통")
        case .high: return L("민감")
        }
    }

    /// (방향 전환으로 인정하는 최소 이동 거리 pt, 필요한 방향 전환 횟수, 시간 창 초)
    var params: (travel: CGFloat, reversals: Int, window: TimeInterval) {
        switch self {
        case .low: return (60, 4, 1.1)
        case .normal: return (45, 3, 1.0)
        case .high: return (28, 2, 0.8)
        }
    }
}

enum AutoClose: String, CaseIterable, Identifiable {
    case s5, s10, s15, s30, m1, never
    var id: String { rawValue }

    /// nil = 닫지 않음 (직접 닫을 때까지 유지)
    var seconds: Double? {
        switch self {
        case .s5: return 5
        case .s10: return 10
        case .s15: return 15
        case .s30: return 30
        case .m1: return 60
        case .never: return nil
        }
    }

    var label: String {
        switch self {
        case .s5: return L("%ld초", 5)
        case .s10: return L("%ld초", 10)
        case .s15: return L("%ld초", 15)
        case .s30: return L("%ld초", 30)
        case .m1: return L("1분")
        case .never: return L("닫지 않음")
        }
    }
}

enum SaveLocation: String, CaseIterable, Identifiable {
    case besideOriginal, downloads
    var id: String { rawValue }

    var label: String {
        switch self {
        case .besideOriginal: return L("원본 파일 옆")
        case .downloads: return L("다운로드 폴더")
        }
    }
}

enum PaperSize: String, CaseIterable, Identifiable {
    case a4, letter
    var id: String { rawValue }

    var label: String {
        switch self {
        case .a4: return "A4"
        case .letter: return "Letter"
        }
    }

    var size: CGSize {
        switch self {
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .letter: return CGSize(width: 612, height: 792)
        }
    }
}

// MARK: - 저장소 (UserDefaults). 어느 스레드에서 읽어도 안전.

enum Prefs {
    enum Key: String {
        case appearance, shakeSensitivity, saveLocation, revealAfter, showLaunchToast, imageQuality, paperSize, autoClose
    }

    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.appearance.rawValue: AppearanceMode.system.rawValue,
            Key.shakeSensitivity.rawValue: ShakeSensitivity.normal.rawValue,
            Key.saveLocation.rawValue: SaveLocation.besideOriginal.rawValue,
            Key.revealAfter.rawValue: false,
            Key.showLaunchToast.rawValue: true,
            Key.imageQuality.rawValue: 0.9,
            Key.paperSize.rawValue: PaperSize.a4.rawValue,
            Key.autoClose.rawValue: AutoClose.s10.rawValue,
        ])
    }

    static func set(_ value: Any, _ key: Key) { defaults.set(value, forKey: key.rawValue) }

    static var appearance: AppearanceMode {
        AppearanceMode(rawValue: defaults.string(forKey: Key.appearance.rawValue) ?? "") ?? .system
    }
    static var shakeSensitivity: ShakeSensitivity {
        ShakeSensitivity(rawValue: defaults.string(forKey: Key.shakeSensitivity.rawValue) ?? "") ?? .normal
    }
    static var saveLocation: SaveLocation {
        SaveLocation(rawValue: defaults.string(forKey: Key.saveLocation.rawValue) ?? "") ?? .besideOriginal
    }
    static var paperSize: PaperSize {
        PaperSize(rawValue: defaults.string(forKey: Key.paperSize.rawValue) ?? "") ?? .a4
    }
    static var autoClose: AutoClose {
        AutoClose(rawValue: defaults.string(forKey: Key.autoClose.rawValue) ?? "") ?? .s10
    }
    static var revealAfter: Bool { defaults.bool(forKey: Key.revealAfter.rawValue) }
    static var showLaunchToast: Bool { defaults.bool(forKey: Key.showLaunchToast.rawValue) }

    /// 0.6 ~ 1.0 범위로 강제
    static var imageQuality: Double {
        min(max(defaults.double(forKey: Key.imageQuality.rawValue), 0.6), 1.0)
    }
}

// MARK: - 설정 창이 바인딩하는 모델

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var appearance: AppearanceMode {
        didSet { Prefs.set(appearance.rawValue, .appearance); AppearanceMode.apply(appearance) }
    }
    @Published var sensitivity: ShakeSensitivity {
        didSet { Prefs.set(sensitivity.rawValue, .shakeSensitivity) }
    }
    @Published var saveLocation: SaveLocation {
        didSet { Prefs.set(saveLocation.rawValue, .saveLocation) }
    }
    @Published var paperSize: PaperSize {
        didSet { Prefs.set(paperSize.rawValue, .paperSize) }
    }
    @Published var autoClose: AutoClose {
        didSet { Prefs.set(autoClose.rawValue, .autoClose) }
    }
    @Published var revealAfter: Bool {
        didSet { Prefs.set(revealAfter, .revealAfter) }
    }
    @Published var showLaunchToast: Bool {
        didSet { Prefs.set(showLaunchToast, .showLaunchToast) }
    }
    @Published var imageQuality: Double {
        didSet { Prefs.set(imageQuality, .imageQuality) }
    }

    /// 비어 있으면 시스템 언어. 바꾸면 다시 시작해야 적용된다.
    @Published var language: String {
        didSet {
            AppLanguage.override = language
            needsRestart = language != initialLanguage
        }
    }
    @Published private(set) var needsRestart = false
    private let initialLanguage: String

    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginMessage: String?

    private init() {
        appearance = Prefs.appearance
        sensitivity = Prefs.shakeSensitivity
        saveLocation = Prefs.saveLocation
        paperSize = Prefs.paperSize
        autoClose = Prefs.autoClose
        revealAfter = Prefs.revealAfter
        showLaunchToast = Prefs.showLaunchToast
        imageQuality = Prefs.imageQuality
        let lang = AppLanguage.override
        language = lang
        initialLanguage = lang
        refreshLogin()
    }

    // MARK: 로그인 시 실행 (SMAppService, macOS 13+)

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginMessage = nil
        } catch {
            loginMessage = L("설정하지 못했습니다: %@", error.localizedDescription)
        }
        refreshLogin()
    }

    func refreshLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        if status == .requiresApproval {
            loginMessage = L("시스템 설정 › 일반 › 로그인 항목에서 허용해 주세요.")
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var isInApplicationsFolder: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }
}
