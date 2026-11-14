import SwiftUI

/// Shows an available update, install progress, or the result of a manual check.
struct UpdateBanner: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        if updater.phase == .downloading || updater.phase == .installing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(updater.phase == .downloading ? "업데이트를 내려받는 중…" : "업데이트를 설치하고 다시 실행합니다…").font(.callout)
                Spacer()
            }.padding(14).background(Color.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        } else if let release = updater.available {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("새 버전 v\(release.version)을 설치할 수 있어요").font(.callout.weight(.semibold))
                    Text("현재 v\(updater.currentVersion) · 설치하면 앱이 잠시 종료된 뒤 다시 열립니다.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Link("변경 사항", destination: release.page).font(.callout)
                Button("지금 업데이트") { Task { await updater.install() } }.buttonStyle(.borderedProminent).tint(.mint)
            }.padding(14).background(Color.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        } else if let message = updater.message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(.mint)
                Text(message).font(.callout).textSelection(.enabled)
                Spacer()
                Button { updater.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("안내 닫기")
            }.padding(14).background(Color.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct UpdateSettingsView: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        Form {
            Section("업데이트") {
                Toggle("새 버전 자동 확인 (실행 시, 6시간마다)", isOn: $updater.autoCheck)
                Toggle("새 버전을 자동으로 설치", isOn: $updater.autoInstall).disabled(!updater.autoCheck)
                Text("자동 설치는 진행 중인 화면 설정 확인이 없을 때만 실행되고, 설치 후 앱이 다시 열립니다. 앱이 응용 프로그램 폴더처럼 쓰기 가능한 위치에 있어야 합니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("현재 버전 v\(updater.currentVersion)")
                    Spacer()
                    if updater.phase == .checking { ProgressView().controlSize(.small) }
                    Button("지금 확인") { Task { await updater.check(userInitiated: true) } }.disabled(updater.phase != .idle)
                }
                if let message = updater.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped).frame(width: 460)
    }
}
