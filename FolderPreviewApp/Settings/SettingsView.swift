import SwiftUI

/// macOS Settings window (⌘,) — same Appearance and Behaviors controls as the main window.
struct SettingsView: View {
    var body: some View {
        TabView {
            ScrollView {
                AppearanceSettingsView()
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(width: 560, alignment: .topLeading)
            }
            .tabItem {
                Label("Appearance", systemImage: "sun.max")
            }

            ScrollView {
                BehaviorsSettingsView()
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(width: 560, alignment: .topLeading)
            }
            .tabItem {
                Label("Behaviors", systemImage: "slider.horizontal.3")
            }
        }
        .frame(width: 560, height: 480)
    }
}

#Preview {
    SettingsView()
}
