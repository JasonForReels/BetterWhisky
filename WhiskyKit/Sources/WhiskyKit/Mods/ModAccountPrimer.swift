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

/// Signs the plain game in once, unseen, before a bottle's first modded launch.
///
/// In a new bottle a modded Among Us cannot reach its account ("could not
/// connect to Among Us account") until the plain game has signed in there
/// once; the mod keeps its own save data and relies on what that first plain
/// sign-in sets up. So the plain game is run first in Unity's headless mode
/// (`-batchmode -nographics`: no window, and Unity starts no audio), until
/// its log says it is signed in, then closed. Nobody sees or hears it.
public enum ModAccountPrimer {
    /// What a Unity game's `Player.log` says once its account sign-in is done.
    static let signedInMarker = "login status LoggedIn"

    /// Where the hidden run writes its log. Its own file, so it can't be
    /// confused with a visible run's `Player.log`, and so headless Unity has
    /// somewhere to write at all.
    static func logURL(appId: Int, bottleURL: URL) -> URL {
        SteamModLauncher.folder(bottleURL).appending(path: "account-primer-\(appId).log")
    }

    static func markerURL(appId: Int, bottleURL: URL) -> URL {
        SteamModLauncher.folder(bottleURL).appending(path: "account-ready-\(appId)")
    }

    /// Whether the plain game has already signed in in this bottle.
    public static func isPrimed(appId: Int, bottleURL: URL) -> Bool {
        let marker = markerURL(appId: appId, bottleURL: bottleURL)
        return FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
    }

    /// Runs the plain game hidden until it has signed in, once per bottle.
    ///
    /// Gives up after `timeout`; the modded launch then goes ahead as before,
    /// so this can only help. The Steam client must be running, since the
    /// sign-in goes through it.
    /// - Returns: Whether the game is signed in.
    @MainActor
    @discardableResult
    public static func primeIfNeeded(
        appId: Int, gameFolder: URL, bottle: Bottle, timeout: Duration = .seconds(150)
    ) async -> Bool {
        guard !isPrimed(appId: appId, bottleURL: bottle.url) else { return true }
        guard let exe = ModInstaller.mainExecutable(in: gameFolder) else { return false }
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
        try? FileManager.default.removeItem(at: log)
        logger.info("Signing in the plain game once before the first modded launch of \(appId)")

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
            return false
        }

        let signedIn = await waitForSignIn(log: log, timeout: timeout)
        _ = try? await Wine.runWine(["taskkill", "/f", "/im", exe.lastPathComponent], bottle: bottle)
        // Wait for it to be gone, so the modded copy is not started beside it.
        try? await Task.sleep(for: .seconds(3))
        if signedIn {
            try? FileManager.default.createDirectory(
                at: SteamModLauncher.folder(bottle.url), withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: markerURL(appId: appId, bottleURL: bottle.url)
                .path(percentEncoded: false), contents: nil)
        }
        logger.info("Plain sign-in for \(appId) \(signedIn ? "succeeded" : "timed out")")
        return signedIn
    }

    /// Polls the hidden run's log for the signed-in line.
    static func waitForSignIn(log: URL, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .seconds(3))
            if await Task.detached(operation: { logShowsSignIn(log) }).value { return true }
        }
        return false
    }

    static func logShowsSignIn(_ url: URL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.contains(signedInMarker) ?? false
    }
}
