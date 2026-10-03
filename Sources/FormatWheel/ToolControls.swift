import AppKit
import SwiftUI

// Small building blocks shared by every editor window: chips, tabs, buttons, lists and the side panel.

func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

func clock(_ seconds: Double) -> String {
    let tenths = Int((max(0, seconds) * 10).rounded())
    return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
}

/// A pill button, filling its grid cell: accent fill when selected.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.85))
                .background(Capsule().fill(selected ? Theme.accent : Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ChipGrid<Content: View>: View {
    let columns: Int
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) { content }
    }
}

/// A quiet caption above a group of controls.
struct PanelSection<Content: View>: View {
    let caption: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(caption).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content
        }
    }
}

/// The one button look used in every panel, so colours never drift: a flat Claude-orange primary
/// button with white text, and a flat grey secondary one. (The system styles add their own
/// gradients and follow the user's accent colour.)
struct PanelButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, prominent: prominent)
    }

    struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent ? Theme.accent : Color.primary.opacity(configuration.isPressed ? 0.17 : 0.09)))
                .opacity(isEnabled ? (configuration.isPressed && prominent ? 0.8 : 1) : 0.4)
        }
    }
}

/// A small two-or-more way switch: quiet grey track, the chosen item in the theme colour.
struct Tabs: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Button { selection = index } label: {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == index ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selection == index ? Theme.accent : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

/// A compact push button that fills the panel's width.
struct WideButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(PanelButtonStyle())
    }
}

/// A rounded group of rows separated by hairlines, like a list in System Settings.
struct ListGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// One row of a ListGroup: a small accent icon and a 12 pt title, highlighted under the pointer.
struct ActionRow: View {
    let symbol: String
    let title: String
    var isLast = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.accent).frame(width: 18)
                Text(title).font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(hovering ? 0.07 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, 36) }
        }
    }
}

/// The fixed-width panel on the right: controls on top, buttons at the bottom.
struct SidePanel<Content: View, Footer: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Scrolls when the window is shorter than the options, so nothing is ever cut off.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(16)
        .padding(.top, 12)
        .frame(width: ToolWindows.panelWidth)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.05))
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 0.5) }
    }
}
