import AppKit
import RingCore
import SwiftUI

/// The settings window: the native sidebar on the left, one page on the right. The ring page is
/// the page that already exists, embedded as it is; the other four are placeholders until their
/// own work lands. Nothing here remembers a page: every new window starts on the ring.
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    /// Optional because a list can clear its selection; the page then falls back to the ring
    /// rather than showing an empty detail.
    @State private var selection: SettingsSection?
    /// Read from the running bundle by the app, so the sidebar never claims a version the build
    /// does not have. A probe passes it in.
    private let version: String?

    init(model: SettingsModel,
         initialSelection: SettingsSection = .ring,
         version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) {
        self.model = model
        _selection = State(initialValue: initialSelection)
        self.version = version
    }

    private var page: SettingsSection { selection ?? .ring }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A native sidebar: the system sidebar list with its own selection style, a fixed width of
    /// its own (never collapsible, so a page switch and a narrow window cannot take it away), and
    /// the running bundle's version at the bottom.
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .frame(minHeight: 34)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(maxHeight: .infinity)
            if let version {
                Text("Ring \(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: SettingsWindowGeometry.sidebarWidth)
    }

    /// One exhaustive switch: a new page cannot be forgotten and a page cannot be shown under
    /// the wrong name.
    @ViewBuilder
    private var detail: some View {
        switch page {
        case .ring:
            SettingsView(model: model)
        case .triggers:
            TriggersSettingsPage()
        case .permissions:
            PermissionsSettingsPage()
        case .general:
            GeneralSettingsPage()
        case .about:
            AboutSettingsPage()
        }
    }
}

/// The one shape the four placeholder pages share: the words "待开发" and nothing else — no
/// buttons, no made-up descriptions, no version, no permission or gesture controls.
private struct SettingsPlaceholderPage: View {
    var body: some View {
        Text("待开发")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TriggersSettingsPage: View {
    var body: some View { SettingsPlaceholderPage() }
}

struct PermissionsSettingsPage: View {
    var body: some View { SettingsPlaceholderPage() }
}

struct GeneralSettingsPage: View {
    var body: some View { SettingsPlaceholderPage() }
}

struct AboutSettingsPage: View {
    var body: some View { SettingsPlaceholderPage() }
}
