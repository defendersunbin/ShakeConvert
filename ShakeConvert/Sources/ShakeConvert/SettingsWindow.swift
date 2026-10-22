import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 740),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = L("ShakeConvert 설정")
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(store: SettingsStore.shared))
            w.center()
            window = w
        }
        SettingsStore.shared.refreshLogin()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section(L("일반")) {
                    Toggle(L("로그인 시 자동 실행"), isOn: Binding(
                        get: { store.launchAtLogin },
                        set: { store.setLaunchAtLogin($0) }
                    ))
                    if !store.isInApplicationsFolder {
                        Text(L("응용 프로그램(Applications) 폴더에 설치한 뒤 켜는 것을 권장합니다."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let message = store.loginMessage {
                        HStack {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(L("로그인 항목 열기")) { store.openLoginItemsSettings() }
                                .controlSize(.small)
                        }
                    }
                    Toggle(L("실행할 때 알림 표시"), isOn: $store.showLaunchToast)
                }

                Section(L("외관")) {
                    Picker(L("테마"), selection: $store.appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section(L("언어")) {
                    Picker(L("표시 언어"), selection: $store.language) {
                        Text(L("시스템 언어 따르기")).tag("")
                        ForEach(AppLanguage.all) { Text($0.name).tag($0.code) }
                    }
                    if store.needsRestart {
                        HStack {
                            Text(L("다시 시작하면 적용됩니다.")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(L("지금 다시 시작")) { AppMover.relaunch() }
                                .controlSize(.small)
                        }
                    }
                }

                Section(L("흔들기 · 저장")) {
                    Picker(L("흔들기 감도"), selection: $store.sensitivity) {
                        ForEach(ShakeSensitivity.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker(L("저장 위치"), selection: $store.saveLocation) {
                        ForEach(SaveLocation.allCases) { Text($0.label).tag($0) }
                    }
                    Picker(L("변환 완료 후 자동으로 닫기"), selection: $store.autoClose) {
                        ForEach(AutoClose.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle(L("변환 후 Finder에서 결과 보기"), isOn: $store.revealAfter)
                }

                Section(L("변환 품질")) {
                    HStack {
                        Text(L("JPEG · HEIC 품질"))
                        Slider(value: $store.imageQuality, in: 0.6...1.0, step: 0.05)
                        Text("\(Int((store.imageQuality * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    Picker(L("문서 → PDF 용지"), selection: $store.paperSize) {
                        ForEach(PaperSize.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 740)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("ShakeConvert").font(.system(size: 17, weight: .semibold))
                Text(L("버전 %@", AppInfo.version)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(L("모든 변환은 이 Mac 안에서만"), systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }
}
