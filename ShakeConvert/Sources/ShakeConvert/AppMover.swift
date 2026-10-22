import AppKit
import Security

/// DMG(또는 다운로드 폴더)에서 바로 실행했을 때, 사용자의 언어로
/// "응용 프로그램 폴더로 옮길까요?"를 묻고 직접 옮긴 뒤 다시 실행한다.
///
/// 보안 원칙
/// - 대상 경로는 /Applications/ShakeConvert.app 으로 고정 (사용자 입력 경로 없음)
/// - 대상이 심볼릭 링크이거나, 같은 번들 ID의 앱이 아니면 절대 건드리지 않는다
/// - 기존 버전은 삭제하지 않고 휴지통으로 보낸다 (되돌릴 수 있음)
/// - 복사본의 코드 서명이 유효하고 번들 ID가 같을 때만 실행한다
/// - Gatekeeper 격리 속성(quarantine)은 제거하지 않는다
@MainActor
enum AppMover {
    private static let suppressKey = "suppressMoveToApplications"
    private static let destination = URL(fileURLWithPath: "/Applications/ShakeConvert.app")

    static func offerIfNeeded() {
        let path = Bundle.main.bundlePath
        let home = NSHomeDirectory()
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return }

        // DMG에서 실행 / 격리된(translocated) 실행 / 다운로드 폴더에서 실행한 경우만 묻는다.
        // (개발 중 build/ 폴더에서 실행할 때는 묻지 않음)
        let fromDMG = path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
        let fromDownloads = path.hasPrefix(home + "/Downloads/")
        guard fromDMG || fromDownloads else { return }
        if UserDefaults.standard.bool(forKey: suppressKey) { return }

        let existing = existingInstallState()
        if existing == .foreign {
            showError(L("응용 프로그램 폴더에 같은 이름의 다른 앱이 있어 옮기지 않았습니다."))
            return
        }

        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = L("ShakeConvert를 응용 프로그램 폴더로 옮길까요?")
        var info = L("응용 프로그램 폴더에서 실행해야 로그인 시 자동 실행 등 모든 기능이 정상적으로 동작합니다.")
        if existing == .ours { info += "\n\n" + L("이미 설치된 버전은 휴지통으로 이동합니다.") }
        alert.informativeText = info
        alert.addButton(withTitle: L("응용 프로그램 폴더로 이동"))
        alert.addButton(withTitle: L("나중에"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("다시 묻지 않기")

        NSApp.activate()
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressKey)
        }
        guard response == .alertFirstButtonReturn else { return }
        move(existing: existing)
    }

    // MARK: 설치 상태 확인

    private enum InstallState { case none, ours, foreign }

    private static func existingInstallState() -> InstallState {
        let fm = FileManager.default
        // 심볼릭 링크면 따라가지 않고 '다른 것'으로 취급 (링크를 통한 엉뚱한 위치 조작 방지)
        if (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil { return .foreign }
        guard fm.fileExists(atPath: destination.path) else { return .none }
        guard let id = Bundle(url: destination)?.bundleIdentifier,
              id == Bundle.main.bundleIdentifier else { return .foreign }
        return .ours
    }

    private static func move(existing: InstallState) {
        let fm = FileManager.default
        do {
            // 확인 직후 다른 것으로 바뀌었는지 한 번 더 검사 (TOCTOU 완화)
            guard existingInstallState() == existing, existing != .foreign else {
                throw CocoaError(.fileWriteFileExists)
            }
            if existing == .ours {
                try fm.trashItem(at: destination, resultingItemURL: nil)
            }
            try fm.copyItem(at: Bundle.main.bundleURL, to: destination)

            guard isValidCopy(at: destination) else {
                try? fm.trashItem(at: destination, resultingItemURL: nil)
                showError(L("복사본의 서명을 확인할 수 없어 설치를 취소했습니다."))
                return
            }
            relaunch(at: destination)
        } catch {
            showError(L("Finder에서 ShakeConvert를 응용 프로그램 폴더로 직접 끌어다 놓아 주세요.")
                      + "\n\n" + error.localizedDescription)
        }
    }

    /// 복사된 앱이 "지금 실행 중인 바로 이 앱"과 같은 서명 신원인지 확인한다.
    /// 서명이 온전한지(변조 여부)뿐 아니라, 실행 중인 앱의 지정 요구 사항(designated requirement)을
    /// 만족하는지까지 검사하므로 다른 서명으로 바꿔치기된 복사본은 실행되지 않는다.
    /// (ad-hoc 서명이면 요구 사항이 코드 해시이므로 바이트 단위로 같은 앱만 통과)
    private static func isValidCopy(at url: URL) -> Bool {
        guard Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier else { return false }

        var running: SecCode?
        var runningStatic: SecStaticCode?
        var requirement: SecRequirement?
        var copy: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &copy) == errSecSuccess, let copy
        else { return false }

        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures)
                                       | UInt32(kSecCSCheckNestedCode)
                                       | UInt32(kSecCSStrictValidate))
        return SecStaticCodeCheckValidity(copy, flags, requirement) == errSecSuccess
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("옮기지 못했습니다")
        alert.informativeText = message
        alert.addButton(withTitle: L("확인"))
        NSApp.activate()
        alert.runModal()
    }

    /// 지정한 위치의 앱을 새로 실행하고 지금 실행 중인 앱은 종료한다.
    static func relaunch(at url: URL = Bundle.main.bundleURL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
