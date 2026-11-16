import SwiftUI

struct DashboardView: View {
    var body: some View {
        SettingsPage(
            title: "Dashboard",
            systemImage: "square.grid.2x2",
            subtitle: "See what’s inside a folder from Finder, without opening another window."
        ) {
            SettingsGroup {
                SettingsBlock(
                    title: "Browse in place",
                    message: "Select a folder in Finder and press Space or ⌘Y. Dirscope lists the contents in Quick Look.",
                    systemImage: "folder"
                )
                SettingsBlock(
                    title: "Open archives",
                    message: "Zip, tar, gz, xz, 7z, and rar preview like folders. Expand them in the list, then open a file in its real app.",
                    systemImage: "doc.zipper",
                    showsDivider: true
                )
                SettingsBlock(
                    title: "Inspect a file",
                    message: "Click a file to read source with syntax color, a Word, Excel, or PowerPoint document, or an image with its dimensions.",
                    systemImage: "doc.text.magnifyingglass",
                    showsDivider: true
                )
            }

            SettingsActionButton(title: "Open Quick Look settings") {
                ExtensionSettings.openQuickLookExtensions()
            }
            .padding(.top, 18)
        }
    }
}

#Preview {
    DashboardView()
        .frame(width: 820, height: 620)
}
