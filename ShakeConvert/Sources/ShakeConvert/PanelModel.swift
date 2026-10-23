import AppKit
import SwiftUI

func positiveMod(_ a: Double, _ m: Double) -> Double {
    let r = a.truncatingRemainder(dividingBy: m)
    return r < 0 ? r + m : r
}

/// 링 메뉴에서 현재 마우스/드래그가 가리키는 조각과 방향.
/// 액터 격리를 일부러 쓰지 않는다 (SwiftUI DropDelegate 콜백에서 바로 호출되므로). 접근은 항상 메인 스레드.
final class DropState: ObservableObject {
    @Published var hoverID: String?
    @Published var overHub = false
    /// 방향 표시(인디케이터)의 각도. 359°→0°로 넘어갈 때 한 바퀴 거꾸로 돌지 않도록 누적값으로 유지
    @Published var indicatorAngle: Double = 90

    func update(id: String?, angle: Double?, overHub: Bool) {
        if hoverID != id { hoverID = id }
        if self.overHub != overHub { self.overHub = overHub }
        if let angle {
            let delta = positiveMod(angle - indicatorAngle + 180, 360) - 180
            if abs(delta) > 0.01 { indicatorAngle += delta }
        }
    }

    func clear() { update(id: nil, angle: nil, overHub: false) }
}

enum Phase {
    case idle
    case working(source: String, target: OutputFormat, since: Date)
    case done(source: String, target: OutputFormat, since: Date, name: String)
    case failed(message: String, source: String, target: OutputFormat, since: Date)
    /// 암호가 걸린 PDF: 사용자가 암호를 입력할 때까지 기다림 (wrong: 방금 입력한 암호가 틀렸음)
    case needsPassword(file: String, source: String, target: OutputFormat, since: Date, wrong: Bool)
}

@MainActor
final class PanelModel: ObservableObject {
    enum Mode { case quick, list }

    @Published var files: [URL] = []
    @Published var category: Category = .image
    @Published var suggestions: [OutputFormat] = []
    @Published var allFormats: [OutputFormat] = []
    @Published var phase: Phase = .idle
    @Published var outputs: [URL] = []
    @Published var focusTick = 0
    @Published var revealed = false      // 링 펼침 애니메이션 트리거
    @Published var dismissing = false    // 닫힘 애니메이션 트리거
    @Published var progress: Double = 0  // 전체 변환 진행률 0...1
    @Published var fileIndex = 0         // 지금 변환 중인 파일 (0부터)
    @Published var fileCount = 0
    private var conversionTask: Task<Void, Never>?
    /// 암호 입력창에 쓰는 값. 화면에만 두고 저장·기록하지 않으며, 시도 직후 비운다.
    @Published var passwordInput = ""
    private struct Carry {
        var format: OutputFormat
        var source: String
        var produced: [URL]
        var errors: [String]
        var queue: [URL]      // 암호가 필요한 파일들 (앞에서부터 차례로 묻는다)
    }
    private var carry: Carry?
    @Published var query = "" { didSet { updateLayout() } }
    @Published var mode: Mode = .quick { didSet { updateLayout() } }

    let drop = DropState()
    var onLayoutChange: ((Bool) -> Void)?
    var onFinished: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var onNeedsPassword: (() -> Void)?
    private var lastWantsList = false

    var showsList: Bool { mode == .list || !query.isEmpty }
    var busy: Bool { if case .working = phase { return true } else { return false } }
    var awaitingPassword: Bool { if case .needsPassword = phase { return true } else { return false } }
    var isIdle: Bool { if case .idle = phase { return true } else { return false } }
    var filtered: [OutputFormat] { allFormats.filter { $0.matches(query) } }
    var sourceExt: String { String((files.first?.pathExtension ?? "").uppercased().prefix(5)) }

    var fileTitle: String {
        guard let first = files.first else { return "" }
        return files.count > 1 ? L("%@ 외 %ld개", first.lastPathComponent, files.count - 1) : first.lastPathComponent
    }

    private func updateLayout() {
        let wants = showsList
        if wants != lastWantsList {
            lastWantsList = wants
            onLayoutChange?(wants)
        }
    }

    func configure(files: [URL], category: Category) {
        self.files = files
        self.category = category
        if let first = files.first {
            suggestions = Catalog.suggestions(for: first, category: category, limit: 7) // 링: 최대 7 + etc
            allFormats = Catalog.formats(for: category, excludingSourceOf: first)
        }
        phase = .idle
        outputs = []
        carry = nil
        passwordInput = ""
        query = ""
        mode = .quick
        lastWantsList = false
        drop.clear()

        // 패널이 화면에 올라온 직후 링이 회전하며 펼쳐지도록
        revealed = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000)
            self?.revealed = true
        }
    }

    /// 클릭으로 조각 선택
    func select(_ id: String) {
        if id == "etc" {
            mode = .list
            requestFocus()
        } else if let format = formatByID(id) {
            convertStored(format)
        }
    }

    func reset() {
        files = []
        suggestions = []
        allFormats = []
        phase = .idle
        outputs = []
        drop.clear()
        conversionTask?.cancel()
        conversionTask = nil
        carry = nil
        passwordInput = ""
        progress = 0
        revealed = false
        dismissing = false
        query = ""
        mode = .quick
        lastWantsList = false
    }

    func backToIdle() {
        phase = .idle
        outputs = []
    }

    func close() { onClose?() }

    func requestFocus() { focusTick += 1 }

    // MARK: 드롭 / 클릭

    func formatByID(_ id: String) -> OutputFormat? {
        (suggestions + allFormats).first { $0.id == id }
    }

    /// 타일(또는 etc) 위에 놓았을 때
    func handleDrop(_ providers: [NSItemProvider], id: String) -> Bool {
        if id == "hub" {
            close() // 가운데에 놓으면 변환 없이 닫기
            return true
        }
        if id == "etc" {
            loadURLs(from: providers) { [weak self] urls in
                guard let self else { return }
                if let first = urls.first, let cat = Catalog.kind(of: first) {
                    self.configure(files: urls, category: cat)
                }
                self.mode = .list
                self.requestFocus()
            }
            return true
        }
        guard let format = formatByID(id) else { return false }
        loadURLs(from: providers) { [weak self] urls in
            guard let self else { return }
            self.run(urls.isEmpty ? self.files : urls, format: format)
        }
        return true
    }

    func convertStored(_ format: OutputFormat) {
        run(files, format: format)
    }

    private func loadURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let result = urls
            Task { @MainActor in completion(result) }
        }
    }

    // MARK: 변환 실행

    /// 한 번에 변환하는 파일 수 상한 (수천 개를 끌어다 놓아 앱이 멈추는 것 방지)
    static let maxFilesPerRun = 100

    private func run(_ allURLs: [URL], format: OutputFormat) {
        let urls = Array(allURLs.prefix(Self.maxFilesPerRun))
        guard !busy, !urls.isEmpty else { return }
        let source = String(urls[0].pathExtension.uppercased().prefix(5))
        query = ""
        mode = .quick
        outputs = []
        progress = 0
        fileIndex = 0
        fileCount = urls.count
        phase = .working(source: source, target: format, since: Date())

        // 진행률은 변환 스레드에서 자주 들어오므로 걸러서 화면에 반영
        let reporter = ProgressReporter { [self] value in
            Task { @MainActor in self.applyProgress(value) }
        }
        let total = Double(urls.count)

        // 변환은 메인 스레드와 분리된 작업에서 실행 → 변환 중에도 화면(진행 표시)이 멈추지 않음
        conversionTask = Task.detached(priority: .userInitiated) { [self] in
            let started = Date()
            var produced: [URL] = []
            var errors: [String] = []
            var locked: [URL] = []
            var cancelled = false

            for (i, url) in urls.enumerated() {
                if Task.isCancelled { cancelled = true; break }
                await self.setFileIndex(i)
                do {
                    produced += try await Converter.convert(url, to: format) { fraction in
                        reporter.report((Double(i) + fraction) / total)
                    }
                } catch is CancellationError {
                    cancelled = true
                    break
                } catch ConvertError.locked {
                    locked.append(url) // 나머지를 먼저 끝내고, 암호가 필요한 파일은 마지막에 차례로 묻는다
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            if !cancelled && !locked.isEmpty {
                let pending = (produced, errors, locked)
                await self.askPassword(produced: pending.0, errors: pending.1, queue: pending.2,
                                       source: source, format: format)
                return
            }

            if !cancelled {
                reporter.report(1)
                // 너무 빨리 끝나도 100%까지 차오르는 모습이 보이도록 최소 표시 시간 확보
                let elapsed = Date().timeIntervalSince(started)
                if elapsed < 1.0 {
                    try? await Task.sleep(nanoseconds: UInt64((1.0 - elapsed) * 1_000_000_000))
                }
            }
            let result = (produced, errors, cancelled)
            await self.finish(produced: result.0, errors: result.1, cancelled: result.2,
                               source: source, format: format)
        }
    }

    // MARK: 암호가 걸린 PDF

    private func askPassword(produced: [URL], errors: [String], queue: [URL], source: String, format: OutputFormat) {
        conversionTask = nil
        carry = Carry(format: format, source: source, produced: produced, errors: errors, queue: queue)
        presentPasswordPrompt(wrong: false)
    }

    private func presentPasswordPrompt(wrong: Bool) {
        guard let c = carry, let file = c.queue.first else { return }
        passwordInput = ""
        phase = .needsPassword(file: file.lastPathComponent, source: c.source, target: c.format,
                               since: Date(), wrong: wrong)
        onNeedsPassword?()
        requestFocus()
    }

    /// 입력한 암호로 그 파일만 다시 변환한다.
    func submitPassword() {
        guard awaitingPassword, let c = carry, let file = c.queue.first, !passwordInput.isEmpty else { return }
        let password = passwordInput
        passwordInput = "" // 입력값은 즉시 비움
        let format = c.format
        progress = 0
        fileIndex = 0
        fileCount = 1
        phase = .working(source: c.source, target: format, since: Date())

        let reporter = ProgressReporter { [self] value in
            Task { @MainActor in self.applyProgress(value) }
        }
        conversionTask = Task.detached(priority: .userInitiated) { [self] in
            let result: Result<[URL], Error>
            do {
                result = .success(try await Converter.convert(file, to: format, password: password) { fraction in
                    reporter.report(fraction)
                })
            } catch {
                result = .failure(error)
            }
            await self.passwordAttemptFinished(result)
        }
    }

    private func passwordAttemptFinished(_ result: Result<[URL], Error>) {
        conversionTask = nil
        guard var c = carry, !c.queue.isEmpty else { return }
        switch result {
        case .success(let urls):
            c.produced += urls
            c.queue.removeFirst()
        case .failure(let error):
            if error is CancellationError {
                carry = nil
                phase = .idle
                close()
                return
            }
            if let known = error as? ConvertError, case .wrongPassword = known {
                presentPasswordPrompt(wrong: true) // 같은 파일에 다시 묻는다
                return
            }
            let name = c.queue.removeFirst().lastPathComponent
            c.errors.append("\(name): \(error.localizedDescription)")
        }
        carry = c
        if c.queue.isEmpty {
            carry = nil
            finish(produced: c.produced, errors: c.errors, cancelled: false, source: c.source, format: c.format)
        } else {
            presentPasswordPrompt(wrong: false)
        }
    }

    /// 암호 입력을 그만두면 전체를 취소하고 닫는다 (이미 끝난 파일은 그대로 남음).
    func cancelPassword() {
        carry = nil
        passwordInput = ""
        phase = .idle
        close()
    }

    private func setFileIndex(_ index: Int) {
        fileIndex = index
    }

    private func applyProgress(_ value: Double) {
        guard busy else { return }
        progress = max(progress, min(value, 1)) // 순서가 뒤바뀌어 도착해도 뒤로 가지 않음
    }

    private func finish(produced: [URL], errors: [String], cancelled: Bool,
                        source: String, format: OutputFormat) {
        conversionTask = nil
        outputs = produced
        if cancelled {
            // 취소: 이미 끝난 파일은 남겨 두고, 진행 중이던 파일의 임시 결과는 버려진 상태로 닫기
            phase = .idle
            close()
            return
        }
        progress = 1
        if errors.isEmpty {
            let name = produced.count == 1 ? produced[0].lastPathComponent : L("%ld개 파일", produced.count)
            phase = .done(source: source, target: format, since: Date(), name: name)
            onFinished?(true)
            if Prefs.revealAfter { revealOutputs() }
        } else {
            phase = .failed(message: errors.joined(separator: "\n"), source: source, target: format, since: Date())
            onFinished?(false)
        }
    }

    /// 진행 중인 변환 취소 (가운데 클릭 / Esc)
    func cancelConversion() {
        conversionTask?.cancel()
    }

    func revealOutputs() {
        guard !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }
}

/// 변환 스레드에서 오는 진행률을 걸러서(1% 이상 변화 또는 0.1초 경과) 화면 쪽으로 넘긴다.
/// 오디오처럼 초당 수천 번 보고하는 경우에도 화면 갱신이 몰리지 않게 한다.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double = -1
    private var lastTime: TimeInterval = 0
    private let sink: @Sendable (Double) -> Void

    init(sink: @escaping @Sendable (Double) -> Void) {
        self.sink = sink
    }

    func report(_ raw: Double) {
        let value = raw.isFinite ? min(max(raw, 0), 1) : 0
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let forward = value > last && (value - last >= 0.01 || now - lastTime >= 0.1 || value >= 1)
        if forward { last = value; lastTime = now }
        lock.unlock()
        if forward { sink(value) }
    }
}
