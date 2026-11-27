//
//  ModAccountPrimer.swift
//  WhiskyKit
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

import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "ModAccountPrimer")

/// Where a mod keeps its own copy of the game's account save.
///
/// Town of Us keeps its saves beside the game's, with a suffix
/// (`player.amogus_TOUMira`). On its first run it can't answer Among Us's
/// age check itself, so its sign-in fails ("could not connect to Among Us
/// account") and it saves a signed-out account. Tested on 2026-11-23: it
/// connects once the plain game's save files and its own copies of them are
/// all present, and its copies can simply be the plain game's.
public struct ModAccountSave: Codable, Hashable, Sendable {
    /// The game's save folder, under the Windows user's `AppData/LocalLow`.
    public var folder: String
    /// The save files to copy. The first holds the account.
    public var files: [String]
    /// What the mod appends to each file name.
    public var suffix: String

    public init(folder: String, files: [String], suffix: String) {
        self.folder = folder
        self.files = files
        self.suffix = suffix
    }

    public static func amongUs(suffix: String) -> ModAccountSave {
        ModAccountSave(folder: "Innersloth/Among Us", files: ["player.amogus", "settings.amogus"], suffix: suffix)
    }
}

/// The one-time account setup before a mod's first launch, while it runs,
/// so the app can show a loading screen instead of seeming stuck.
@MainActor
public final class ModFirstLaunch: ObservableObject {
    public static let shared = ModFirstLaunch()
    /// The mod being set up, or nil when nothing is.
    @Published public private(set) var modName: String?
    /// When the setup began, for the progress estimate.
    @Published public private(set) var startedAt: Date?
    /// What the person should know or do right now.
    @Published public private(set) var detail = "Getting things ready for the first start. This only happens once."
    /// Whether the person has something to do (the game is waiting on them).
    @Published public private(set) var needsPerson = false

    func begin(_ name: String) {
        modName = name
        startedAt = Date()
    }

    func waitForPerson(_ text: String) {
        detail = text
        needsPerson = true
    }

    func end() {
        modName = nil
        startedAt = nil
        needsPerson = false
        detail = "Getting things ready for the first start. This only happens once."
    }
}

/// Gives a mod a signed-in account save before its launch.
///
/// When the plain game has signed in in the bottle, its save files are
/// copied to the mod's names: no game runs. Only when it never has, the
/// plain game is opened once so the person can confirm their age: its very
/// first sign-in waits for that (`CoWaitForDateConfirmation`), so it can't
/// be done hidden, and nothing here answers it for them. As soon as the
/// save says signed in, the plain game is closed and the mod's copy made.
public enum ModAccountPrimer {
    /// The game's save folder in the bottle's Windows user profile.
    static func saveFolder(_ save: ModAccountSave, bottleURL: URL) -> URL? {
        let users = bottleURL.appending(path: "drive_c/users")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: users.path(percentEncoded: false))) ?? []
        guard let user = names.sorted().first(where: { name in
            name != "Public" && FileManager.default.fileExists(
                atPath: users.appending(path: "\(name)/AppData").path(percentEncoded: false)
            )
        }) else { return nil }
        return users.appending(path: "\(user)/AppData/LocalLow").appending(path: save.folder)
    }

    /// Whether this account save says it is signed in (`"loginStatus": 1`).
    static func isSignedIn(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["account"] as? [String: Any] else { return false }
        return (account["loginStatus"] as? Int) == 1
    }

    /// Whether every plain save file is there and the account is signed in.
    static func plainSaveReady(_ save: ModAccountSave, in folder: URL) -> Bool {
        guard let account = save.files.first else { return false }
        return save.files.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false))
        } && isSignedIn(folder.appending(path: account))
    }

    /// Copies the plain save to the mod's names, unless the mod already has
    /// a signed-in save of its own. A signed-out account, left by a failed
    /// first run, is replaced; the mod's other files (its settings) are only
    /// filled in when missing, so the player's settings are never reset.
    static func seedModSave(_ save: ModAccountSave, in folder: URL) throws {
        guard let account = save.files.first else { return }
        guard !isSignedIn(folder.appending(path: account + save.suffix)) else { return }
        for file in save.files {
            let target = folder.appending(path: file + save.suffix)
            let exists = FileManager.default.fileExists(atPath: target.path(percentEncoded: false))
            if exists, file != account { continue }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: folder.appending(path: file), to: target)
        }
    }

    // MARK: Settings per profile

    static let settingsOwnerFile = ".betterwhisky-settings-owner"
    static let profileSettingsFolder = ".betterwhisky-settings"

    /// Gives each profile its own game settings. Profiles of one mod share
    /// one settings file in the game's save folder, so before a profile
    /// starts, the live settings go back to the profile that last played and
    /// this profile's own settings (if it has any yet) come in.
    /// The account file is never touched.
    public static func switchSettings(
        to profileGame: URL, bottleURL: URL, save: ModAccountSave = .amongUs(suffix: "")
    ) {
        guard let folder = saveFolder(save, bottleURL: bottleURL) else { return }
        let fileManager = FileManager.default
        let settingsNames = save.files.dropFirst()
        let live = ((try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
            .filter { name in settingsNames.contains { name.hasPrefix($0 + "_") } }
        let owner = folder.appending(path: settingsOwnerFile)
        let target = profileGame.deletingLastPathComponent().standardizedFileURL
        let previous = (try? String(contentsOf: owner, encoding: .utf8)).map { URL(fileURLWithPath: $0) }
        if previous?.standardizedFileURL.path == target.path { return }

        // Keep what the last profile played with.
        if let previous, fileManager.fileExists(atPath: previous.path(percentEncoded: false)) {
            let store = previous.appending(path: profileSettingsFolder)
            try? fileManager.createDirectory(at: store, withIntermediateDirectories: true)
            for name in live {
                try? fileManager.removeItem(at: store.appending(path: name))
                try? fileManager.copyItem(at: folder.appending(path: name), to: store.appending(path: name))
            }
        }
        // Bring in this profile's, when it has its own already.
        let store = target.appending(path: profileSettingsFolder)
        let kept = (try? fileManager.contentsOfDirectory(atPath: store.path(percentEncoded: false))) ?? []
        for name in kept where settingsNames.contains(where: { name.hasPrefix($0 + "_") }) {
            try? fileManager.removeItem(at: folder.appending(path: name))
            try? fileManager.copyItem(at: store.appending(path: name), to: folder.appending(path: name))
        }
        try? target.path.write(to: owner, atomically: true, encoding: .utf8)
    }

    /// Makes sure the mod named `modName` has a signed-in save before it
    /// starts, opening the plain game for its one-time sign-in if needed.
    /// Does nothing for mods that don't need one. Shows ``ModFirstLaunch``
    /// while it works.
    /// - Returns: Whether the mod's save is ready.
    @MainActor
    @discardableResult
    public static func prepare(
        appId: Int, gameFolder: URL, modName: String?, bottle: Bottle, timeout: Duration = .seconds(600)
    ) async -> Bool {
        seedDiscoveredSaves(bottleURL: bottle.url)
        guard let save = ModPreset.named(modName)?.accountSave else { return true }
        guard let folder = saveFolder(save, bottleURL: bottle.url) else { return false }
        if !plainSaveReady(save, in: folder) {
            ModFirstLaunch.shared.begin(modName ?? "the mod")
            defer { ModFirstLaunch.shared.end() }
            // Closed as soon as the save says signed in; Town of Us may
            // still ask for the birthday itself, which is fine.
            await signInPlain(appId: appId, gameFolder: gameFolder, bottle: bottle, timeout: timeout) {
                plainSaveReady(save, in: folder)
            }
        }
        guard plainSaveReady(save, in: folder) else {
            logger.info("The plain game has no signed-in save for \(appId)")
            return false
        }
        do {
            try seedModSave(save, in: folder)
            return true
        } catch {
            logger.error("Couldn't copy the account save: \(error.localizedDescription)")
            return false
        }
    }

    /// The suffixes mods have started their own saves under, found from the
    /// files themselves: `settings.amogus_SR` means a mod uses `_SR`. Mods
    /// don't say which they use, but each writes its settings copy on its
    /// first start, before the account screen it then hangs on.
    static func discoveredSuffixes(_ save: ModAccountSave, in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let suffixes = names.flatMap { name in
            save.files.compactMap { base -> String? in
                guard name.hasPrefix(base + "_"), name.count > base.count + 1 else { return nil }
                return String(name.dropFirst(base.count))
            }
        }
        return Array(Set(suffixes)).sorted()
    }

    /// Gives every mod that has started a save of its own (any suffix, not
    /// just the presets') a copy of the plain game's signed-in account, so it
    /// doesn't stop on the Privacy Policy screen as a new player. A mod that is
    /// signed in already keeps its save. Nothing happens until the plain game
    /// has signed in. Returns the suffixes it gave an account.
    @discardableResult
    public static func seedDiscoveredSaves(bottleURL: URL, save: ModAccountSave = .amongUs(suffix: "")) -> [String] {
        guard let folder = saveFolder(save, bottleURL: bottleURL), plainSaveReady(save, in: folder),
              let account = save.files.first else { return [] }
        return discoveredSuffixes(save, in: folder).filter { suffix in
            guard !isSignedIn(folder.appending(path: account + suffix)) else { return false }
            var modSave = save
            modSave.suffix = suffix
            do {
                try seedModSave(modSave, in: folder)
                logger.info("Gave the \(suffix, privacy: .public) mod save the game's account")
                return true
            } catch {
                logger.error("Couldn't copy the account save: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Whether the mod already has a signed-in save, or needs none.
    public static func isReady(modName: String?, bottleURL: URL) -> Bool {
        guard let save = ModPreset.named(modName)?.accountSave else { return true }
        guard let folder = saveFolder(save, bottleURL: bottleURL), let account = save.files.first else { return false }
        return isSignedIn(folder.appending(path: account + save.suffix))
    }

    /// Opens the plain game for its first sign-in and closes it once
    /// `isDone` (its save says signed in), or after `timeout`.
    @MainActor
    static func signInPlain(
        appId: Int, gameFolder: URL, bottle: Bottle, timeout: Duration,
        isDone: @escaping @Sendable () -> Bool
    ) async {
        guard let exe = ModInstaller.mainExecutable(in: gameFolder) else { return }
        // The sign-in goes through this bottle's Steam client.
        await SteamInstallService.startClientForSignIn(bottle: bottle)
        for _ in 0 ..< 45 where await !SteamLauncher.isClientRunning(
            bottle: bottle, hostSteamPIDs: SteamLauncher.hostSteamPIDs()
        ) {
            try? await Task.sleep(for: .seconds(2))
        }
        try? await Task.sleep(for: .seconds(10))
        logger.info("Opening the plain game once for its first sign-in (\(appId))")
        do {
            try await Wine.runProgram(
                at: exe, args: [], bottle: bottle,
                // Lets the Steam API start from a direct launch, through the
                // client that is already running.
                environment: ["SteamAppId": String(appId), "SteamGameId": String(appId)]
            )
        } catch {
            logger.error("Couldn't start the plain game: \(error.localizedDescription)")
            return
        }
        ModFirstLaunch.shared.waitForPerson(
            "Among Us is open to connect your account. Confirm your age there; "
                + "BetterWhisky closes it by itself as soon as you're signed in. This only happens once."
        )
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .seconds(2))
            if await Task.detached(operation: isDone).value { break }
        }
        // Give it a moment to finish writing, then close it, so the mod is
        // not started beside it.
        try? await Task.sleep(for: .seconds(2))
        _ = try? await Wine.runWine(["taskkill", "/f", "/im", exe.lastPathComponent], bottle: bottle)
        try? await Task.sleep(for: .seconds(3))
    }
}
