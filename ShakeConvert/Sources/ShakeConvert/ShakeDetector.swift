import AppKit

/// 파일(또는 무엇이든)을 마우스로 잡고 좌우로 흔드는 동작을 전역에서 감지한다.
///
/// - 마우스 이벤트 전역 모니터링은 손쉬운 사용(Accessibility) 권한이 필요하지 않다.
/// - 일반 클릭 드래그와 구분하기 위해, 마우스를 누른 뒤 드래그 전용 pasteboard의
///   changeCount가 바뀐 경우(= 실제 드래그 세션이 시작된 경우)에만 동작한다.
final class ShakeDetector {
    var onShake: (() -> Void)?

    private var monitors: [Any] = []
    private let dragPasteboard = NSPasteboard(name: .drag)

    // 상태
    private var baselineCount = 0
    private var anchorX: CGFloat = 0
    private var extremeX: CGFloat = 0
    private var direction = 0 // -1 왼쪽, 0 미정, 1 오른쪽
    private var reversals: [TimeInterval] = []
    private var lastTrigger: TimeInterval = 0

    // 튜닝 값 (설정 › 흔들기 감도). 드래그 시작 시점에 한 번 읽어 둔다.
    private var minTravel: CGFloat = 45        // 방향 전환으로 인정하는 최소 이동 거리(pt)
    private var window: TimeInterval = 1.0     // 이 시간 안에
    private var neededReversals = 3            // 이 횟수만큼 방향이 바뀌면 흔들기로 판단
    private let cooldown: TimeInterval = 1.5

    func start() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.beginTracking()
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            self?.handleDrag()
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            self?.resetMotion()
        }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func beginTracking() {
        let p = Prefs.shakeSensitivity.params
        minTravel = p.travel
        neededReversals = p.reversals
        window = p.window
        baselineCount = dragPasteboard.changeCount
        anchorX = NSEvent.mouseLocation.x
        resetMotion()
    }

    private func resetMotion() {
        direction = 0
        reversals.removeAll()
        extremeX = NSEvent.mouseLocation.x
        anchorX = extremeX
    }

    private func handleDrag() {
        // 실제 드래그 세션이 아니면 무시 (드래그 pasteboard가 갱신되지 않았다면 단순 마우스 이동)
        guard dragPasteboard.changeCount != baselineCount else { return }

        let x = NSEvent.mouseLocation.x
        var reversed = false

        switch direction {
        case 0:
            if abs(x - anchorX) >= minTravel {
                direction = x > anchorX ? 1 : -1
                extremeX = x
            }
        case 1:
            if x > extremeX { extremeX = x }
            else if extremeX - x >= minTravel { direction = -1; extremeX = x; reversed = true }
        default:
            if x < extremeX { extremeX = x }
            else if x - extremeX >= minTravel { direction = 1; extremeX = x; reversed = true }
        }

        guard reversed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        reversals.append(now)
        reversals.removeAll { now - $0 > window }

        if reversals.count >= neededReversals, now - lastTrigger > cooldown {
            lastTrigger = now
            reversals.removeAll()
            onShake?()
        }
    }
}
