import SwiftUI

struct AboutPageView: View {
    var body: some View {
        SettingsPage(
            title: "About",
            systemImage: "info.circle",
            subtitle: "A Quick Look folder viewer for macOS."
        ) {
            HStack(spacing: 16) {
                Image(nsImage: AppBranding.appMarkImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text(AppBranding.name)
                        .font(.system(size: 20, weight: .semibold))
                    Text(AppBranding.tagline)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Version 1.0")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 18)

            SettingsGroup {
                SettingsBlock(
                    title: "Directories",
                    message: "Sortable lists, icon grids, and an expandable folder tree.",
                    systemImage: "list.bullet"
                )
                SettingsBlock(
                    title: "Archives",
                    message: "Browse zip, tar, and other archives without extracting them first.",
                    systemImage: "doc.zipper",
                    showsDivider: true
                )
                SettingsBlock(
                    title: "File viewer",
                    message: "Syntax-colored source, Office text, and image details in the side panel.",
                    systemImage: "eye",
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
