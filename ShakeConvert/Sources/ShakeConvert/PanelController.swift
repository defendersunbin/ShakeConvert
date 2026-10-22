import AppKit
import SwiftUI

final class ConvertPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }   // 검색창에 타이핑하려면 필요
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() } // Esc
}

@MainActor
final class PanelController {
    private var panel: ConvertPanel?
    private let model = PanelModel()
    private var monitors: [Any] = []
    private var hideTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    // 창 크기는 고정 (PanelView: 위 여백 8 + 검색창 38 + 간격 12 + 링 300 + 간격 8 + 안내 44 + 여유)
    private static let size = NSSize(width: 340, height: 418)

    /// 창 위쪽 끝에서 링 중심(허브)까지의 거리
    private static let hubFromTop: CGFloat = 8 + 38 + 12 + 150

    init() {
        model.onLayoutChange = { [weak self] list in
            if list { self?.focusSearch() }
        }
        model.onFinished = { [weak self] success in
            // 성공: 설정(변환 완료 후 자동으로 닫기)에 따라 / 실패: 오류를 읽을 수 있게 열어 둠
            guard success else { self?.cancelScheduledClose(); return }
            if let seconds = Prefs.autoClose.seconds {
                self?.scheduleClose(after: seconds, onlyIfIdle: false)
            } else {
                self?.cancelScheduledClose()
            }
        }
        model.onClose = { [weak self] in self?.dismiss() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(at point: NSPoint, files: [URL], kind: Category) {
        dismissTask?.cancel()
        dismissTask = nil
        model.dismissing = false
        model.configure(files: files, category: kind)

        let panel = self.panel ?? makePanel()
        self.panel = panel

        // 커서(잡고 있는 파일)가 링의 중심 허브(= 취소 영역)에 오도록 배치:
        // 흔들자마자 놓으면 아무것도 변환되지 않고, 원하는 방향으로 밀어야 선택됨
        let size = Self.size
        panel.setContentSize(size)
        let origin = NSPoint(x: point.x - size.width / 2,
                             y: point.y - (size.height - Self.hubFromTop))
        panel.setFrameOrigin(clamped(origin, size: size))
        panel.orderFrontRegardless()

        installMonitors()
        scheduleClose(after: 20, onlyIfIdle: true) // 아무 동작이 없으면 자동으로 닫힘
    }

    /// 즉시 숨김 (애니메이션 없음)
    func hide() {
        hideTask?.cancel()
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        removeMonitors()
        model.reset()
    }

    /// 자연스럽게 닫기: 링 중심 쪽으로 작아지며 사라진 뒤 숨김
    func dismiss() {
        guard isVisible, dismissTask == nil else { return }
        hideTask?.cancel()
        model.dismissing = true
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, let self else { return }
            self.dismissTask = nil
            self.hide()
        }
    }

    private func cancelScheduledClose() {
        hideTask?.cancel()
        hideTask = nil
    }

    /// 일정 시간 뒤 자동으로 닫기. 변환 중이거나 검색 목록을 쓰는 중에는 닫지 않는다.
    /// onlyIfIdle: 변환을 시작하기 전(대기 상태)에만 해당하는 타이머 — 변환 결과 화면은 건드리지 않음
    private func scheduleClose(after seconds: Double, onlyIfIdle: Bool) {
        if onlyIfIdle && !model.isIdle { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.model.busy || (self.model.isIdle && self.model.showsList) { return }
            if onlyIfIdle && !self.model.isIdle { return }
            self.dismiss()
        }
    }

    private func makePanel() -> ConvertPanel {
        let p = ConvertPanel(contentRect: .zero,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false // 창은 투명, 그림자는 SwiftUI 요소별로 그림
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = NSHostingView(rootView: PanelView(model: model, drop: model.drop))
        p.onCancel = { [weak self] in
            guard let self else { return }
            if self.model.busy { self.model.cancelConversion() } else { self.dismiss() }
        }
        return p
    }

    private func focusSearch() {
        NSApp.activate()
        panel?.makeKey()
        model.requestFocus()
    }

    private func clamped(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let probe = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let screen = NSScreen.screens.first { NSMouseInRect(probe, $0.frame, false) } ?? NSScreen.main
        var o = origin
        if let visible = screen?.visibleFrame {
            o.x = min(max(o.x, visible.minX + 8), visible.maxX - size.width - 8)
            o.y = min(max(o.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        return o
    }

    // MARK: 외부 클릭/마우스 업 감지

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        // 다른 앱을 클릭하면 닫기
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, !self.model.busy else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) { self.dismiss() }
            }
        }) { monitors.append(m) }
        // 패널 밖에서 드래그를 놓으면: 검색창에 바로 입력할 수 있게 포커스를 주고 잠시 유지
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible, self.model.isIdle, !self.model.dismissing else { return }
                self.scheduleClose(after: 10, onlyIfIdle: true)
                self.focusSearch()
            }
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}
