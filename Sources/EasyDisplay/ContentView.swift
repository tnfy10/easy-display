import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var controller: DisplayController

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "display.2").font(.title2).foregroundStyle(.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Easy Display").font(.headline)
                        Text("내 화면에 맞게, 선명하게").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.top, 22)
                List(controller.displays) { display in
                    Button { controller.select(display) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                                .font(.title2).foregroundStyle(controller.selectedID == display.id ? Color.mint : Color.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(display.name).fontWeight(.medium).lineLimit(1)
                                Text("\(display.active.sizeLabel) · \(display.active.isHiDPI ? "HiDPI" : "일반")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if display.isMain { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("주 모니터") }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(controller.selectedID == display.id ? Color.mint.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).listRowSeparator(.hidden)
                        .disabled(controller.pending != nil)
                }.listStyle(.sidebar)
                HStack {
                    Label("\(controller.displays.count)개 연결됨", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { controller.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("모니터 새로고침").accessibilityLabel("모니터 새로고침")
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 235, ideal: 260, max: 310)
        } detail: {
            if let display = controller.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header(display)
                        signalCard(display)
                        if let notice = controller.notice {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint)
                                Text(notice).font(.callout).textSelection(.enabled)
                                Spacer()
                                Button { controller.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("안내 닫기")
                            }.padding(14).background(Color.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        modeCard(display)
                        customCard(display)
                        Text("HiDPI는 글자와 UI를 더 많은 픽셀로 그린 뒤 화면에 맞춥니다. 최종 선명도는 모니터의 실제 픽셀 밀도에 따라 달라집니다.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(30).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
                }.background(Color(nsColor: .windowBackgroundColor))
            } else {
                ContentUnavailableView("연결된 모니터가 없습니다", systemImage: "display.trianglebadge.exclamationmark", description: Text("모니터를 연결한 뒤 새로고침해 주세요."))
            }
        }
        .frame(minWidth: 880, minHeight: 700)
        .toolbar {
            ToolbarItem {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.diagnosticText, forType: .string)
                    controller.notice = "모니터 진단 정보를 복사했습니다."
                } label: { Label("진단 정보 복사", systemImage: "doc.on.doc") }
                .help("현재 모드와 실제 출력 정보를 복사")
            }
        }
        .sheet(isPresented: Binding(get: { controller.pending != nil }, set: { if !$0 { controller.rollback() } })) { previewSheet }
        .sheet(isPresented: $controller.showCustom) { customSheet }
        .alert("설정을 변경하지 못했습니다", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("확인", role: .cancel) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
        .confirmationDialog("등록 전 HiDPI 설정으로 복원할까요?", isPresented: $controller.showRestoreConfirmation) {
            Button("등록 전 설정 복원", role: .destructive) { controller.restoreOverride() }
        } message: { Text("이 앱이 처음 등록하기 전 파일로 되돌립니다. 관리자 인증과 재시동이 필요합니다.") }
    }

    private func header(_ display: ConnectedDisplay) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(display.name).font(.system(size: 28, weight: .bold))
                Text(display.isBuiltin ? "내장 디스플레이" : "외장 디스플레이 · 모니터별 독립 설정")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(display.active.isHiDPI ? "HiDPI 사용 중" : "일반 배율")
                .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                .background(display.active.isHiDPI ? Color.mint.opacity(0.15) : Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    private func signalCard(_ display: ConnectedDisplay) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Label("현재 화면", systemImage: "waveform.path.ecg").font(.headline); Spacer(); Text("실시간 확인").font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .top, spacing: 24) {
                metric("화면에 보이는 크기", value: display.active.sizeLabel, detail: display.active.isHiDPI ? "HiDPI · 2배 렌더링" : "일반 배율 · 1배 렌더링")
                Divider()
                metric("모니터 출력 신호", value: display.signal.map { "\($0.width) × \($0.height)" } ?? "확인 불가", detail: display.signal?.refreshRate.map { "\($0.formatted(.number.precision(.fractionLength(0...2)))) Hz" } ?? "이 환경에서 신호를 읽을 수 없습니다")
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                Text("내부 렌더링 \(display.active.pixelWidth) × \(display.active.pixelHeight)")
                Spacer()
                if display.nativeWidth > 0 { Text("기본 패널 \(display.nativeWidth) × \(display.nativeHeight)") }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(cardBackground)
    }

    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modeCard(_ display: ConnectedDisplay) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("해상도와 배율", systemImage: "slider.horizontal.3").font(.headline)
            Text("화면 크기와 주사율을 선택한 뒤 ‘설정 적용’을 누르세요.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("화면 크기", selection: Binding(get: { controller.selectedResolutionKey }, set: { controller.selectedResolutionKey = $0 })) {
                ForEach(controller.availableResolutions) { mode in
                    Text("\(mode.sizeLabel)  ·  \(mode.isHiDPI ? "HiDPI" : "일반 배율")").tag(mode.resolutionKey)
                }
            }
            Picker("주사율", selection: $controller.selectedModeID) {
                ForEach(controller.frequencies) { mode in Text(mode.frequencyLabel).tag(Optional(mode.id)) }
            }
            Toggle("일반 배율(LoDPI) 모드도 표시", isOn: $controller.showLoDPI).font(.callout)
            if display.isMirrored {
                Label("미러링 중에는 변경할 수 없습니다. macOS 디스플레이 설정에서 미러링을 해제해 주세요.", systemImage: "rectangle.on.rectangle").font(.caption).foregroundStyle(.orange)
            }
            Divider()
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("적용 후 15초 안에 유지 여부를 선택하세요").font(.callout.weight(.medium))
                    Text("확인하지 않으면 이전 설정으로 자동 복구됩니다.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("설정 적용") { controller.preview() }
                    .buttonStyle(.borderedProminent).tint(.mint).controlSize(.large)
                    .help(controller.selectedMode?.selectionKey == display.active.selectionKey
                          ? "현재 설정과 같습니다. 화면 크기나 주사율을 바꾸면 적용할 수 있습니다."
                          : "선택한 설정을 적용하고 유지 여부를 확인합니다.")
                    .disabled(controller.selectedMode == nil || controller.selectedMode?.selectionKey == display.active.selectionKey || controller.busy || display.isMirrored)
            }
        }.padding(20).background(cardBackground).disabled(controller.pending != nil)
    }

    private func customCard(_ display: ConnectedDisplay) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack").font(.title).foregroundStyle(.mint)
            VStack(alignment: .leading, spacing: 6) {
                Text("원하는 HiDPI 크기가 없나요?").font(.headline)
                Text("사용자 지정 모드를 등록하고 재시동한 뒤 선택할 수 있어요.")
                    .font(.caption).foregroundStyle(.secondary)
                if OverrideStore.hasBackup(display.identity) {
                    Button("등록 전 설정 복원…") { controller.showRestoreConfirmation = true }.font(.caption).buttonStyle(.link).disabled(controller.busy)
                }
            }
            Spacer()
            if controller.busy { ProgressView().controlSize(.small) }
            Button("모드 추가…") { controller.showCustom = true }.disabled(controller.busy || display.isBuiltin || display.isMirrored)
        }.padding(20).background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var previewSheet: some View {
        VStack(spacing: 20) {
            Image(systemName: "display").font(.system(size: 42)).foregroundStyle(.mint)
            Text("이 화면 설정을 유지할까요?").font(.title2.bold())
            if let display = controller.selected {
                Text("\(display.active.sizeLabel) · \(display.active.isHiDPI ? "HiDPI" : "일반 배율") · \(display.active.frequencyLabel)")
                VStack(spacing: 6) {
                    Text("모니터 출력 신호: \(display.signal?.label ?? "확인 불가")").font(.callout.weight(.medium))
                    if let before = controller.pending?.initialSignal, let now = display.signal,
                       before.width != now.width || before.height != now.height {
                        Label("출력 신호 해상도가 바뀌었습니다. 모니터 경고가 보이면 복구하세요.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }.padding(12).frame(maxWidth: .infinity).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("\(controller.remainingSeconds)초 후 이전 설정으로 자동 복구").monospacedDigit().foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("이전 설정으로 복구", role: .cancel) { controller.rollback() }.keyboardShortcut(.cancelAction)
                Button("이 설정 유지") { controller.keep() }.buttonStyle(.borderedProminent).tint(.mint)
            }.controlSize(.large)
        }.padding(32).frame(width: 480).interactiveDismissDisabled()
    }

    private var customSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("사용자 지정 HiDPI 모드", systemImage: "plus.rectangle.on.rectangle").font(.title2.bold())
            Text("모니터에 보이게 할 화면 크기를 입력하세요. 예를 들어 1920×1080 HiDPI는 내부에서 3840×2160으로 렌더링합니다.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("1920x1080, 2048x1152", text: $controller.customInput).textFieldStyle(.roundedBorder)
                .accessibilityLabel("추가할 HiDPI 해상도")
            Text("쉼표로 구분 · 최대 24개 · 가로 640~3840 / 세로 360~2160").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Label("관리자 인증 후 모니터 모델 전용 설정 파일을 등록합니다.", systemImage: "lock")
                Label("같은 제조사·모델의 모니터에는 함께 적용됩니다.", systemImage: "display.2")
                Label("재시동 후 사용 가능 여부를 확인해야 합니다. 모든 모드·주사율이 보장되지는 않습니다.", systemImage: "arrow.clockwise")
                Label("기존 파일은 백업하며 앱에서 등록 전 설정으로 복원할 수 있습니다.", systemImage: "arrow.uturn.backward")
            }.font(.callout).padding(16).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Spacer()
                Button("취소", role: .cancel) { controller.showCustom = false }
                Button("등록하기") { controller.installCustom() }.buttonStyle(.borderedProminent).tint(.mint)
            }
        }.padding(28).frame(width: 550)
    }
}
