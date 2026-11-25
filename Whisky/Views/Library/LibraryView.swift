//
//  LibraryView.swift
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
import SwiftUI
import WhiskyKit

/// Everything worth launching, across every bottle, most recently played first.
///
/// This is the home screen because it is the thing people open Whisky to do. A
/// bottle is a Wine prefix, which is an implementation detail of running a
/// Windows program on a Mac, and it only earns space on screen once there is
/// more than one of them.
///
/// Entries come from ``LibraryCatalogue``, so Steam games sit beside pinned
/// programs and a future launcher needs no change here.
struct LibraryView: View {
    @EnvironmentObject var bottleVM: BottleVM
    @Binding var selectedBottle: URL?
    /// Toggled by the toolbar's refresh button. Folded into the reload trigger
    /// because the bottle list is unchanged by a refresh, so watching only that
    /// left the button spinning without rebuilding anything.
    @Binding var refresh: Bool

    @AppStorage("librarySort") private var sort: LibrarySort = .recent

    @StateObject private var model = LibraryModel()

    /// Set by the Search tab; the Library tab itself shows everything.
    var searchText: String = ""

    @State private var modsProgram: Program?
    @State private var aboutAppID: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var bottles: [Bottle] { bottleVM.bottles.filter(\.isAvailable) }

    private var visible: [LibraryRow] {
        guard !searchText.isEmpty else { return model.rows }
        return model.rows.filter { $0.item.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// Every input that changes what the grid should contain. Pins live in
    /// bottle settings, so a program pinned in the bottle screen shows up here
    /// without a relaunch.
    private var reloadTrigger: String {
        let pins = bottles.flatMap { $0.settings.pins.map(\.name) }
        return (bottles.map(\.url.path) + pins + ["\(refresh)"]).joined(separator: "\u{1F}")
    }

    var body: some View {
        Group {
            if model.rows.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .sheet(item: $modsProgram, onDismiss: { refresh.toggle() }, content: { program in
            ModPickerSheet(program: program)
        })
        .overlay {
            if let appID = aboutAppID {
                GameDetailView(appId: appID) {
                    withAnimation(.smooth(duration: 0.35)) { aboutAppID = nil }
                }
                .id(appID)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .sheet(item: $model.launchRequest) { request in
            LaunchProgressView(request: request) { model.launchRequest = nil }
        }
        .toast($model.toast)
        .task {
            // Steam starts slowly under Wine; get it signed in before it's needed.
            // Not while a Steam setup is waiting to run: a second client for
            // the same account makes the new one hang on its first start.
            if !SteamLibraryModel.setupRequested, !SteamLibraryModel.setupRunning,
               !SteamLibraryModel.debugFreshSetupRequested {
                await SteamModLauncher.warmUp(bottles: bottles)
            }
            // Mods updated since their last start load faster once pre-compiled.
            await ModPrecompiler.runWhereNeeded(bottles: bottles)
        }
        .task(id: reloadTrigger) {
            await model.reload(bottles: bottles)
            // Mods move to their latest release on their own, at most every few hours.
            let updates = await ModAutoUpdater.runIfDue(bottles: bottles)
            if !updates.isEmpty {
                model.toast = ToastData(message: updates.joined(separator: " "), style: .success)
                await model.reload(bottles: bottles)
            }
        }
        .onChange(of: sort, initial: true) {
            model.sort = sort
        }
        .onDisappear {
            model.stopTracking()
        }
        .alert(
            "library.launch.failed",
            isPresented: Binding(
                get: { model.launchError != nil },
                set: { if !$0 { model.launchError = nil } }
            )
        ) {
            Button("button.ok") { model.launchError = nil }
        } message: {
            Text(model.launchError ?? "")
        }
    }

    /// The few games played most recently, biggest first, the way the TV app
    /// leads with Up Next. Hidden while searching, where it would repeat results.
    private var recentlyPlayed: [LibraryRow] {
        guard searchText.isEmpty else { return [] }
        return model.rows
            .filter { $0.lastPlayed != nil && !$0.item.isLauncher }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(8)
            .map { $0 }
    }

    private func card(_ row: LibraryRow) -> some View {
        LibraryCard(
            item: row.item,
            bottleName: row.bottleName,
            lastPlayed: row.lastPlayed,
            state: model.state(for: row.item),
            launch: { model.launch(row, bottles: bottles) },
            onSettings: settingsAction(for: row)
        )
        .contextMenu { menu(for: row) }
    }

    /// The game in the banner: the one played last.
    private var heroRow: LibraryRow? { recentlyPlayed.first }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if let hero = heroRow {
                    LibraryHero(
                        row: hero,
                        state: model.state(for: hero.item),
                        play: { model.launch(hero, bottles: bottles) },
                        stop: { model.stop(hero, bottles: bottles) },
                        mods: settingsAction(for: hero),
                        about: aboutAction(for: hero),
                        variants: variants(of: hero),
                        playVariant: { model.launch($0, bottles: bottles) }
                    )
                    .contextMenu { menu(for: hero) }
                    .id("hero-\(hero.id)")
                    .transition(.opacity)
                }

                if recentlyPlayed.count > 1 {
                    LibraryShelf(
                        title: "Recently Played", systemImage: "clock.arrow.circlepath",
                        rows: Array(recentlyPlayed.dropFirst())
                    ) { row in
                        card(row).frame(width: 280)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Label(searchText.isEmpty ? "All Games" : "Results", systemImage: "square.grid.2x2")
                            .font(.title2.weight(.semibold))
                        Text("\(visible.count)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .contentTransition(.numericText())
                    }
                    LazyVGrid(
                        // Small enough that two columns fit at the window's minimum
                        // width: one column of landscape cards is a list with
                        // wasted space.
                        columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 18)],
                        spacing: 18
                    ) {
                        ForEach(visible) { row in
                            card(row)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                }
            }
            .padding(24)
            // Sorting, searching and a launch moving a game to the front all
            // slide cards to their new places instead of jumping.
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: visible.map(\.id))
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: recentlyPlayed.map(\.id))
        }
        .accessibilityHidden(aboutAppID != nil)
    }

    private func aboutAction(for row: LibraryRow) -> (() -> Void)? {
        guard case let .steam(appID) = row.item.launch else { return nil }
        return { withAnimation(.smooth(duration: 0.4)) { aboutAppID = appID } }
    }

    /// Every way to play the same game: the plain game first, then each mod profile.
    private func variants(of row: LibraryRow) -> [LibraryRow] {
        guard let game = row.item.mod?.gameFolder else { return [] }
        let all = model.rows.filter { $0.item.mod?.gameFolder == game }
        guard all.count > 1 else { return [] }
        return all.sorted { lhs, rhs in
            let lhsPlain = lhs.item.mod?.modFolder == nil, rhsPlain = rhs.item.mod?.modFolder == nil
            if lhsPlain != rhsPlain { return lhsPlain }
            return lhs.item.name.localizedStandardCompare(rhs.item.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func menu(for row: LibraryRow) -> some View {
        Button("button.run") { model.launch(row, bottles: bottles) }
        let others = variants(of: row).filter { $0.id != row.id }
        if !others.isEmpty {
            Menu("Play With") {
                ForEach(others) { variant in
                    Button(LibraryHero.profileName(variant)) { model.launch(variant, bottles: bottles) }
                }
            }
        }
        if model.state(for: row.item) == .running {
            Button("library.card.stop") { model.stop(row, bottles: bottles) }
        }
        Divider()
        if case let .program(url) = row.item.launch {
            Button("button.showInFinder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("library.card.unpin", role: .destructive) { unpin(url, in: row.item.bottleURL) }
        }
        if case let .steam(appID) = row.item.launch {
            Button("About This Game") { withAnimation(.smooth(duration: 0.4)) { aboutAppID = appID } }
        }
        if case let .steam(appID) = row.item.launch, let program = gameProgram(appID, in: row.item.bottleURL) {
            Button("Mods…") { modsProgram = program }
        }
        // Per-program settings live inside the bottle's own navigation stack,
        // which the library cannot push onto, so this is as close as the menu
        // gets without a deep link into it.
        Button("library.card.configure") {
            selectedBottle = row.item.bottleURL
        }
    }

    private func settingsAction(for row: LibraryRow) -> (() -> Void)? {
        guard case let .steam(appID) = row.item.launch,
              !ModPreset.builtIn.filter({ $0.steamAppId == appID }).isEmpty else { return nil }
        return {
            if let program = gameProgram(appID, in: row.item.bottleURL) { modsProgram = program }
        }
    }

    /// The game Steam installed, as a program, for its mod settings.
    private func gameProgram(_ appID: Int, in bottleURL: URL) -> Program? {
        guard let bottle = bottles.first(where: { $0.url == bottleURL }),
              let game = SteamLibrary.enumerate(bottleURL: bottleURL).first(where: { $0.appId == appID }),
              !ModPreset.builtIn.filter({ $0.steamAppId == appID }).isEmpty,
              let exe = ModInstaller.mainExecutable(in: game.installURL) else { return nil }
        return bottle.programs.first { $0.url == exe } ?? Program(url: exe, bottle: bottle)
    }

    private func unpin(_ url: URL, in bottleURL: URL) {
        guard let bottle = bottles.first(where: { $0.url == bottleURL }) else { return }
        // Recorded here and not only by `pinned`'s setter: the library lists
        // pins straight from bottle settings, so the bottle may have no
        // `Program` for this one, and the Start Menu scan would pin it again.
        bottle.settings.unpin(url)
        if let program = bottle.programs.first(where: { $0.url == url }) {
            program.pinned = false
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("library.empty.title", systemImage: "square.grid.2x2")
        } description: {
            Text(bottles.isEmpty ? "library.empty.noBottle" : "library.empty.noPrograms")
        } actions: {
            if let first = bottles.first {
                Button("library.empty.pinHint") { selectedBottle = first.url }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
