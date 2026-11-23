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

/// Gives a mod a signed-in account save before its launch.
///
/// When the plain game has signed in in the bottle, its save files are
/// copied to the mod's names: no game runs. Only when it never has, the
/// plain game is run once in Unity's headless mode (`-batchmode
/// -nographics`: no window, no sound) until it has saved a signed-in
/// account, then closed. The sign-in itself, with its age check, is the
/// game's own, done with Innersloth's servers; nothing here fakes it.
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
    /// a signed-in save of its own. A signed-out one, left by a failed first
    /// run, is replaced.
    static func seedModSave(_ save: ModAccountSave, in folder: URL) throws {
        guard let account = save.files.first else { return }
        guard !isSignedIn(folder.appending(path: account + save.suffix)) else { return }
        for file in save.files {
            let target = folder.appending(path: file + save.suffix)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: folder.appending(path: file), to: target)
        }
    }

    /// Makes sure the mod named `modName` has a signed-in save before it
    /// starts. Does nothing for mods that don't need one.
    /// - Returns: Whether the mod's save is ready.
    @MainActor
    @discardableResult
    public static func prepare(
        appId: Int, gameFolder: URL, modName: String?, bottle: Bottle, timeout: Duration = .seconds(150)
    ) async -> Bool {
        guard let save = ModPreset.named(modName)?.accountSave else { return true }
        guard let folder = saveFolder(save, bottleURL: bottle.url) else { return false }
        if !plainSaveReady(save, in: folder) {
            await signInHidden(appId: appId, gameFolder: gameFolder, bottle: bottle) {
                plainSaveReady(save, in: folder)
            }
        }
        guard plainSaveReady(save, in: folder) else {
            logger.info("The plain game has no signed-in save for \(appId); starting the mod anyway")
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

    /// Where the hidden run writes its log: headless Unity needs one.
    static func logURL(appId: Int, bottleURL: URL) -> URL {
        SteamModLauncher.folder(bottleURL).appending(path: "account-primer-\(appId).log")
    }

    /// Runs the plain game unseen until `isDone`, then closes it.
    @MainActor
    static func signInHidden(
        appId: Int, gameFolder: URL, bottle: Bottle, timeout: Duration = .seconds(150),
        isDone: @escaping @Sendable () -> Bool
    ) async {
        guard let exe = ModInstaller.mainExecutable(in: gameFolder) else { return }
        // The sign-in goes through the Steam client: start it hidden and give
        // it time to sign in if a launch option change just closed it.
        await SteamInstallService.startClientForSignIn(bottle: bottle)
        for _ in 0 ..< 45 where await !SteamModLauncher.isSteamRunning() {
            try? await Task.sleep(for: .seconds(2))
        }
        try? await Task.sleep(for: .seconds(10))
        let log = logURL(appId: appId, bottleURL: bottle.url)
        try? FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        logger.info("Signing in the plain game once, unseen, before the first modded launch of \(appId)")
        do {
            try await Wine.runProgram(
                at: exe,
                args: ["-batchmode", "-nographics", "-logFile", #"C:\BetterWhisky\"# + log.lastPathComponent],
                bottle: bottle,
                // Lets the Steam API start from a direct launch, through the
                // client that is already running.
                environment: ["SteamAppId": String(appId), "SteamGameId": String(appId)]
            )
        } catch {
            logger.error("Couldn't start the plain game: \(error.localizedDescription)")
            return
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .seconds(3))
            if await Task.detached(operation: isDone).value { break }
        }
        // Give it a moment to finish writing, then close it, so the mod is
        // not started beside it.
        try? await Task.sleep(for: .seconds(2))
        _ = try? await Wine.runWine(["taskkill", "/f", "/im", exe.lastPathComponent], bottle: bottle)
        try? await Task.sleep(for: .seconds(3))
    }
}
