import SwiftUI

struct AppSidebar: View {
    @Binding var selection: AppSection
    @State private var hovered: AppSection?

    private let primary: [AppSection] = [.dashboard, .appearance, .behaviors, .about]
    private let guide: [AppSection] = [.introduction, .quickLook, .extensionSetup]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            brand
                .padding(.bottom, 16)

            sectionLabel("App")
            ForEach(primary) { section in
                row(section)
            }

            sectionLabel("Guide")
                .padding(.top, 14)

            ForEach(guide) { section in
                row(section)
            }

            Spacer(minLength: 0)

            Text("Version 1.0")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(width: AppTheme.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsChrome.sidebar)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppBranding.appMarkImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(AppBranding.name)
                    .font(.system(size: 13, weight: .semibold))
                Text("Folder preview")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
    }

    private func row(_ section: AppSection) -> some View {
        let selected = selection == section
        let highlighted = selected || hovered == section

        return Button {
            selection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AppBranding.accent : .secondary)
                    .frame(width: 20, alignment: .center)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AppBranding.accent.opacity(0.14) : (highlighted ? Color.primary.opacity(0.05) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hovered = hovering ? section : (hovered == section ? nil : hovered)
        }
        .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}
