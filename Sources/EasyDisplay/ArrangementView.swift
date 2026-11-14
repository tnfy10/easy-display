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
            HStack(spacing: 12) {
                modeOption(mirroring: false, title: "확장", icon: "rectangle.split.2x1",
                           detail: "모니터마다 다른 화면을 띄워 작업 공간을 넓혀요. 창을 옆 모니터로 옮길 수 있어요.")
                modeOption(mirroring: true, title: "미러링", icon: "rectangle.on.rectangle",
                           detail: "모든 모니터에 같은 화면을 보여줘요. 발표하거나 TV에 연결할 때 좋아요.")
            }
            if controller.isMirroring { mirroringSection } else { extendSection }
            if controller.displays.count > 2 { advancedSection }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1)))
        .disabled(!controller.isIdle)
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
            ArrangementCanvas().frame(height: 230)
            HStack(spacing: 18) {
                legend("hand.draw", "끌어서 실제 책상 위치에 맞춰요")
                legend("menubar.rectangle", "위쪽 막대 = 주 모니터")
            }
            mainPicker
        }
    }

    private var mirroringSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            let sources = controller.arrangeable
            Picker("복제할 원본 화면", selection: Binding(
                get: { controller.mirrorSource?.id },
                set: { id in if let source = controller.display(id) { controller.setMirrorSource(source) } })) {
                ForEach(sources) { Text($0.name).tag(Optional($0.id)) }
            }
            if let source = controller.mirrorSource {
                Text("\(controller.mirrors(of: source).map(\.name).joined(separator: ", "))에 \(source.name) 화면이 똑같이 표시돼요. 해상도는 원본 모니터 기준으로 맞춰집니다.")
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
}

struct ArrangementCanvas: View {
    @EnvironmentObject private var controller: DisplayController
    @State private var dragging: CGDirectDisplayID?
    @State private var translation: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let items = controller.arrangeable
            let union = items.reduce(CGRect.null) { $0.union($1.bounds) }
            // Leave room around the layout so displays can be dropped on any side.
            let scale = union.isNull ? 1 : min(geometry.size.width / (union.width * 1.6), geometry.size.height / (union.height * 1.6))
            let offset = CGPoint(x: (geometry.size.width - union.width * scale) / 2 - union.minX * scale,
                                 y: (geometry.size.height - union.height * scale) / 2 - union.minY * scale)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07))
                ForEach(items) { display in
                    let frame = display.bounds
                    let moved = dragging == display.id ? translation : .zero
                    tile(display)
                        .frame(width: max(frame.width * scale - 4, 10), height: max(frame.height * scale - 4, 10))
                        .position(x: offset.x + frame.midX * scale + moved.width, y: offset.y + frame.midY * scale + moved.height)
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
            .coordinateSpace(name: "arrangement")
        }
    }

    private func tile(_ display: ConnectedDisplay) -> some View {
        let selected = controller.selectedID == display.id
        let mirrors = controller.mirrors(of: display)
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.mint.opacity(0.28) : Color(nsColor: .windowBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.mint : Color.primary.opacity(0.25), lineWidth: selected ? 2 : 1))
            if display.isMain {
                // Stands in for the menu bar, as in System Settings.
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.55)).frame(height: 5).padding(.horizontal, 6).padding(.top, 5)
            }
            VStack(spacing: 2) {
                Text(display.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(display.active.sizeLabel).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
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
