//
//  SteamLibraryView.swift
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

import SwiftUI
import WhiskyKit

/// Every game the connected Steam account owns, installed or not.
///
/// The home Library is what you play; this is what you could. Installing is
/// asked of Steam, which does the download, so a card here is a front door to
/// Steam rather than a downloader of its own.
struct SteamLibraryView: View {
    @EnvironmentObject var bottleVM: BottleVM
    @StateObject private var model = SteamLibraryModel()

    @AppStorage("steamLibraryFilter") private var filter: SteamLibraryFilter = .all
    @AppStorage("steamLibrarySort") private var sort: SteamLibrarySort = .recentlyPlayed
    @State private var search = ""
    @State private var uninstallTarget: SteamLibraryRow?

    private var visible: [SteamLibraryRow] {
        model.visibleRows(filter: filter, sort: sort, search: search)
    }

    var body: some View {
        Group {
            switch model.connection {
            case .unknown, .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    if let status = model.setupStatus {
                        Text(status).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsAccount:
                connectPrompt(nil)
            case let .failed(message) where model.rows.isEmpty:
                connectPrompt(message)
            default:
                VStack(spacing: 0) {
                    controls
                    if visible.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        grid
                    }
                }
            }
        }
        .task(id: bottleVM.bottles.map(\.url)) { await model.reload() }
        .onDisappear { model.stopPolling() }
        .confirmationDialog(
            "Uninstall \(uninstallTarget?.game.name ?? "")?",
            isPresented: Binding(get: { uninstallTarget != nil }, set: { if !$0 { uninstallTarget = nil } }),
            presenting: uninstallTarget
        ) { row in
            Button("Uninstall", role: .destructive) { model.uninstall(row) }
        } message: { _ in
            Text("Steam closes for a moment while the game's files are removed. Your saves stay in your account.")
        }
        .alert(
            "Steam Library",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("button.ok") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Controls

    /// Filter and sort are separate on purpose: one decides what is shown,
    /// the other only the order.
    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $filter) {
                ForEach(SteamLibraryFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(SteamLibrarySort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(sort.label, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button("Refresh") { Task { await model.reload() } }
                Button("Open Steam") { model.setUpSteam() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 320), spacing: 14)], spacing: 14) {
                ForEach(visible) { row in
                    LibraryCard(
                        item: row.entry,
                        bottleName: nil,
                        lastPlayed: row.lastPlayed,
                        state: .idle,
                        launch: { primaryAction(row) },
                        install: row.install,
                        detail: detail(for: row)
                    )
                    .contextMenu { menu(for: row) }
                }
            }
            .padding(18)
        }
    }

    private func primaryAction(_ row: SteamLibraryRow) {
        switch row.install {
        case .installed: model.play(row)
        case .notInstalled: model.install(row)
        case .installing, .uninstalling: break
        }
    }

    @ViewBuilder
    private func menu(for row: SteamLibraryRow) -> some View {
        switch row.install {
        case .installed:
            Button("Play") { model.play(row) }
            Divider()
            Button("Uninstall…", role: .destructive) { uninstallTarget = row }
        case .notInstalled:
            Button("Install") { model.install(row) }
        case .installing:
            Button("Show in Steam") { model.openInSteam(row) }
        case .uninstalling:
            EmptyView()
        }
    }

    private func detail(for row: SteamLibraryRow) -> String {
        var parts: [String] = []
        switch row.install {
        case .installed:
            parts.append("Installed")
            if let size = row.sizeOnDisk, size > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
        case .notInstalled:
            parts.append("Not Installed")
        case let .installing(fraction):
            parts.append(model.preparing[row.game.appId]
                ?? fraction.map { "Downloading \($0.formatted(.percent.precision(.fractionLength(0))))" }
                ?? "Waiting for Steam…")
        case .uninstalling:
            parts.append("Uninstalling…")
        }
        if row.hasMods { parts.append("Mods") }
        if let lastPlayed = row.lastPlayed, row.install == .installed || row.install == .notInstalled {
            parts.append(lastPlayed.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Connecting

    private func connectPrompt(_ failure: String?) -> some View {
        ContentUnavailableView {
            Label("Sign In to Steam", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text(failure ?? "BetterWhisky shows the games in your Steam library once you've signed in to Steam. "
                + "It sets Steam up for you if needed.")
        } actions: {
            Button("Set Up Steam") { model.setUpSteam() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Filtering, sorting, rows

enum SteamLibraryFilter: String, CaseIterable, Identifiable {
    case all
    case installed
    case notInstalled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .installed: "Installed"
        case .notInstalled: "Not Installed"
        }
    }

    func includes(_ state: LibraryInstallState) -> Bool {
        switch self {
        case .all: true
        case .installed: state != .notInstalled
        case .notInstalled: state == .notInstalled
        }
    }
}

enum SteamLibrarySort: String, CaseIterable, Identifiable {
    case recentlyPlayed
    case name
    case recentlyAdded
    case size

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentlyPlayed: "Recently Played"
        case .name: "Name"
        case .recentlyAdded: "Recently Added"
        case .size: "Size"
        }
    }
}

/// One owned game and where it is in this Mac's bottles.
struct SteamLibraryRow: Identifiable, Equatable {
    let game: SteamOwnedGame
    let entry: LibraryEntry
    let install: LibraryInstallState
    /// The bottle it is installed in, or will be installed into.
    let bottleURL: URL?
    let sizeOnDisk: Int64?
    let lastPlayed: Date?
    let firstSeen: Date
    let hasMods: Bool

    var id: Int { game.appId }
}

// MARK: - Install indicator

/// Whether an entry's game is on disk. Only the Steam Library page shows
/// anything but `.installed`; every other card is something already there.
enum LibraryInstallState: Equatable {
    case installed
    case notInstalled
    /// Steam is fetching it. Nil until Steam knows the size.
    case installing(Double?)
    case uninstalling

    var isInstalled: Bool { self == .installed }

    /// A game that isn't installed keeps its art, a step back: dimmed and a
    /// little quieter in colour, brought forward again on hover or focus.
    func artOpacity(active: Bool) -> Double {
        isInstalled ? 1 : (active ? 0.92 : 0.55)
    }

    func artSaturation(active: Bool) -> Double {
        isInstalled ? 1 : (active ? 0.95 : 0.85)
    }
}

/// The corner of a card whose game is not installed, or is on its way.
struct LibraryInstallIndicator: View {
    let install: LibraryInstallState
    let isActive: Bool

    var body: some View {
        switch install {
        case .notInstalled:
            badge
        case let .installing(fraction):
            Group {
                if let fraction {
                    ProgressView(value: fraction).progressViewStyle(.circular)
                } else {
                    ProgressView()
                }
            }
            .controlSize(.small)
            .frame(width: 30, height: 30)
            .cardGlass(.circle)
            .help(fraction.map { "Downloading \($0.formatted(.percent.precision(.fractionLength(0))))" }
                ?? "Preparing download")
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        case .uninstalling:
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
                .cardGlass(.circle)
                .help("Uninstalling")
        case .installed:
            EmptyView()
        }
    }

    /// Small and always there, so the grid reads at a glance; it names the
    /// action only once the pointer or focus is on the card.
    private var badge: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .semibold))
            if isActive {
                Text("Install")
                    .font(.caption.weight(.medium))
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(height: 30)
        .padding(.horizontal, isActive ? 11 : 0)
        .frame(minWidth: 30)
        .cardGlass(.capsule, interactive: true)
        .opacity(isActive ? 1 : 0.85)
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }
}

// MARK: - Bottle creation for the Steam Library

extension BottleVM {
    /// Creates a bottle and waits for it, for flows that need the bottle next
    /// (the Steam Library making a bottle to install into). Nil if creation
    /// failed; the failure has already been surfaced the usual way.
    func createBottleAndWait(named name: String, winVersion: WinVersion = .win10) async -> Bottle? {
        let location = UserDefaults.standard.url(forKey: "defaultBottleLocation") ?? BottleData.defaultBottleDir
        let request = BottleCreationRequest(
            bottleName: name, winVersion: winVersion, bottleURL: location,
            newBottleDir: location.appending(path: UUID().uuidString)
        )
        await createBottleTask(request: request)
        return bottles.first { $0.url == request.newBottleDir && $0.isAvailable }
    }
}
