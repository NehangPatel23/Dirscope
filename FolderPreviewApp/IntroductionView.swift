import SwiftUI

struct IntroductionView: View {
    var body: some View {
        SettingsPage(
            title: "Introduction",
            systemImage: "text.book.closed",
            subtitle: "How Dirscope fits into Finder."
        ) {
            SettingsGroup {
                SettingsBlock(
                    title: "Welcome",
                    message: "Press Space on any folder and see what’s inside — files, subfolders, and compressed archives — right in Quick Look.",
                    systemImage: "hand.wave"
                )
                SettingsBlock(
                    title: "Why it exists",
                    message: "Quick Look is handy for photos and documents, but folders usually stop at a plain icon. Dirscope lets you scan and preview them the moment you need to.",
                    systemImage: "magnifyingglass",
                    showsDivider: true
                )
                SettingsBlock(
                    title: "How to get started",
                    message: "Turn on the Dirscope extension once from the Extension page. Then highlight a folder in Finder and press Space or ⌘Y.",
                    systemImage: "play.circle",
                    showsDivider: true
                )
                SettingsBlock(
                    title: "Archives in Quick Look",
                    message: "Press Space on a .zip or .tar.gz file to browse it like a folder. Preview images, code, HTML, and Office documents without extracting first.",
                    systemImage: "doc.zipper",
                    showsDivider: true
                )
                SettingsBlock(
                    title: "Make it feel like home",
                    message: "Appearance and Behaviors choose list or icon view, text size, the path breadcrumb, and how folders expand.",
                    systemImage: "slider.horizontal.3",
                    showsDivider: true
                )
            }
        }
    }
}
