import SwiftUI

struct ContentView: View {
    @State private var selection: AppSection = .dashboard

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(selection: $selection)

            Divider()

            Group {
                switch selection {
                case .dashboard:
                    DashboardView()
                case .introduction:
                    IntroductionView()
                case .quickLook:
                    QuickLookPageView()
                case .extensionSetup:
                    ExtensionPageView()
                case .appearance:
                    AppearancePageView()
                case .behaviors:
                    BehaviorsPageView()
                case .about:
                    AboutPageView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SettingsChrome.canvas)
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(SettingsChrome.sidebar)
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case introduction
    case quickLook
    case extensionSetup
    case appearance
    case behaviors
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .introduction: return "Introduction"
        case .quickLook: return "Quick Look"
        case .extensionSetup: return "Extension"
        case .appearance: return "Appearance"
        case .behaviors: return "Behaviors"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "speedometer"
        case .introduction: return "text.book.closed"
        case .quickLook: return "eye"
        case .extensionSetup: return "puzzlepiece.extension"
        case .appearance: return "sun.max"
        case .behaviors: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

#Preview {
    ContentView()
}
