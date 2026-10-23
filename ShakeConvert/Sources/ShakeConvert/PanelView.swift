import SwiftUI
import UniformTypeIdentifiers

// MARK: - 360° 링 기하
//
// 커서(잡고 있는 파일) 위치 = 링의 중심 허브. 변환 형식 조각들이 360°로 커서를 감싼다.
//  - etc는 항상 3시 방향(0°), 나머지 형식은 12시부터 시계 방향으로 선호 순서대로 배치
//  - 선택은 "방향"으로만 결정: 링 바깥까지 밀어도 그 방향 조각이 선택됨
//  - 허브(가운데)에 놓으면 변환 없이 메뉴가 자연스럽게 닫힘 (파일은 그대로)

enum Ring {
    static let box: CGFloat = 300
    static let center = CGPoint(x: 150, y: 150)
    static let disc: CGFloat = 146      // 바탕 원
    static let outer: CGFloat = 130
    static let inner: CGFloat = 60
    static let hub: CGFloat = 50
    static let track: CGFloat = 95      // 상태 애니메이션 링 반지름
    static let gap: Double = 1.2        // 조각 사이 간격(도)

    /// 수학 좌표계 각도(0° = 오른쪽, 90° = 위)를 화면 좌표로
    static func point(_ r: CGFloat, _ deg: Double) -> CGPoint {
        let t = deg * .pi / 180
        return CGPoint(x: center.x + r * CGFloat(cos(t)), y: center.y - r * CGFloat(sin(t)))
    }

    /// 조각별 중심 각도. 마지막 원소(etc) = 0°, 나머지는 12시부터 시계 방향.
    static func angles(count n: Int) -> [Double] {
        guard n > 0 else { return [] }
        let step = 360.0 / Double(n)
        let free = (1..<n).map { Double($0) * step }
            .sorted { positiveMod(90 - $0, 360) < positiveMod(90 - $1, 360) }
        return free + [0]
    }

    struct Hit {
        let index: Int?
        let angle: Double?
        let overHub: Bool
    }

    static func hit(_ p: CGPoint, angles: [Double]) -> Hit {
        let dx = Double(p.x - center.x)
        let dy = Double(center.y - p.y)
        if hypot(dx, dy) < Double(inner) - 4 || angles.isEmpty {
            return Hit(index: nil, angle: nil, overHub: true)
        }
        let a = positiveMod(atan2(dy, dx) * 180 / .pi, 360)
        var best = 0
        var bestDiff = Double.greatestFiniteMagnitude
        for (i, c) in angles.enumerated() {
            let diff = abs(positiveMod(a - c + 180, 360) - 180)
            if diff < bestDiff { bestDiff = diff; best = i }
        }
        return Hit(index: best, angle: angles[best], overHub: false)
    }
}

struct RingSegment: Shape {
    var start: Double
    var end: Double
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let steps = 24
        var p = Path()
        p.move(to: Ring.point(outer, start))
        for s in 1...steps {
            p.addLine(to: Ring.point(outer, start + (end - start) * Double(s) / Double(steps)))
        }
        for s in 0...steps {
            p.addLine(to: Ring.point(inner, end + (start - end) * Double(s) / Double(steps)))
        }
        p.closeSubpath()
        return p
    }
}

/// 0°를 중심으로 ±half 만큼 그려지는 호 (rotationEffect로 방향을 돌림)
struct IndicatorArc: Shape {
    var radius: CGFloat
    var half: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = 20
        for s in 0...steps {
            let deg = -half + 2 * half * Double(s) / Double(steps)
            let t = deg * .pi / 180
            let pt = CGPoint(x: rect.midX + radius * CGFloat(cos(t)), y: rect.midY - radius * CGFloat(sin(t)))
            if s == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

private struct RingItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let isEtc: Bool
}

private struct RingDropDelegate: DropDelegate {
    let ids: [String]
    let angles: [Double]
    let drop: DropState
    let onDrop: (String, [NSItemProvider]) -> Bool

    @discardableResult
    private func track(_ p: CGPoint) -> String? {
        let h = Ring.hit(p, angles: angles)
        let id = h.index.map { ids[$0] }
        drop.update(id: id, angle: h.angle, overHub: h.overHub)
        return id
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        track(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        track(info.location)
        // 조각 = 변환, 허브 = 닫기. 어느 쪽이든 파일 자체는 옮겨지지 않는다 (copy 의미로만 받음)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        drop.clear()
    }

    func performDrop(info: DropInfo) -> Bool {
        let hit = Ring.hit(info.location, angles: angles)
        drop.clear()
        if hit.overHub { return onDrop(RingMenu.hubID, []) }
        guard let index = hit.index else { return false }
        return onDrop(ids[index], info.itemProviders(for: [UTType.fileURL]))
    }
}

// MARK: - 루트 (배경 없는 투명 창 위에 검색창 / 링 / 안내 문구가 떠 있음)

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var drop: DropState

    var body: some View {
        VStack(spacing: 12) {
            SearchBar(model: model)
            if model.isIdle && model.showsList {
                FormatList(model: model)
                    .padding(14)
                    .frame(width: Ring.disc * 2, height: 352)
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
            } else {
                VStack(spacing: 8) {
                    if model.isIdle {
                        RingMenu(model: model, drop: drop)
                    } else {
                        RingStatus(model: model)
                    }
                    Caption(model: model, drop: drop)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(width: 340, height: 418, alignment: .top)
        // 닫힐 때: 링 중심(허브) 쪽으로 작아지며 사라짐
        .scaleEffect(model.dismissing ? 0.8 : 1, anchor: UnitPoint(x: 0.5, y: (8 + 38 + 12 + 150) / 418))
        .opacity(model.dismissing ? 0 : 1)
        .animation(.easeIn(duration: 0.2), value: model.dismissing)
    }
}

private struct Disc: View {
    var body: some View {
        Circle()
            .fill(Theme.panel)
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            .frame(width: Ring.disc * 2, height: Ring.disc * 2)
            .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
    }
}

// MARK: - 링 메뉴

private struct RingMenu: View {
    static let hubID = "hub"
    @ObservedObject var model: PanelModel
    @ObservedObject var drop: DropState

    private var items: [RingItem] {
        model.suggestions.map {
            RingItem(id: $0.id, title: $0.ext.uppercased(), subtitle: $0.note ?? "", isEtc: false)
        } + [RingItem(id: "etc", title: "etc", subtitle: L("더 보기"), isEtc: true)]
    }

    var body: some View {
        let list = items
        let ids = list.map(\.id)
        let angles = Ring.angles(count: list.count)
        let step = 360.0 / Double(max(list.count, 1))

        ZStack {
            Disc()
            ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                segment(item, index: i, center: angles[i], step: step)
            }
            indicator(step: step)
            hub
        }
        .frame(width: Ring.box, height: Ring.box)
        // 펼침: 살짝 돌면서 커지며 등장
        .scaleEffect(model.revealed ? 1 : 0.72)
        .rotationEffect(.degrees(model.revealed ? 0 : -45))
        .opacity(model.revealed ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: model.revealed)
        .contentShape(Circle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let h = Ring.hit(p, angles: angles)
                drop.update(id: h.index.map { ids[$0] }, angle: h.angle, overHub: h.overHub)
            case .ended:
                drop.clear()
            }
        }
        .onTapGesture(coordinateSpace: .local) { p in
            let hit = Ring.hit(p, angles: angles)
            if hit.overHub {
                model.close()
            } else if let i = hit.index {
                model.select(ids[i])
            }
        }
        .onDrop(of: [UTType.fileURL],
                delegate: RingDropDelegate(ids: ids, angles: angles, drop: drop, onDrop: { id, providers in
                    model.handleDrop(providers, id: id)
                }))
    }

    private func segment(_ item: RingItem, index i: Int, center c: Double, step: Double) -> some View {
        let hovering = drop.hoverID == item.id
        let t = c * .pi / 180
        let push: CGFloat = hovering ? 6 : 0
        let fill: Color = hovering ? Theme.ringHi : (item.isEtc ? Theme.ringEtc : Theme.ring)
        let ink: Color = hovering ? Theme.panel : Theme.text

        return ZStack {
            RingSegment(start: c + step / 2 - Ring.gap, end: c - step / 2 + Ring.gap,
                        inner: Ring.inner, outer: Ring.outer)
                .fill(fill)
            VStack(spacing: 1) {
                if item.isEtc {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold))
                } else {
                    Text(item.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .opacity(0.7)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(ink)
            .frame(width: 70)
            .position(Ring.point((Ring.inner + Ring.outer) / 2, c))
        }
        .frame(width: Ring.box, height: Ring.box)
        .offset(x: push * CGFloat(cos(t)), y: -push * CGFloat(sin(t)))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .opacity(model.revealed ? 1 : 0)
        .animation(.easeOut(duration: 0.25).delay(model.revealed ? Double(i) * 0.03 : 0), value: model.revealed)
    }

    /// 링 바깥을 따라 미끄러지며 현재 방향을 가리키는 얇은 호
    private func indicator(step: Double) -> some View {
        IndicatorArc(radius: Ring.outer + 8, half: max(step / 2 - Ring.gap * 2, 4))
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: Ring.box, height: Ring.box)
            .rotationEffect(.degrees(-drop.indicatorAngle))
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: drop.indicatorAngle)
            .opacity(drop.hoverID == nil ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: drop.hoverID == nil)
    }

    private var hub: some View {
        let target: OutputFormat? = drop.hoverID.flatMap { $0 == "etc" ? nil : model.formatByID($0) }
        return ZStack {
            Circle().fill(drop.overHub ? Theme.surfaceHi : Theme.hub)
            Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            VStack(spacing: 3) {
                Text(model.sourceExt)
                    .font(.system(size: target == nil ? 15 : 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(target == nil ? Theme.text : Theme.textDim)
                if let target {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                    Text(target.ext.uppercased())
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                } else if drop.hoverID == "etc" {
                    Text(L("검색"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text(L("닫기"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(drop.overHub ? Theme.text : Theme.textDim)
                }
            }
        }
        .frame(width: Ring.hub * 2, height: Ring.hub * 2)
        .scaleEffect(drop.overHub ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: drop.hoverID)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: drop.overHub)
    }
}

// MARK: - 링 안에서 보여주는 변환 중 / 완료 / 실패 모션

private struct RingStatus: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        TimelineView(.animation) { ctx in
            ZStack {
                Disc()
                switch model.phase {
                case .idle:
                    EmptyView()
                case let .working(source, target, since):
                    working(source: source, target: target, e: ctx.date.timeIntervalSince(since))
                case let .done(_, target, since, _):
                    done(target: target, e: ctx.date.timeIntervalSince(since))
                case let .failed(_, _, target, since):
                    failed(target: target, e: ctx.date.timeIntervalSince(since))
                case let .needsPassword(_, _, target, since, wrong):
                    locked(target: target, e: ctx.date.timeIntervalSince(since), wrong: wrong)
                }
            }
        }
        .frame(width: Ring.box, height: Ring.box)
    }

    private var trackBase: some View {
        Circle()
            .stroke(Theme.ring, lineWidth: 10)
            .frame(width: Ring.track * 2, height: Ring.track * 2)
    }

    // 변환 중: 링을 따라 도는 호 + 허브 안에서 원본 → 대상으로 흐르는 점
    // 변환 중: 링이 실제 진행률만큼 시계 방향으로 차오름 (로딩 바)
    // 끝부분의 점이 계속 맥박처럼 뛰어서, 진행률이 잠시 멈춰 있어도 '살아 있음'이 보인다.
    private func working(source: String, target: OutputFormat, e: Double) -> some View {
        let p = model.progress
        let angle = (-90 + 360 * p) * .pi / 180          // 화면 좌표: 12시에서 시계 방향
        let tip = CGSize(width: Ring.track * CGFloat(cos(angle)), height: Ring.track * CGFloat(sin(angle)))
        let pulse = 0.5 + 0.5 * sin(e * 6)

        return ZStack {
            trackBase
            Circle()
                .trim(from: 0, to: max(p, 0.005))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .frame(width: Ring.track * 2, height: Ring.track * 2)
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: p)
            Circle()
                .fill(Theme.accent)
                .frame(width: 16, height: 16)
                .scaleEffect(0.75 + 0.35 * pulse)
                .opacity(0.35 + 0.4 * pulse)
                .offset(tip)
                .animation(.easeOut(duration: 0.3), value: p)
            ZStack {
                Circle().fill(Theme.hub)
                VStack(spacing: 3) {
                    Text("\(Int((p * 100).rounded(.down)))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                    Text("\(source) → \(target.ext.uppercased())")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    Text(L("눌러서 취소"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .frame(width: Ring.hub * 2, height: Ring.hub * 2)
            .contentShape(Circle())
            .onTapGesture { model.cancelConversion() }
        }
    }

    // 완료: 링이 끝까지 차오름 → 바깥으로 퍼지는 파동 → 허브가 튀어오르며 체크 표시
    private func done(target: OutputFormat, e: Double) -> some View {
        let fill = Ease.outCubic(e / 0.45)
        let burst = Ease.clamp((e - 0.35) / 0.7)
        let pop = Ease.outBack((e - 0.3) / 0.45)
        let check = Ease.clamp((e - 0.5) / 0.3)

        return ZStack {
            trackBase
            Circle()
                .trim(from: 0, to: fill)
                .stroke(Theme.success, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .frame(width: Ring.track * 2, height: Ring.track * 2)
                .rotationEffect(.degrees(-90))
            Circle()
                .stroke(Theme.success.opacity(0.55 * (1 - burst)), lineWidth: 2)
                .frame(width: Ring.track * 2 + 92 * burst, height: Ring.track * 2 + 92 * burst)
                .opacity(e > 0.35 ? 1 : 0)
            ZStack {
                Circle().fill(Theme.success)
                VStack(spacing: 4) {
                    CheckShape()
                        .trim(from: 0, to: check)
                        .stroke(Theme.panel, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 24, height: 19)
                    Text(target.ext.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.panel)
                }
            }
            .frame(width: Ring.hub * 2, height: Ring.hub * 2)
            .scaleEffect(0.6 + 0.4 * pop)
        }
    }

    // 암호 필요: 자물쇠가 있는 링. 암호가 틀리면 붉게 바뀌며 좌우로 흔들림
    private func locked(target: OutputFormat, e: Double, wrong: Bool) -> some View {
        let decay = 1 - Ease.clamp(e / 0.6)
        let shake = wrong ? sin(e * 42) * 8 * decay : 0
        let pulse = 0.5 + 0.5 * sin(e * 3)
        let tint = wrong ? Theme.danger : Theme.accent

        return ZStack {
            Circle()
                .stroke(tint.opacity(0.3 + 0.3 * pulse), lineWidth: 10)
                .frame(width: Ring.track * 2, height: Ring.track * 2)
            ZStack {
                Circle().fill(Theme.hub)
                VStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(target.ext.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .frame(width: Ring.hub * 2, height: Ring.hub * 2)
        }
        .offset(x: shake)
    }

    // 실패: 붉은 링 + X 표시, 좌우로 흔들림
    private func failed(target: OutputFormat, e: Double) -> some View {
        let decay = 1 - Ease.clamp(e / 0.6)
        let shake = sin(e * 42) * 8 * decay
        let cross = Ease.clamp((e - 0.1) / 0.3)

        return ZStack {
            Circle()
                .stroke(Theme.danger.opacity(0.85), lineWidth: 10)
                .frame(width: Ring.track * 2, height: Ring.track * 2)
            ZStack {
                Circle().fill(Theme.danger)
                VStack(spacing: 5) {
                    CrossShape()
                        .trim(from: 0, to: cross)
                        .stroke(Theme.panel, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 16, height: 16)
                    Text(target.ext.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.panel)
                }
            }
            .frame(width: Ring.hub * 2, height: Ring.hub * 2)
        }
        .offset(x: shake)
    }
}

// MARK: - 링 아래 안내 문구 / 결과 버튼

private struct Caption: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var drop: DropState

    private var idleText: String {
        if drop.overHub { return L("놓으면 닫기") }
        guard let id = drop.hoverID else { return model.fileTitle }
        if id == "etc" { return L("놓으면 전체 형식 검색") }
        if let f = model.formatByID(id) { return L("놓으면 %@(으)로 변환", f.label) }
        return model.fileTitle
    }

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                chip {
                    Text(idleText)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(drop.hoverID == nil && !drop.overHub ? Theme.textDim : Theme.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            case .working:
                // 진행률은 링에서 보여주므로 아래에는 파일 이름만 (여러 개면 순서도)
                chip {
                    HStack(spacing: 8) {
                        if model.fileCount > 1 {
                            Text("\(model.fileIndex + 1)/\(model.fileCount)")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.accent)
                        }
                        Text(model.fileTitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.textDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            case let .done(_, _, _, name):
                chip {
                    HStack(spacing: 10) {
                        Text(name)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button { model.revealOutputs() } label: {
                            Text(L("Finder에서 보기"))
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            case let .needsPassword(file, _, _, _, wrong):
                PasswordBar(model: model, file: file, wrong: wrong)
            case let .failed(message, _, _, _):
                chip {
                    HStack(spacing: 10) {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.danger)
                            .lineLimit(2)
                        Button { model.backToIdle() } label: {
                            Text(L("다시")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        Button { model.close() } label: {
                            Text(L("닫기")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textDim)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: 320)
        .frame(height: 44)
    }

    private func chip<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}

// MARK: - 암호 입력 (암호가 걸린 PDF)

private struct PasswordBar: View {
    @ObservedObject var model: PanelModel
    let file: String
    let wrong: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(wrong ? Theme.danger : Theme.accent)
            SecureField("", text: $model.passwordInput,
                        prompt: Text(wrong ? L("암호가 맞지 않습니다") : L("암호 입력"))
                            .foregroundColor(wrong ? Theme.danger : Theme.textDim))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .frame(width: 118)
                .onSubmit { model.submitPassword() }
            Button { model.submitPassword() } label: {
                Text(L("잠금 해제"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(model.passwordInput.isEmpty ? Theme.textDim : Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(model.passwordInput.isEmpty)
            Button { model.cancelPassword() } label: {
                Text(L("취소")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(wrong ? Theme.danger.opacity(0.7) : (focused ? Theme.accent.opacity(0.7) : Theme.hairline), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .help(file)
        .onAppear { focused = true }
        .onChange(of: model.focusTick) { focused = true }
    }
}

// MARK: - 상단 검색창

private struct SearchBar: View {
    @ObservedObject var model: PanelModel
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // 왼쪽 돋보기 / 오른쪽 지우기 버튼 (입력 칸 아래층)
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                Spacer()
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)

            // 입력 칸: 막대 전체 기준 가운데 정렬
            TextField("", text: $model.query,
                      prompt: Text(L("변환할 형식 검색")).foregroundColor(Theme.textDim))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.text)
                .focused($focused)
                .padding(.horizontal, 38)
                .onSubmit {
                    guard !model.query.isEmpty, let first = model.filtered.first else { return }
                    model.convertStored(first)
                }
        }
        .frame(width: Ring.disc * 2, height: 38) // 링의 왼쪽 끝 ~ 오른쪽 끝
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .onChange(of: model.focusTick) { focused = true }
    }
}

// MARK: - etc / 검색 결과 목록

private struct FormatList: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(model.sourceExt)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.panel)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.text))
                Text(model.fileTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    model.query = ""
                    model.mode = .quick
                } label: {
                    Text(L("‹ 링으로"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(model.filtered.enumerated()), id: \.element.id) { index, format in
                        ListRow(format: format, highlighted: index == 0 && !model.query.isEmpty, model: model)
                    }
                    if model.filtered.isEmpty {
                        Text(L("일치하는 형식이 없습니다"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textDim)
                            .padding(.top, 24)
                    }
                }
            }
        }
    }
}

private struct ListRow: View {
    let format: OutputFormat
    let highlighted: Bool
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 12) {
            Text(format.ext.uppercased())
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(highlighted ? Theme.panel : Theme.text)
                .frame(width: 56, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(highlighted ? Theme.ringHi : Theme.ring))
            VStack(alignment: .leading, spacing: 1) {
                Text(format.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                if let note = format.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                }
            }
            Spacer()
            if highlighted {
                Text("↩ Enter").font(.system(size: 11)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(highlighted ? Theme.accent.opacity(0.10) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(highlighted ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { model.convertStored(format) }
    }
}

// MARK: - 도형

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.06, y: rect.midY + rect.height * 0.04))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.08))
        p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.04, y: rect.minY + rect.height * 0.12))
        return p
    }
}

private struct CrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return p
    }
}
