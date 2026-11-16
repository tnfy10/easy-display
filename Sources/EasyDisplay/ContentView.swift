import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var controller: DisplayController
    @EnvironmentObject private var updater: Updater

    @State private var showAllModes = false

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
                List(selection: Binding(get: { controller.page }, set: { controller.page = $0 })) {
                    if controller.displays.count > 1 {
                        Section {
                            sidebarRow(icon: "rectangle.3.group", title: "모니터 배치",
                                       detail: controller.isMirroring ? "미러링 사용 중" : "확장 · \(controller.displays.count)대")
                                .tag(DisplayController.Page.arrangement)
                        }
                    }
                    Section {
                        // A plain row, not a section header: clicking a sidebar header collapses the whole list.
                        HStack {
                            Text("모니터").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                controller.refresh()
                                controller.notice = "모니터 \(controller.displays.count)개를 다시 확인했습니다."
                            } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless).help("모니터 목록 새로고침 (⌘R)").accessibilityLabel("모니터 목록 새로고침")
                                .disabled(!controller.isIdle)
                        }.listRowSeparator(.hidden).selectionDisabled()
                        ForEach(controller.displays) { display in
                            sidebarRow(icon: display.isBuiltin ? "laptopcomputer" : "display", title: display.name,
                                       detail: sidebarDetail(display), isMain: display.isMain)
                                .tag(DisplayController.Page.display(display.id))
                        }
                    }
                }
                .listStyle(.sidebar)
                .disabled(!controller.isIdle)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        if !controller.stalledPorts.isEmpty {
                            Label("\(controller.stalledPorts.count)개 포트 연결 실패", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text("v\(updater.currentVersion)")
                    }.font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if updater.phase == .checking {
                        ProgressView().controlSize(.small).help("업데이트 확인 중")
                    } else {
                        Button { Task { await updater.check(userInitiated: true) } } label: {
                            Label("업데이트 확인", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderless).font(.caption)
                        .help("새 버전이 있는지 확인합니다").disabled(updater.phase != .idle)
                    }
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 235, ideal: 260, max: 310)
        } detail: {
            Group {
                if controller.showingArrangement || controller.selected != nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            UpdateBanner()
                            ForEach(controller.visibleStalledPorts) { portWarning($0) }
                            if controller.showingArrangement {
                                arrangementPage
                            } else if let display = controller.selected {
                                displayPage(display)
                            }
                        }.padding(30).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
                    }.background(Color(nsColor: .windowBackgroundColor))
                } else {
                    VStack(spacing: 22) {
                        ForEach(controller.visibleStalledPorts) { portWarning($0) }
                        ContentUnavailableView("연결된 모니터가 없습니다", systemImage: "display.trianglebadge.exclamationmark", description: Text("모니터를 연결하면 자동으로 나타납니다."))
                    }.padding(30).frame(maxWidth: 900)
                }
            }
            .overlay(alignment: .top) { toast }
            .animation(.snappy, value: controller.notice)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onChange(of: controller.selectedID) { showAllModes = false }
        .sheet(isPresented: Binding(get: { controller.pending != nil }, set: { if !$0 { controller.rollback() } })) { previewSheet }
        .sheet(isPresented: $controller.showCustom) { customSheet }
        .sheet(isPresented: Binding(get: { controller.layoutPending != nil }, set: { if !$0 { controller.revertLayout() } })) { layoutSheet }
        .alert("설정을 변경하지 못했습니다", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("확인", role: .cancel) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
        .confirmationDialog("등록 전 HiDPI 설정으로 복원할까요?", isPresented: $controller.showRestoreConfirmation) {
            Button("등록 전 설정 복원", role: .destructive) { controller.restoreOverride() }
        } message: { Text("이 앱이 처음 등록하기 전 파일로 되돌립니다. 관리자 인증과 재시동이 필요합니다.") }
    }

    private func sidebarRow(icon: String, title: String, detail: String, isMain: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    if isMain {
                        Image(systemName: "menubar.rectangle").font(.caption2).foregroundStyle(.secondary)
                            .help("주 모니터 (메뉴 막대·Dock)").accessibilityLabel("주 모니터")
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 5)
    }

    private func sidebarDetail(_ display: ConnectedDisplay) -> String {
        if let source = controller.display(display.mirrorOf) {
            return "\(source.name) 미러링 · \(display.active.sizeLabel)"
        }
        return "\(display.active.sizeLabel) · \(display.active.isHiDPI ? "HiDPI" : "일반 배율")\(display.isPortrait ? " · 세로" : "")\(display.hdrEnabled ? " · HDR" : "")"
    }

    /// Short confirmations float over the page and fade out, so they are seen wherever it is scrolled.
    @ViewBuilder private var toast: some View {
        if let notice = controller.notice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint)
                Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.top, 14).padding(.horizontal, 30)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { controller.notice = nil }
            .help("클릭하면 닫힙니다")
            .task(id: notice) {
                AccessibilityNotification.Announcement(notice).post()
                // Longer messages (e.g. "restart to finish") stay up longer.
                try? await Task.sleep(for: .seconds(min(12, 3.5 + Double(notice.count) * 0.08)))
                if controller.notice == notice { controller.notice = nil }
            }
        }
    }

    private var arrangementPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("모니터 배치").font(.system(size: 28, weight: .bold))
                Text("모든 모니터에 함께 적용되는 설정입니다. 모니터별 해상도는 왼쪽에서 모니터를 선택하세요.")
                    .foregroundStyle(.secondary)
            }
            ArrangementCard()
        }
    }

    @ViewBuilder private func displayPage(_ display: ConnectedDisplay) -> some View {
        header(display)
        signalCard(display)
        if let source = controller.display(display.mirrorOf) {
            mirrorCard(display, source: source)
        } else {
            modeCard(display)
            if display.canRotate { rotationCard(display) }
            if display.supportsHDR { hdrCard(display) }
            if display.colorMode != nil && display.selectableColorModes.count > 1 { colorCard(display) }
            customCard(display)
            Text("HiDPI는 글자와 UI를 더 많은 픽셀로 그린 뒤 화면에 맞춥니다. 최종 선명도는 모니터의 실제 픽셀 밀도에 따라 달라집니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A mirror copy has no settings of its own, so one card explains why and offers the two ways out.
    private func mirrorCard(_ display: ConnectedDisplay, source: ConnectedDisplay) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("‘\(source.name)’ 화면을 복제하는 중", systemImage: "rectangle.on.rectangle").font(.headline)
            Text("이 모니터는 원본 모니터의 화면을 그대로 보여 주고 있어서 해상도, 화면 방향, HDR, 색 출력 형식을 따로 바꿀 수 없어요. 원본 모니터에서 바꾸거나 이 모니터를 독립 화면으로 전환하세요.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("원본 모니터 설정 열기") { controller.open(source) }
                Button("독립 화면으로 전환") { controller.mirror(display, of: nil) }
                    .buttonStyle(.borderedProminent).tint(.mint)
                    .help("확장 화면으로 바꾼 뒤 15초 안에 유지 여부를 확인합니다.")
            }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20).background(cardBackground)
        .disabled(!controller.isIdle)
    }

    private func portWarning(_ port: StalledPort) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cable.connector.slash").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text("\(port.label)에 케이블이 감지됐지만 모니터가 연결되지 않았습니다").font(.headline)
                Text("Mac과 모니터가 화면 신호를 맞추지 못해 macOS가 모니터를 인식하지 못한 상태입니다. 모니터가 꺼져 있거나 다른 입력을 보고 있다면 정상일 수 있어요.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. 이 포트의 케이블을 뽑았다가 다시 꽂으세요.")
                    Text("2. 그래도 안 되면 모니터 전원을 껐다 켜세요.")
                    Text("3. 다른 모니터 케이블도 모두 뺀 뒤 한 대씩 다시 연결하세요.")
                }.font(.callout)
            }
            Spacer(minLength: 0)
            Button { controller.dismissStalledPort(port) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("이 포트가 다시 연결될 때까지 숨기기").accessibilityLabel("경고 닫기")
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
    }

    private func header(_ display: ConnectedDisplay) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(display.name).font(.system(size: 28, weight: .bold))
                Text(display.isBuiltin ? "내장 디스플레이" : "외장 디스플레이 · 모니터별 독립 설정")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func signalCard(_ display: ConnectedDisplay) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("현재 화면", systemImage: "waveform.path.ecg").font(.headline)
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
        let steps = controller.scaledResolutions
        return VStack(alignment: .leading, spacing: 18) {
            Label("해상도와 배율", systemImage: "slider.horizontal.3").font(.headline)
            if steps.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("텍스트 크게", systemImage: "textformat.size.larger")
                        Spacer()
                        Label("공간 넓게", systemImage: "rectangle.expand.vertical")
                    }.font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, mode in
                            resolutionTile(mode, display: display, emphasis: steps.count > 1 ? 1 - Double(index) / Double(steps.count - 1) : 0.5)
                        }
                    }
                }
            }
            if steps.count > 1 {
                DisclosureGroup("모든 해상도 보기", isExpanded: $showAllModes) { allModeControls.padding(.top, 8) }
                    .font(.callout)
            } else {
                allModeControls
            }
            Picker("주사율", selection: $controller.selectedModeID) {
                ForEach(controller.frequencies) { mode in Text(mode.frequencyLabel).tag(Optional(mode.id)) }
            }
            if display.isMirrored {
                HStack(spacing: 10) {
                    Label("미러링 중에는 해상도를 바꿀 수 없습니다. ‘모니터 배치’에서 확장으로 바꾼 뒤 설정해 주세요.", systemImage: "rectangle.on.rectangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("모니터 배치 열기") { controller.openArrangement() }.font(.caption)
                }
            }
            Divider()
            HStack(alignment: .center) {
                applyStatus(display)
                Spacer()
                Button("설정 적용") { controller.preview() }
                    .buttonStyle(.borderedProminent).tint(.mint).controlSize(.large)
                    .disabled(controller.selectedMode == nil || controller.selectedMode?.selectionKey == display.active.selectionKey || controller.busy || display.isMirrored)
            }
        }.padding(20).background(cardBackground).disabled(controller.pending != nil || controller.layoutPending != nil)
    }

    /// Says what "설정 적용" will do, or why it is unavailable, right next to the button.
    @ViewBuilder private func applyStatus(_ display: ConnectedDisplay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if display.isMirrored {
                Text("미러링 중이라 적용할 수 없어요").font(.callout.weight(.medium))
                Text("확장으로 바꾸면 해상도를 설정할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            } else if let target = controller.selectedMode, target.selectionKey != display.active.selectionKey {
                Text("\(modeSummary(display.active)) → \(modeSummary(target))").font(.callout.weight(.medium)).monospacedDigit()
                Text("적용 후 15초 안에 유지를 누르지 않으면 이전 설정으로 돌아갑니다.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("현재 설정과 같아요").font(.callout.weight(.medium))
                Text("화면 크기나 주사율을 고르면 적용할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func modeSummary(_ mode: DisplayMode) -> String {
        "\(mode.sizeLabel) \(mode.isHiDPI ? "HiDPI" : "일반 배율") · \(mode.frequencyLabel)"
    }

    private var allModeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("화면 크기", selection: Binding(get: { controller.selectedResolutionKey }, set: { controller.selectedResolutionKey = $0 })) {
                ForEach(controller.availableResolutions) { mode in
                    Text("\(mode.sizeLabel)  ·  \(mode.isHiDPI ? "HiDPI" : "일반 배율")").tag(mode.resolutionKey)
                }
            }
            Toggle("일반 배율 해상도도 표시", isOn: $controller.showLoDPI).font(.callout)
        }
    }

    /// One step of the text-size scale; the "Aa" shrinks as the desktop gets more space.
    private func resolutionTile(_ mode: DisplayMode, display: ConnectedDisplay, emphasis: Double) -> some View {
        let selected = controller.selectedMode?.resolutionKey == mode.resolutionKey
        let isCurrent = display.active.resolutionKey == mode.resolutionKey
        let crisp = display.nativeWidth > 0
            && Set([mode.pixelWidth, mode.pixelHeight]) == Set([display.nativeWidth, display.nativeHeight])
        return Button { controller.selectedResolutionKey = mode.resolutionKey } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.2), lineWidth: 1))
                    .overlay(Text("Aa").font(.system(size: 9 + 13 * emphasis, weight: .semibold)).foregroundStyle(.secondary))
                    .frame(height: 44)
                Text(mode.sizeLabel).font(.caption.weight(.medium)).monospacedDigit().lineLimit(1)
                HStack(spacing: 4) {
                    if isCurrent { badge("현재", color: .secondary) }
                    if crisp { badge("가장 선명", color: .mint) }
                }.frame(height: 14)
            }
            .padding(8).frame(maxWidth: .infinity)
            .background(selected ? Color.mint.opacity(0.14) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.mint : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(crisp ? "패널 픽셀과 1:1로 그려 가장 선명합니다." : "\(mode.pixelWidth) × \(mode.pixelHeight)로 렌더링합니다.")
        .accessibilityLabel("\(mode.sizeLabel)\(isCurrent ? ", 현재 설정" : "")\(crisp ? ", 가장 선명" : "")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func rotationCard(_ display: ConnectedDisplay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("화면 방향", systemImage: display.isPortrait ? "rectangle.portrait" : "rectangle").font(.headline)
            Picker("화면 방향", selection: Binding(
                get: { DisplayRotation(rawValue: display.rotation) ?? .standard },
                set: { controller.setRotation(display, to: $0) }
            )) {
                ForEach(DisplayRotation.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Text("모니터를 세로로 세워 쓸 때 화면을 회전합니다. 고르는 즉시 바뀌고, 15초 안에 유지를 누르지 않으면 이전 방향으로 돌아갑니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20).background(cardBackground)
        .disabled(!controller.isIdle)
    }

    private func hdrCard(_ display: ConnectedDisplay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("HDR (High Dynamic Range)", systemImage: "sun.max").font(.headline)
                Spacer()
                Toggle("HDR", isOn: Binding(get: { display.hdrEnabled }, set: { controller.setHDR(display, enabled: $0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            Text("HDR 영상·사진·게임을 더 넓은 밝기와 색 범위로 표시합니다. 켜면 일반 화면이 어둡거나 색이 다르게 보일 수 있어요. 누르는 즉시 바뀌고, 15초 안에 유지를 누르지 않으면 이전 설정으로 돌아갑니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20).background(cardBackground)
        .disabled(!controller.isIdle)
    }

    private func colorCard(_ display: ConnectedDisplay) -> some View {
        let modes = display.selectableColorModes
        let ranges = [true, false].filter { full in modes.contains { $0.isRGB && $0.isFullRange == full } }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("색 출력 형식", systemImage: "paintpalette").font(.headline)
                Spacer()
                if let current = display.colorMode {
                    Text("현재 \(current.label)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !ranges.isEmpty {
                HStack {
                    Text("RGB 범위").font(.callout)
                    Spacer()
                    Picker("RGB 범위", selection: Binding<Bool?>(
                        get: { display.colorMode.flatMap { $0.isRGB ? $0.isFullRange : nil } },
                        set: { if let full = $0 { controller.setRGBRange(display, fullRange: full) } }
                    )) {
                        ForEach(ranges, id: \.self) { full in
                            Text(full ? "Full (0–255)" : "Limited (16–235)").tag(Optional(full))
                        }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            // A menu picker under fixedSize() measures before its items exist and only widens once opened,
            // so it fills the row like the refresh rate picker instead.
            Picker("세부 형식", selection: Binding(
                get: { display.colorMode ?? modes[0] },
                set: { controller.setColorMode(display, to: $0) }
            )) {
                ForEach(modes) { Text($0.label).tag($0) }
            }
            Text("PC 모니터는 보통 RGB Full, TV는 Limited가 표준입니다. 검은색이 회색처럼 뜨고 색이 바래 보이면 RGB Full을, 어두운 부분이 뭉개지면 Limited를 고르거나 모니터의 입력 범위 설정과 맞춰 보세요. 고르는 즉시 바뀌고, 15초 안에 유지를 누르지 않으면 이전 설정으로 돌아갑니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20).background(cardBackground)
        .disabled(!controller.isIdle)
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
        confirmSheet(icon: "display", title: "이 화면 설정을 유지할까요?",
                     summary: controller.selected.map { modeSummary($0.active) } ?? "",
                     keep: controller.keep, revert: controller.rollback) {
            if let display = controller.selected {
                VStack(spacing: 6) {
                    Text("모니터 출력 신호: \(display.signal?.label ?? "확인 불가")").font(.callout.weight(.medium))
                    if let before = controller.pending?.initialSignal, let now = display.signal,
                       before.width != now.width || before.height != now.height {
                        Label("출력 신호 해상도가 바뀌었습니다. 모니터 경고가 보이면 복구하세요.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }.padding(12).frame(maxWidth: .infinity).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var layoutSheet: some View {
        confirmSheet(icon: "rectangle.3.group", title: controller.layoutPending?.title ?? "이 설정을 유지할까요?",
                     summary: controller.layoutPending?.summary ?? "",
                     keep: controller.keepLayout, revert: controller.revertLayout) { EmptyView() }
    }

    /// Every timed change confirms the same way: Return keeps it, Esc or the countdown reverts it.
    private func confirmSheet<Extra: View>(icon: String, title: String, summary: String,
                                           keep: @escaping () -> Void, revert: @escaping () -> Void,
                                           @ViewBuilder extra: () -> Extra) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 42)).foregroundStyle(.mint)
            Text(title).font(.title2.bold())
            Text(summary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            extra()
            Text("화면이 보이지 않거나 모니터 경고가 나타나면 그대로 기다리세요. 자동으로 복구됩니다.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ProgressView(value: Double(controller.remainingSeconds), total: 15).tint(.mint)
                    .animation(.linear(duration: 1), value: controller.remainingSeconds)
                Text("\(controller.remainingSeconds)초 후 이전 설정으로 자동 복구").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("이전 설정으로 복구", role: .cancel, action: revert).keyboardShortcut(.cancelAction)
                Button("이 설정 유지", action: keep).buttonStyle(.borderedProminent).tint(.mint).keyboardShortcut(.defaultAction)
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
