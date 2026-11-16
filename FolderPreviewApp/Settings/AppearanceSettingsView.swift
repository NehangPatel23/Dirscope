import SwiftUI

struct AppearanceSettingsView: View {
    @State private var viewMode = PreviewSettings.viewMode.rawValue
    @State private var textSize = PreviewSettings.textSize.rawValue
    @State private var showPathBar = PreviewSettings.showPathBar

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsControlRow(
                    title: "Default view",
                    subtitle: "Shown when opening a directory."
                ) {
                Picker("Default view", selection: $viewMode) {
                    Text("List").tag(PreviewViewMode.list.rawValue)
                    Text("Icons").tag(PreviewViewMode.icon.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)
                .onChange(of: viewMode) { PreviewSettings.viewMode = PreviewViewMode(rawValue: $0) ?? .list }
            }

                SettingsControlRow(
                    title: "Text size",
                    subtitle: "Default text size for lists and details.",
                    showsDivider: true
                ) {
                Picker("Text size", selection: $textSize) {
                    ForEach(PreviewTextSize.allCases) { size in
                        Text(size.compactTitle).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)
                .onChange(of: textSize) { PreviewSettings.textSize = PreviewTextSize(rawValue: $0) ?? .small }
            }

                SettingsControlRow(
                    title: "Path breadcrumb",
                    subtitle: "Show full path as breadcrumb in window title.",
                    showsDivider: true
                ) {
                Toggle("Path breadcrumb", isOn: $showPathBar)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: showPathBar) { PreviewSettings.showPathBar = $0 }
                }
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                Text("Right-click a column header in the preview to show or hide fields.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 14)
            .padding(.leading, 4)
        }
        .onReceive(NotificationCenter.default.publisher(for: .previewSettingsDidChange)) { _ in
            reloadFromStore()
        }
        .onAppear { reloadFromStore() }
    }

    private func reloadFromStore() {
        PreviewSettings.reloadFromDisk()
        viewMode = PreviewSettings.viewMode.rawValue
        textSize = PreviewSettings.textSize.rawValue
        showPathBar = PreviewSettings.showPathBar
    }
}

#Preview {
    SettingsPage(title: "Appearance") {
        AppearanceSettingsView()
    }
    .frame(width: 720, height: 420)
}
