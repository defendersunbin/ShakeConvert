import AppKit
import SwiftUI

/// 앱이 실행되었음을 알려주는 짧은 팝업 (상단 중앙, 약 3초). 아이콘이 좌우로 흔들린다.
@MainActor
final class WelcomeToast {
    private var panel: NSPanel?

    func show() {
        panel?.orderOut(nil)

        let size = NSSize(width: 372, height: 92)
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = NSHostingView(rootView: WelcomeView(since: Date()))
        p.setContentSize(size)

        if let visible = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12))
        }
        p.orderFrontRegardless()
        panel = p

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_400_000_000)
            p.orderOut(nil)
            if self?.panel === p { self?.panel = nil }
        }
    }
}

private struct WelcomeView: View {
    let since: Date

    var body: some View {
        TimelineView(.animation) { ctx in
            let e = ctx.date.timeIntervalSince(since)
            let enter = Ease.outCubic(e / 0.5)
            let exit = Ease.clamp((e - 2.8) / 0.4)
            let alpha = enter * (1 - exit)

            // 0.5s ~ 2.0s 동안 감쇠하며 좌우로 흔들림
            let wiggleT = max(e - 0.5, 0)
            let decay = 1 - Ease.clamp(wiggleT / 1.5)
            let swing = sin(wiggleT * 18) * 7 * decay
            let pulse = 0.5 + 0.5 * sin(e * 5)

            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .offset(x: swing)
                    .rotationEffect(.degrees(swing * 0.9))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("ShakeConvert")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Circle()
                            .fill(Theme.success)
                            .frame(width: 7, height: 7)
                            .opacity(0.45 + 0.55 * pulse)
                        Text(L("실행 중"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.success)
                        Text("v\(AppInfo.version)")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                    }
                    Text(L("파일을 잡고 좌우로 흔들어 보세요"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(width: 372, height: 92)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .offset(y: -22 * (1 - enter))
            .opacity(alpha)
        }
    }
}
