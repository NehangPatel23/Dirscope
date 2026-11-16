import SwiftUI

struct ExtensionPageView: View {
    var body: some View {
        SettingsPage(
            title: "Extension",
            systemImage: "puzzlepiece.extension",
            subtitle: "Turn Dirscope on so Finder can use it."
        ) {
            SettingsGroup {
                SettingsBlock(
                    title: "Go to System Settings",
                    message: "Open General → Login Items & Extensions, then choose Quick Look.",
                    systemImage: "1.circle"
                )
                SettingsBlock(
                    title: "Activate Dirscope",
                    message: "Switch on \(AppBranding.extensionDisplayName) so Finder can use it.",
                    systemImage: "2.circle",
                    showsDivider: true
                )
                SettingsBlock(
                    title: "Adjust Appearance and Behaviors",
                    message: "Set the default layout, text size, and folder listing rules. They apply the next time Quick Look opens.",
                    systemImage: "3.circle",
                    showsDivider: true
                )
            }

            SettingsActionButton(title: "Open System Settings") {
                ExtensionSettings.openQuickLookExtensions()
            }
            .padding(.top, 18)

            SettingsSectionLabel(title: "After enabling")

            SettingsGroup {
                SettingsBlock(
                    title: "If the old preview is still showing",
                    message: "Close the Quick Look panel and try again. macOS may need a moment to register the new extension.",
                    systemImage: "arrow.clockwise"
                )
                SettingsBlock(
                    title: "Archives and the background helper",
                    message: "Opening a file from inside an archive uses a lightweight Launch Agent installed with the app. Behaviors shows whether that helper is running.",
                    systemImage: "gearshape",
                    showsDivider: true
                )
            }
        }
    }
}
