//
//  ContentView+Sidebar.swift
//  Whisky
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import AppKit
import SemanticVersion
import SwiftUI
import WhiskyKit

// MARK: - Tabs

/// The places in the window, picked from the bar at the top.
enum AppTab: String, CaseIterable, Identifiable {
    case library
    case steamLibrary
    case store
    case bottles
    case search

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .library: "library.title"
        case .steamLibrary: "Steam Library"
        case .store: "Store"
        case .bottles: "sidebar.bottles"
        case .search: "tab.search"
        }
    }
}

/// The three tabs, as the system's own segmented control. In the toolbar on
/// macOS 26 Apple draws it in Liquid Glass, with a thumb you can slide
/// between segments, so none of the glass here is hand-made.
struct TopTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        Picker("tab.picker", selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                Text(tab.title)
                    .tag(tab)
                    .accessibilityIdentifier("tab.\(tab.rawValue)")
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

// MARK: - Pages

/// A page that covers the window, such as a game's store page, sets this so
/// the window hides its tabs and buttons while it is open.
struct HidesTopBarKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension ContentView {
    @ViewBuilder
    var page: some View {
        if bottlesLoaded, bottleVM.countActive() == 0, tab != .steamLibrary, tab != .store {
            createFirstBottle
        } else {
            switch tab {
            case .library:
                LibraryView(selectedBottle: $selected, refresh: $triggerRefresh)
            case .steamLibrary:
                SteamLibraryView()
            case .store:
                StoreView()
            case .bottles:
                if let url = selected, let bottle = bottleVM.bottles.first(where: { $0.url == url }) {
                    BottleView(bottle: bottle, onClose: { selected = nil })
                        .disabled(bottle.inFlight)
                        .id(bottle.url)
                } else {
                    bottlesGrid
                }
            case .search:
                SearchPage(selectedBottle: $selected, refresh: $triggerRefresh)
            }
        }
    }

    private var createFirstBottle: some View {
        ContentUnavailableView {
            Label("main.createFirst", systemImage: "shippingbox")
        } actions: {
            // The one click: makes the bottle, installs Steam and opens it.
            Button("Set Up Steam", systemImage: "arrow.down.circle") {
                SteamLibraryModel.setupRequested = true
                tab = .steamLibrary
            }
            .buttonStyle(.borderedProminent)
            Button("button.createBottle", systemImage: "plus") {
                showBottleCreation.toggle()
            }
        }
    }

    /// Every bottle as a card. Opening one shows its pane with a Back button,
    /// so the grid stays the way back to the others.
    private var bottlesGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 16)], spacing: 16) {
                ForEach(sortedBottles) { bottle in
                    Group {
                        if bottle.inFlight || !bottle.isAvailable {
                            unavailableCard(bottle)
                        } else {
                            BottleListEntry(
                                bottle: bottle,
                                selected: $selected,
                                refresh: $triggerRefresh,
                                toast: $toast,
                                style: .card
                            )
                        }
                    }
                    .id(bottle.url)
                }
            }
            .padding(24)
        }
        .animation(.default, value: bottleVM.bottles)
        .accessibilityIdentifier("bottleSidebar")
    }

    private func unavailableCard(_ bottle: Bottle) -> some View {
        HStack(spacing: 12) {
            if bottle.inFlight {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(bottle.settings.name).lineLimit(1)
            Spacer()
            if !bottle.inFlight {
                Button {
                    // Only deregisters, which cannot fail.
                    Task { try? await bottle.remove(delete: false) }
                } label: {
                    Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("button.removeFromList.help")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(0.6)
    }

    var sortedBottles: [Bottle] {
        bottleVM.bottles.sorted()
    }
}

/// Search across the library, and the bottles that hold it.
struct SearchPage: View {
    @EnvironmentObject var bottleVM: BottleVM
    @Binding var selectedBottle: URL?
    @Binding var refresh: Bool
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            GlassSearchBar(text: $query)
                .frame(maxWidth: 560)
                .padding(.top, 20)
                .padding(.horizontal, 24)

            if !matchingBottles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("sidebar.bottles").font(.headline)
                    ForEach(matchingBottles) { bottle in
                        Button {
                            selectedBottle = bottle.url
                        } label: {
                            Label(bottle.settings.name, systemImage: "shippingbox")
                        }
                        .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }

            LibraryView(selectedBottle: $selectedBottle, refresh: $refresh, searchText: query)
        }

    }

    private var matchingBottles: [Bottle] {
        guard !query.isEmpty else { return [] }
        return bottleVM.bottles.filter { $0.isAvailable && $0.settings.name.localizedCaseInsensitiveContains(query) }
    }
}

// MARK: - Process Close Confirmation

extension ContentView {
    @MainActor
    func showProcessCloseAlert(for bottle: Bottle) {
        let checkbox = NSButton(
            checkboxWithTitle: String(localized: "bottle.close.remember"),
            target: nil,
            action: nil
        )
        let alert = NSAlert()
        alert.messageText = String(localized: "bottle.close.confirm.title")
        alert.informativeText = String(localized: "bottle.close.confirm.message")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "bottle.close.keepRunning"))
        let stopButton = alert.addButton(withTitle: String(localized: "bottle.close.stopBottle"))
        stopButton.hasDestructiveAction = true
        alert.accessoryView = checkbox

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Keep Running (default)
            if checkbox.state == .on {
                bottle.settings.closeWithProcessesPolicy = .alwaysKeepRunning
            }
        } else if response == .alertSecondButtonReturn {
            // Stop Bottle
            if checkbox.state == .on {
                bottle.settings.closeWithProcessesPolicy = .alwaysStop
            }
            Wine.killBottle(bottle: bottle)
            ProcessRegistry.shared.clearRegistry(for: bottle.url)
        }
    }
}

#Preview {
    ContentView(showSetup: .constant(false))
        .environmentObject(BottleVM.shared)
}

/// The Search page's field: a tall capsule of Apple's Liquid Glass with a
/// system text field inside. AppKit's search field caps its own height, so a
/// bar this size has to be a text field on the glass rather than that control.
struct GlassSearchBar: View {
    @Binding var text: String
    var prompt: LocalizedStringKey = "library.search"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .accessibilityIdentifier("search.field")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(Text("button.clear"))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .background { glass }
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var glass: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            Capsule().fill(.regularMaterial)
        }
    }
}
