import SwiftUI
import AppKit

/// Global multi-display settings: extend vs. mirror, main display, and drag-to-arrange.
struct ArrangementCard: View {
    @EnvironmentObject private var controller: DisplayController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("여러 모니터 배치", systemImage: "rectangle.3.group").font(.headline)
                Spacer()
                Picker("화면 사용 방식", selection: Binding(get: { controller.isMirroring }, set: { controller.setMirroring($0) })) {
                    Text("확장").tag(false)
                    Text("미러링").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                    .help("확장: 모니터마다 다른 화면 · 미러링: 같은 화면을 함께 표시")
            }
            Text(controller.isMirroring
                 ? "미러링 중인 모니터는 원본 모니터와 함께 표시됩니다. 모니터를 끌어 위치를 바꾸거나, 아래에서 모니터별로 미러링을 해제할 수 있어요."
                 : "모니터를 끌어서 실제 책상 위의 위치에 맞게 놓으세요. 위쪽에 막대가 표시된 모니터가 주 모니터입니다.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ArrangementCanvas().frame(height: 250)
            if let display = controller.selected { selectedControls(display) }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1)))
        .disabled(!controller.isIdle)
    }

    private func selectedControls(_ display: ConnectedDisplay) -> some View {
        let sources = controller.displays.filter { $0.id != display.id && $0.mirrorOf == nil }
        return VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display").foregroundStyle(.mint)
                Text(display.name).fontWeight(.medium).lineLimit(1)
                if display.isMain {
                    Text("주 모니터").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.mint.opacity(0.15), in: Capsule())
                }
                Spacer()
                Button("주 모니터로 설정") { controller.setMain(display) }
                    .disabled(display.isMain || display.mirrorOf != nil)
                    .help(display.mirrorOf != nil ? "미러링된 모니터는 주 모니터가 될 수 없습니다." : "메뉴 막대와 Dock을 이 모니터로 옮깁니다.")
            }
            Picker("이 모니터에 표시할 화면", selection: Binding(
                get: { display.mirrorOf },
                set: { id in controller.mirror(display, of: controller.display(id)) })) {
                Text("독립 화면 (확장)").tag(CGDirectDisplayID?.none)
                ForEach(sources) { source in
                    Text("\(source.name) 미러링").tag(Optional(source.id))
                }
            }
            .disabled(sources.isEmpty)
            if !controller.mirrors(of: display).isEmpty {
                Text("이 화면을 미러링하는 모니터: \(controller.mirrors(of: display).map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
