import SwiftUI

enum SettingsChrome {
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let canvas = Color(nsColor: .textBackgroundColor)
}

struct SettingsPage<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    if let systemImage {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            AppBranding.accent.opacity(0.22),
                                            AppBranding.accent.opacity(0.08)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(AppBranding.accent.opacity(0.2), lineWidth: 1)
                            Image(systemName: systemImage)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(AppBranding.accent)
                        }
                        .frame(width: 44, height: 44)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.primary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.bottom, 22)

                content
            }
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 36)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SettingsChrome.canvas)
    }
}

struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 10, y: 3)
    }
}

struct SettingsControlRow<Control: View>: View {
    let title: String
    let subtitle: String
    var showsDivider = false
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider {
                Divider()
                    .padding(.leading, 16)
            }
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                control
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}

struct SettingsStatusPill: View {
    let title: String
    let isHealthy: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isHealthy ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill((isHealthy ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)).opacity(0.14))
            )
    }
}

struct SettingsBlock: View {
    let title: String
    let message: String
    var systemImage: String? = nil
    var showsDivider = false

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider {
                Divider()
                    .padding(.leading, systemImage == nil ? 16 : 54)
            }
            HStack(alignment: .top, spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppBranding.accent)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(AppBranding.accent.opacity(0.12))
                        )
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}

struct SettingsActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(AppBranding.accent)
        .controlSize(.large)
    }
}

struct SettingsSectionLabel: View {
    let title: String
    var topPadding: CGFloat = 20

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.4)
            .padding(.top, topPadding)
            .padding(.bottom, 8)
            .padding(.leading, 4)
    }
}
