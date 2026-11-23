//
//  SteamLibraryModel.swift
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

import Combine
import Foundation
import WhiskyKit

private enum PendingKind { case install, uninstall }

private struct PendingJob {
    let kind: PendingKind
    let bottleURL: URL
    let started: Date
}

/// The Steam Library page: every game the account owns, and the installs and
/// uninstalls it asks Steam to do.
@MainActor
final class SteamLibraryModel: ObservableObject {
    enum Connection: Equatable {
        case unknown
        case needsAccount
        case loading
        case connected
        case failed(String)
    }

    @Published private(set) var rows: [SteamLibraryRow] = []
    @Published private(set) var connection: Connection = .unknown
    @Published var errorMessage: String?
    /// What an install that is still setting up is doing, by App ID.
    @Published fileprivate(set) var preparing: [Int: String] = [:]
    @Published private(set) var setupStatus: String?
    private var settingUp = false

    private var owned: [SteamOwnedGame] = []
    /// Installs and uninstalls Steam is working on, polled until they settle.
    private var pending: [Int: PendingJob] = [:]
    private var pollTask: Task<Void, Never>?
    private var orchestrators: [URL: SteamClientOrchestrator] = [:]

    static let firstSeenKey = "steamLibraryFirstSeen"
    static let bottleName = "Steam"

    var bottles: [Bottle] { BottleVM.shared.bottles.filter(\.isAvailable) }

    // MARK: - Loading

    /// Reads the library from the Steam client signed in inside a bottle.
    /// No key or separate sign-in: the client already knows what you own.
    func reload() async {
        let urls = bottles.map(\.url)
        let signedIn = await Task.detached {
            urls.contains { SteamClientLibrary.isSignedIn(bottleURL: $0) }
        }.value
        guard signedIn else {
            connection = settingUp ? .loading : .needsAccount
            return
        }
        if owned.isEmpty { connection = .loading }
        let snapshot = await Task.detached { SteamClientLibrary.snapshot(bottleURLs: urls) }.value
        let ids = snapshot.appIDs, names = snapshot.installedNames
        let info = await SteamAppCatalog.shared.info(for: ids)
        owned = ids.compactMap { id in
            let known = info[id]
            // DLC, tools and soundtracks share the cache with games; only
            // games belong here, plus anything actually installed.
            if names[id] == nil, let known, known.type != "game" { return nil }
            guard let name = names[id] ?? known.map(\.name) ?? Optional("App \(id)"), !name.isEmpty else {
                return nil
            }
            return SteamOwnedGame(appId: id, name: name, playtimeMinutes: 0, lastPlayed: snapshot.lastPlayed[id])
        }
        connection = .connected
        recordFirstSeen(owned)
        await rebuild()
        await cacheArtwork()
    }

    /// First run: makes a Steam bottle, installs Steam, and opens it so the
    /// person can sign in. The page fills in once they have.
    func setUpSteam() {
        guard !settingUp else { return }
        settingUp = true
        connection = .loading
        Task {
            defer { settingUp = false }
            do {
                let bottle = try await provisionBottle { [weak self] in self?.setupStatus = $0 }
                setupStatus = "Sign in to Steam to see your games…"
                if let root = SteamLibrary.detectInstall(bottleURL: bottle.url) {
                    try await Wine.prepareBottlePrefix(bottle: bottle)
                    try await Wine.runProgram(at: root.appending(path: "steam.exe"), bottle: bottle)
                }
                // Steam writes its library cache as the sign-in finishes.
                for _ in 0 ..< 120 {
                    try? await Task.sleep(for: .seconds(5))
                    if SteamClientLibrary.isSignedIn(bottleURL: bottle.url),
                       !SteamClientLibrary.ownedAppIDs(bottleURLs: [bottle.url]).isEmpty { break }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            setupStatus = nil
            await reload()
        }
    }

    /// Re-reads every bottle's manifests and rebuilds the rows. Cheap enough
    /// to run on each poll: a manifest is a few hundred bytes of text.
    func rebuild() async {
        let urls = bottles.map(\.url)
        let manifestsByBottle = await Task.detached {
            Dictionary(uniqueKeysWithValues: urls.map { ($0, SteamInstallService.manifests(bottleURL: $0)) })
        }.value
        let firstSeen = UserDefaults.standard.dictionary(forKey: Self.firstSeenKey) as? [String: Double] ?? [:]
        let routes = GameRouting().routes()

        rows = owned.map { game in
            // The bottle that has it wins; otherwise where it was last played.
            let holder = urls.first { manifestsByBottle[$0]?[game.appId] != nil }
            let bottleURL = holder ?? routes[game.appId]
            let status = holder.map {
                SteamInstallService.status(appId: game.appId, manifests: manifestsByBottle[$0] ?? [:])
            } ?? .notInstalled
            let install = installState(for: game.appId, status: status)
            let manifest = holder.flatMap { manifestsByBottle[$0]?[game.appId] }
            let lastPlayed = [game.lastPlayed, manifest?.lastPlayed].compactMap { $0 }.max()
            return SteamLibraryRow(
                game: game,
                entry: entry(for: game, bottleURL: bottleURL),
                install: install,
                bottleURL: bottleURL,
                sizeOnDisk: status.isInstalled ? manifest?.sizeOnDisk : nil,
                lastPlayed: lastPlayed,
                firstSeen: Date(timeIntervalSince1970: firstSeen[String(game.appId)] ?? 0),
                hasMods: ModPreset.builtIn.contains { $0.steamAppId == game.appId }
            )
        }
        settlePending()
    }

    private func installState(for appId: Int, status: SteamInstallStatus) -> LibraryInstallState {
        if pending[appId]?.kind == .uninstall, status != .notInstalled { return .uninstalling }
        switch status {
        case .installed: return .installed
        case let .installing(fraction): return .installing(fraction)
        case .notInstalled:
            return pending[appId]?.kind == .install || preparing[appId] != nil ? .installing(nil) : .notInstalled
        }
    }

    /// The card's entry. Installed games use the art Steam cached in the
    /// bottle; the rest use the store art saved by ``cacheArtwork()``.
    private func entry(for game: SteamOwnedGame, bottleURL: URL?) -> LibraryEntry {
        // Any bottle's Steam may have cached the game's art, installed or not.
        let roots = ([bottleURL].compactMap { $0 } + bottles.map(\.url)).compactMap {
            SteamLibrary.detectInstall(bottleURL: $0)
        }
        let localArt = roots.lazy.compactMap { SteamLibrarySource.artworkURL(appID: game.appId, steamRoot: $0) }.first
        let cached = Self.artworkCacheURL(appId: game.appId)
        let hasCached = FileManager.default.fileExists(atPath: cached.path(percentEncoded: false))
        let art = localArt ?? (hasCached ? cached : nil)
        return LibraryEntry(
            id: "steam-owned:\(game.appId)",
            name: game.name,
            iconURL: nil,
            artworkURL: art,
            bottleURL: bottleURL ?? BottleData.defaultBottleDir,
            source: .steam,
            launch: .steam(appID: game.appId)
        )
    }

}

extension SteamLibraryModel {
    // MARK: - Filtering and sorting

    func visibleRows(filter: SteamLibraryFilter, sort: SteamLibrarySort, search: String) -> [SteamLibraryRow] {
        rows.filter { filter.includes($0.install) }
            .filter { search.isEmpty || $0.game.name.localizedCaseInsensitiveContains(search) }
            .sorted { Self.ordered($0, $1, by: sort) }
    }

    static func ordered(_ lhs: SteamLibraryRow, _ rhs: SteamLibraryRow, by sort: SteamLibrarySort) -> Bool {
        let byName = lhs.game.name.localizedStandardCompare(rhs.game.name) == .orderedAscending
        switch sort {
        case .name:
            return byName
        case .recentlyPlayed:
            return descending(lhs.lastPlayed, rhs.lastPlayed) ?? byName
        case .recentlyAdded:
            return lhs.firstSeen == rhs.firstSeen ? byName : lhs.firstSeen > rhs.firstSeen
        case .size:
            return descending(lhs.sizeOnDisk, rhs.sizeOnDisk) ?? byName
        }
    }

    /// Larger first, missing values last; nil when the two tie.
    private static func descending<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Bool? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): lhs == rhs ? nil : lhs > rhs
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): nil
        }
    }

    // MARK: - Install

    func install(_ row: SteamLibraryRow) {
        let appId = row.game.appId
        guard preparing[appId] == nil, pending[appId] == nil else { return }
        preparing[appId] = "Preparing…"
        Task { await rebuild() }
        Task {
            defer { preparing[appId] = nil }
            do {
                let bottle = try await provisionBottle(preferring: row.bottleURL) { [weak self] in
                    self?.preparing[appId] = $0
                }
                preparing[appId] = "Starting Steam…"
                try await SteamInstallService.requestInstall(appId: appId, name: row.game.name, bottle: bottle)
                pending[appId] = PendingJob(kind: .install, bottleURL: bottle.url, started: Date())
                startPolling()
            } catch {
                errorMessage = error.localizedDescription
            }
            await rebuild()
        }
    }

    /// The bottle to install into: the one the game was last played from, a
    /// bottle that already has Steam, or a new Steam bottle.
    func provisionBottle(
        preferring preferred: URL? = nil, status: @escaping (String) -> Void
    ) async throws -> Bottle {
        let withSteam = bottles.filter { SteamLibrary.detectInstall(bottleURL: $0.url) != nil }
        if let url = preferred, let routed = withSteam.first(where: { $0.url == url }) {
            return routed
        }
        if let named = withSteam.first(where: { $0.settings.name == Self.bottleName }) ?? withSteam.first {
            return named
        }
        let bottle: Bottle
        if let empty = bottles.first(where: { $0.settings.name == Self.bottleName }) {
            bottle = empty
        } else {
            status("Creating bottle…")
            guard let made = await BottleVM.shared.createBottleAndWait(named: Self.bottleName) else {
                throw SteamLaunchError.steamNotInstalled
            }
            bottle = made
        }
        status("Installing Steam…")
        try await SteamClientInstaller.install(into: bottle)
        return bottle
    }

    /// Steam's own install dialog, for when the queued install doesn't start.
    func openInSteam(_ row: SteamLibraryRow) {
        guard let bottle = bottle(for: row) else { return }
        Task {
            do {
                try await SteamInstallService.openSteamURL("install", appId: row.game.appId, bottle: bottle)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Uninstall

    func uninstall(_ row: SteamLibraryRow) {
        guard let bottle = bottle(for: row) else { return }
        let appId = row.game.appId
        pending[appId] = PendingJob(kind: .uninstall, bottleURL: bottle.url, started: Date())
        Task {
            do {
                try await SteamInstallService.uninstallInBackground(appId: appId, bottle: bottle)
                startPolling()
            } catch {
                pending[appId] = nil
                errorMessage = error.localizedDescription
            }
            await rebuild()
        }
    }

    // MARK: - Play

    func play(_ row: SteamLibraryRow) {
        guard let bottle = bottle(for: row),
              let game = SteamLibrary.enumerate(bottleURL: bottle.url).first(where: { $0.appId == row.game.appId })
        else {
            errorMessage = String(localized: "library.launch.steamGameMissing")
            return
        }
        let orchestrator = orchestrators[bottle.url] ?? SteamClientOrchestrator(bottle: bottle)
        orchestrators[bottle.url] = orchestrator
        orchestrator.launch(game)
    }

    private func bottle(for row: SteamLibraryRow) -> Bottle? {
        bottles.first { $0.url == row.bottleURL }
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                await rebuild()
                if pending.isEmpty {
                    pollTask = nil
                    return
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Drops jobs Steam has finished, or that have gone quiet for too long:
    /// an uninstall the user cancelled in Steam's dialog never removes the
    /// manifest.
    private func settlePending() {
        for (appId, job) in pending {
            guard let row = rows.first(where: { $0.game.appId == appId }) else { continue }
            let done = switch job.kind {
            case .install: row.install == .installed
            case .uninstall: row.install == .notInstalled
            }
            let timeout: TimeInterval = job.kind == .install ? 6 * 3600 : 300
            if done || Date().timeIntervalSince(job.started) > timeout {
                pending[appId] = nil
            }
        }
    }

    // MARK: - Bookkeeping

    /// Steam does not say when a game was added to the account, so this is
    /// when BetterWhisky first saw it.
    private func recordFirstSeen(_ games: [SteamOwnedGame]) {
        var seen = UserDefaults.standard.dictionary(forKey: Self.firstSeenKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        var changed = false
        for game in games where seen[String(game.appId)] == nil {
            seen[String(game.appId)] = now
            changed = true
        }
        if changed { UserDefaults.standard.set(seen, forKey: Self.firstSeenKey) }
    }

    nonisolated static func artworkCacheURL(appId: Int) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: "BetterWhisky/SteamArtwork/\(appId).jpg")
    }

    /// Saves store art for games whose art isn't in a bottle, a few at a time.
    private func cacheArtwork() async {
        let missing = rows.filter { $0.entry.artworkURL == nil }.map(\.game)
        guard !missing.isEmpty else { return }
        let folder = Self.artworkCacheURL(appId: 0).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await withTaskGroup(of: Void.self) { group in
            for (index, game) in missing.enumerated() {
                if index >= 6 { await group.next() }
                if index > 0, index.isMultiple(of: 24) { await rebuild() }
                group.addTask {
                    await SteamAppCatalog.downloadHeader(appId: game.appId, to: Self.artworkCacheURL(appId: game.appId))
                }
            }
        }
        await rebuild()
    }
}
