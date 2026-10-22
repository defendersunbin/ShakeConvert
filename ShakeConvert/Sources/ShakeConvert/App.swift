import AppKit

@main
struct ShakeConvertMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Dock 아이콘 없이 메뉴바 앱으로 동작
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let detector = ShakeDetector()
    private let panel = PanelController()
    private let toast = WelcomeToast()
    private let settings = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        AppearanceMode.apply(Prefs.appearance)
        setupStatusItem()
        detector.onShake = { [weak self] in
            Task { @MainActor in self?.handleShake() }
        }
        detector.start()
        if Prefs.showLaunchToast { toast.show() } // 실행되었음을 알리는 팝업
        Task { @MainActor in AppMover.offerIfNeeded() } // DMG에서 실행했다면 설치 제안
    }

    @objc private func openSettings() {
        settings.show()
    }

    private func handleShake() {
        let files = DragPasteboard.fileURLs()
        guard let first = files.first, let kind = Catalog.kind(of: first) else { return }
        panel.show(at: NSEvent.mouseLocation, files: files, kind: kind)
    }

    @objc private func showToast() {
        toast.show()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "ShakeConvert") {
            image.isTemplate = true
            item.button?.image = image
        }
        let menu = NSMenu()
        let version = NSMenuItem(title: "ShakeConvert v\(AppInfo.version)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let info = NSMenuItem(title: L("파일을 잡고 좌우로 흔들면 변환 메뉴가 나타납니다"), action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        let status = NSMenuItem(title: L("실행 상태 보기"), action: #selector(showToast), keyEquivalent: "")
        status.target = self
        menu.addItem(status)
        let prefs = NSMenuItem(title: L("설정…"), action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("종료"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

enum DragPasteboard {
    /// 현재 드래그 중인 파일 URL (드래그 전용 pasteboard에서만 읽음 — 일반 클립보드는 건드리지 않음)
    static func fileURLs() -> [URL] {
        let pb = NSPasteboard(name: .drag)
        let urls = pb.readObjects(forClasses: [NSURL.self],
                                  options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls ?? []
    }
}
