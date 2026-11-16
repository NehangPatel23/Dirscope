import SwiftUI

struct QuickLookPageView: View {
    var body: some View {
        SettingsPage(
            title: "Quick Look",
            systemImage: "eye",
            subtitle: "What you can do once the preview is open."
        ) {
            SettingsGroup {
                SettingsBlock(
                    title: "Open from Finder",
                    message: "Select a folder or archive, then press Space or ⌘Y.",
                    systemImage: "keyboard"
                )
                SettingsBlock(
                    title: "List and Icons",
                    message: "Switch views with the control at the bottom left. The slider in the middle scales rows and icons.",
                    systemImage: "rectangle.split.2x1",
                    showsDivider: true
                )
                SettingsBlock(
                    title: "Columns",
                    message: "Click a column heading to sort. Right-click a heading to show or hide fields such as size, type, and dates.",
                    systemImage: "tablecells",
                    showsDivider: true
                )
                SettingsBlock(
                    title: "Nested folders",
                    message: "Use the chevron beside a folder or archive to expand it in the list. Arrow keys move the selection.",
                    systemImage: "chevron.right",
                    showsDivider: true
                )
                SettingsBlock(
                    title: "Open a file",
                    message: "Double-click a file to launch it in its default application.",
                    systemImage: "arrow.up.forward.square",
                    showsDivider: true
                )
            }
        }
    }
}
