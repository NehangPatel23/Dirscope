import SwiftUI

struct AppearancePageView: View {
    var body: some View {
        SettingsPage(
            title: "Appearance",
            systemImage: "sun.max",
            subtitle: "Layout and text for Quick Look previews."
        ) {
            AppearanceSettingsView()
        }
    }
}

struct BehaviorsPageView: View {
    var body: some View {
        SettingsPage(
            title: "Behaviors",
            systemImage: "slider.horizontal.3",
            subtitle: "What the preview lists, and how archives open."
        ) {
            BehaviorsSettingsView()
        }
    }
}
