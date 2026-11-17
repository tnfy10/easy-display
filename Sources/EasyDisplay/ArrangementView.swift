import SwiftUI
import AppKit

/// Global multi-display settings: extend vs. mirror, main display, and drag-to-arrange.
struct ArrangementCard: View {
    @EnvironmentObject private var controller: DisplayController
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Label("여러 모니터 사용 방식", systemImage: "rectangle.3.group").font(.headline)
                Text("모니터 \(controller.displays.count)대가 연결되어 있어요. 어떻게 쓸지 고르세요.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                modeOption(mirroring: false, title: "확장", icon: "rectangle.split.2x1", detail: extendDetail)
                modeOption(mirroring: true, title: "미러링", icon: "rectangle.on.rectangle", detail: mirrorDetail)
            }
            if controller.isMirroring { mirroringSection } else { extendSection }
            if controller.displays.count > 2 { advancedSection }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1)))
        .disabled(!controller.isIdle)
    }

    /// The display mirroring copies: the current source, or the main display that `setMirroring(true)` will use.
    private var mirrorSourceCandidate: ConnectedDisplay? {
        controller.isMirroring ? controller.mirrorSource
            : controller.arrangeable.first(where: \.isMain) ?? controller.arrangeable.first
    }

    private func names(_ displays: [ConnectedDisplay]) -> String {
        displays.map { "‘\($0.name)’" }.joined(separator: ", ")
    }

    private var extendDetail: String {
        "\(names(controller.displays))에 서로 다른 화면을 띄워 작업 공간을 넓혀요. 창을 옆 모니터로 옮길 수 있어요."
    }

    private var mirrorDetail: String {
        guard let source = mirrorSourceCandidate else { return "모든 모니터에 같은 화면을 보여줘요." }
        let copies = controller.displays.filter { $0.id != source.id }
        return "‘\(source.name)’ 화면을 \(names(copies))에도 똑같이 보여줘요."
            + (controller.isMirroring ? "" : " 원본 모니터는 바꾼 뒤 고를 수 있어요.")
    }

    private func modeOption(mirroring: Bool, title: String, icon: String, detail: String) -> some View {
        let selected = controller.isMirroring == mirroring
        return Button { controller.setMirroring(mirroring) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(selected ? Color.mint : Color.secondary).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.body.weight(.semibold))
                        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint).accessibilityLabel("사용 중") }
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ModeDiagram(mirroring: mirroring, displays: controller.displays, source: mirrorSourceCandidate?.id)
                        .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.mint.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.mint : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selected ? "지금 사용 중인 방식입니다." : "\(title)(으)로 바꾼 뒤 15초 안에 유지 여부를 확인합니다.")
    }

    private var extendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("모니터 위치 맞추기").font(.subheadline.weight(.semibold))
            ArrangementCanvas().frame(height: 300)
            HStack(spacing: 18) {
                legend("hand.draw", "끌면 놓일 자리와 정렬선이 보여요")
                legend("menubar.rectangle", "위쪽 막대 = 주 모니터")
            }
            mainPicker
        }
    }

    private var mirroringSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            let sources = controller.arrangeable
            Picker("원본 모니터 (이 화면이 복제돼요)", selection: Binding(
                get: { controller.mirrorSource?.id },
                set: { id in if let source = controller.display(id) { controller.setMirrorSource(source) } })) {
                ForEach(controller.displays) { Text($0.name).tag(Optional($0.id)) }
            }
            if let source = controller.mirrorSource {
                HStack(spacing: 10) {
                    roleTile(source, role: "원본")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    ForEach(controller.mirrors(of: source)) { roleTile($0, role: "복제") }
                }
                Text("‘\(source.name)’ 화면이 \(names(controller.mirrors(of: source)))에 똑같이 표시돼요. 해상도는 원본 모니터 기준으로 맞춰집니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if sources.count > 1 {
                ArrangementCanvas().frame(height: 200)
                mainPicker
            }
        }
    }

    /// The main display carries the menu bar and Dock and is where new windows open.
    private var mainPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("주 모니터 (메뉴 막대·Dock)", selection: Binding(
                get: { controller.arrangeable.first(where: \.isMain)?.id },
                set: { id in if let display = controller.display(id) { controller.setMain(display) } })) {
                ForEach(controller.arrangeable) { Text($0.name).tag(Optional($0.id)) }
            }
            Text("새 창과 메뉴 막대, Dock이 주 모니터에 표시됩니다.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("고급: 일부 모니터만 미러링", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
                Text("모니터마다 독립 화면으로 쓸지, 다른 모니터 화면을 복제할지 정할 수 있어요.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(controller.displays) { display in
                    let sources = controller.displays.filter { $0.id != display.id && $0.mirrorOf == nil }
                    Picker(display.name, selection: Binding(
                        get: { display.mirrorOf },
                        set: { id in controller.mirror(display, of: controller.display(id)) })) {
                        Text("독립 화면").tag(CGDirectDisplayID?.none)
                        ForEach(sources) { Text("\($0.name) 화면 복제").tag(Optional($0.id)) }
                    }
                }
            }.padding(.top, 8)
        }.font(.callout)
    }

    private func legend(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(.secondary)
    }

    private func roleTile(_ display: ConnectedDisplay, role: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(role).font(.caption2.weight(.semibold)).foregroundStyle(role == "원본" ? Color.mint : Color.secondary)
            Label(display.name, systemImage: "display").font(.callout.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(role == "원본" ? Color.mint.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Miniature of what each monitor will show: distinct content when extending,
/// the source's content repeated when mirroring.
private struct ModeDiagram: View {
    let mirroring: Bool
    let displays: [ConnectedDisplay]
    let source: CGDirectDisplayID?

    private static let contents = ["doc.text", "safari", "music.note", "photo"]

    var body: some View {
        let ordered = displays.sorted { ($0.id == source ? 0 : 1) < ($1.id == source ? 0 : 1) }
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, display in
                let isSource = display.id == source
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(mirroring && isSource ? Color.mint : Color.primary.opacity(0.25),
                                                                       lineWidth: mirroring && isSource ? 1.5 : 1))
                        .overlay(Image(systemName: mirroring ? Self.contents[0] : Self.contents[index % Self.contents.count])
                            .font(.caption).foregroundStyle(.secondary))
                        .frame(width: 54, height: 32)
                    Text(display.name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 70)
                    if mirroring { Text(isSource ? "원본" : "복제").font(.system(size: 9, weight: .semibold)).foregroundStyle(isSource ? Color.mint : Color.secondary) }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct ArrangementCanvas: View {
    @EnvironmentObject private var controller: DisplayController
    @State private var dragging: CGDirectDisplayID?
    @State private var translation: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let items = controller.arrangeable
            let union = items.reduce(CGRect.null) { $0.union($1.bounds) }
            // Leave room for the largest display on every side, so a drop target is never drawn off the canvas.
            let margin = items.reduce(CGSize.zero) { CGSize(width: max($0.width, $1.bounds.width), height: max($0.height, $1.bounds.height)) }
            let scale = union.isNull ? 1 : min(geometry.size.width / (union.width + margin.width * 2.1),
                                               geometry.size.height / (union.height + margin.height * 2.1))
            let offset = CGPoint(x: (geometry.size.width - union.width * scale) / 2 - union.minX * scale,
                                 y: (geometry.size.height - union.height * scale) / 2 - union.minY * scale)
            let preview = dragPreview(items: items, scale: scale)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07))
                if let preview {
                    snapOverlay(preview, scale: scale, offset: offset)
                }
                ForEach(items) { display in
                    let frame = display.bounds
                    let moved = dragging == display.id ? translation : .zero
                    tile(display, blocked: dragging == display.id && preview?.target == nil)
                        .frame(width: max(frame.width * scale - 4, 10), height: max(frame.height * scale - 4, 10))
                        .position(x: offset.x + frame.midX * scale + moved.width, y: offset.y + frame.midY * scale + moved.height)
                        .opacity(dragging == display.id ? 0.75 : 1)
                        .zIndex(dragging == display.id ? 1 : 0)
                        .onTapGesture { controller.select(display) }
                        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("arrangement"))
                            .onChanged { value in
                                dragging = display.id
                                translation = value.translation
                            }
                            .onEnded { value in
                                controller.move(display, by: CGSize(width: value.translation.width / scale, height: value.translation.height / scale))
                                dragging = nil
                                translation = .zero
                            })
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .coordinateSpace(name: "arrangement")
        }
    }

    /// Where the dragged display will land, using the same snapping as the drop itself.
    private struct DragPreview {
        let target: CGRect?
        let guides: [DisplayArrangement.Guide]
        /// Other displays pulled along to stay joined, at their new places.
        var shifted: [CGRect] = []
    }

    private func dragPreview(items: [ConnectedDisplay], scale: CGFloat) -> DragPreview? {
        guard let id = dragging, scale > 0, let display = items.first(where: { $0.id == id }) else { return nil }
        let dropped = display.bounds.offsetBy(dx: translation.width / scale, dy: translation.height / scale)
        let frames = Dictionary(uniqueKeysWithValues: items.map { ($0.uuid, $0.bounds) })
        guard let result = DisplayArrangement.drop(display.uuid, at: dropped, frames: frames),
              let target = result[display.uuid] else { return DragPreview(target: nil, guides: []) }
        let others = result.filter { $0.key != display.uuid }
        return DragPreview(target: target, guides: DisplayArrangement.guides(for: target, others: Array(others.values)),
                           shifted: others.filter { frames[$0.key] != $0.value }.map(\.value))
    }

    @ViewBuilder private func snapOverlay(_ preview: DragPreview, scale: CGFloat, offset: CGPoint) -> some View {
        let dash = StrokeStyle(lineWidth: 1, dash: [4, 3])
        ForEach(Array(preview.guides.enumerated()), id: \.offset) { _, guide in
            Path { path in
                switch guide.axis {
                case .vertical:
                    let x = offset.x + guide.position * scale
                    path.move(to: CGPoint(x: x, y: offset.y + guide.start * scale - 12))
                    path.addLine(to: CGPoint(x: x, y: offset.y + guide.end * scale + 12))
                case .horizontal:
                    let y = offset.y + guide.position * scale
                    path.move(to: CGPoint(x: offset.x + guide.start * scale - 12, y: y))
                    path.addLine(to: CGPoint(x: offset.x + guide.end * scale + 12, y: y))
                }
            }.stroke(Color.mint, style: dash)
        }
        ForEach(Array(preview.shifted.enumerated()), id: \.offset) { _, frame in
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.mint.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: max(frame.width * scale - 4, 10), height: max(frame.height * scale - 4, 10))
                .position(x: offset.x + frame.midX * scale, y: offset.y + frame.midY * scale)
                .accessibilityHidden(true)
        }
        if let target = preview.target {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.mint.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                .frame(width: max(target.width * scale - 4, 10), height: max(target.height * scale - 4, 10))
                .position(x: offset.x + target.midX * scale, y: offset.y + target.midY * scale)
                .accessibilityHidden(true)
        }
    }

    private func tile(_ display: ConnectedDisplay, blocked: Bool = false) -> some View {
        let selected = controller.selectedID == display.id
        let mirrors = controller.mirrors(of: display)
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.mint.opacity(0.28) : Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(blocked ? Color.red : selected ? Color.mint : Color.primary.opacity(0.25),
                                                                  lineWidth: blocked || selected ? 2 : 1))
            if display.isMain {
                // Stands in for the menu bar, as in System Settings.
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.55)).frame(height: 5).padding(.horizontal, 6).padding(.top, 5)
            }
            VStack(spacing: 2) {
                Text(display.name).font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Text(display.active.sizeLabel).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if !mirrors.isEmpty {
                    Label(mirrors.map(\.name).joined(separator: ", "), systemImage: "rectangle.on.rectangle")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(6).frame(maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .help("클릭해서 선택, 끌어서 위치 변경")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(display.name)\(display.isMain ? ", 주 모니터" : "")\(mirrors.isEmpty ? "" : ", 미러링 원본")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
