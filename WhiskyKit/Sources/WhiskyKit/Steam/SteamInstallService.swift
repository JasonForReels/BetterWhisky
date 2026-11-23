//
//  SteamInstallService.swift
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

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "SteamInstall")

/// Where one owned game is in a bottle's Steam client.
public enum SteamInstallStatus: Equatable, Sendable {
    case notInstalled
    /// Steam has a manifest for it and is fetching or staging it. `fraction`
    /// is nil until Steam has worked out the download size.
    case installing(fraction: Double?)
    case installed(sizeOnDisk: Int64?, lastPlayed: Date?)

    public var isInstalled: Bool {
        if case .installed = self { true } else { false }
    }
}

/// Asks a bottle's Steam client to install or uninstall a game.
///
/// Steam does the work: it checks the licence, fetches and decrypts the
/// depots, and writes the game. Nothing here downloads game content. An
/// install is requested the way Steam itself records one that is queued, an
/// `appmanifest_<id>.acf` with the update-required flag, which the client
/// picks up when it starts and downloads like any other queued update.
public enum SteamInstallService {
    /// `StateFlags` of a manifest Steam has queued but not started:
    /// update required (2) plus update started (1024).
    static let queuedStateFlags = 1026

    // MARK: Reading state

    /// Every manifest in the bottle's Steam libraries, by App ID, including
    /// ones that are still downloading.
    public static func manifests(bottleURL: URL) -> [Int: SteamAppManifest] {
        guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottleURL) else { return [:] }
        var found: [Int: SteamAppManifest] = [:]
        for library in SteamLibrary.libraryRoots(steamRoot: steamRoot, bottleURL: bottleURL) {
            let steamApps = library.appending(path: "steamapps")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: steamApps.path(percentEncoded: false)))
                ?? []
            for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
                guard let manifest = SteamAppManifest(contentsOf: steamApps.appending(path: name)),
                      found[manifest.appId] == nil else { continue }
                found[manifest.appId] = manifest
            }
        }
        return found
    }

    /// The install state of `appId`, from its manifest.
    public static func status(appId: Int, manifests: [Int: SteamAppManifest]) -> SteamInstallStatus {
        guard let manifest = manifests[appId] else { return .notInstalled }
        // Fully installed and not mid-update is the only state that can be
        // played; an update in progress still shows its progress.
        if manifest.isFullyInstalled, manifest.stateFlags & 2 == 0 {
            return .installed(sizeOnDisk: manifest.sizeOnDisk, lastPlayed: manifest.lastPlayed)
        }
        return .installing(fraction: manifest.downloadFraction)
    }

    // MARK: Requesting

    /// The text of a queued-install manifest.
    static func stubManifest(appId: Int, name: String) -> String {
        let installDir = installDirectoryName(for: name, appId: appId)
        let quotedName = name.replacingOccurrences(of: "\"", with: "")
        return """
        "AppState"
        {
        \t"appid"\t\t"\(appId)"
        \t"Universe"\t\t"1"
        \t"name"\t\t"\(quotedName)"
        \t"StateFlags"\t\t"\(queuedStateFlags)"
        \t"installdir"\t\t"\(installDir)"
        \t"SizeOnDisk"\t\t"0"
        \t"AutoUpdateBehavior"\t\t"0"
        \t"AllowOtherDownloadsWhileRunning"\t\t"0"
        }

        """
    }

    /// A folder name Windows and Steam both accept. Steam renames it to the
    /// game's own install folder once it has the app's info.
    static func installDirectoryName(for name: String, appId: Int) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_.'"))
        let cleaned = String(name.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty || !SteamLibrary.isSafePathComponent(cleaned) ? "App \(appId)" : cleaned
    }

    /// Writes the queued manifest into the bottle's main Steam library.
    /// Leaves an existing manifest alone, since Steam already knows the game.
    @discardableResult
    public static func queueInstall(appId: Int, name: String, bottleURL: URL) throws -> Bool {
        guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottleURL) else {
            throw SteamLaunchError.steamNotInstalled
        }
        let steamApps = steamRoot.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
        let manifest = steamApps.appending(path: "appmanifest_\(appId).acf")
        guard !FileManager.default.fileExists(atPath: manifest.path(percentEncoded: false)) else { return false }
        try stubManifest(appId: appId, name: name).write(to: manifest, atomically: true, encoding: .utf8)
        return true
    }

    /// Queues the install and makes sure the client reads it.
    ///
    /// The client reads manifests when it starts, so a running client is
    /// restarted once; a client that is not running is started silently.
    @MainActor
    public static func requestInstall(appId: Int, name: String, bottle: Bottle) async throws {
        guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottle.url) else {
            throw SteamLaunchError.steamNotInstalled
        }
        let steamExe = steamRoot.appending(path: "steam.exe")
        let wrote = try queueInstall(appId: appId, name: name, bottleURL: bottle.url)
        try await Wine.prepareBottlePrefix(bottle: bottle)
        let pids = await SteamLauncher.hostSteamPIDs()
        let running = await SteamLauncher.isClientRunning(bottle: bottle, hostSteamPIDs: pids)
        if running, wrote {
            logger.info("Restarting Steam so it picks up app \(appId)")
            _ = try await shutDownClient(steamRoot: steamRoot, bottle: bottle)
            SteamLauncher.startClient(steamExe: steamExe, bottle: bottle)
        } else if !running {
            SteamLauncher.startClient(steamExe: steamExe, bottle: bottle)
        }
    }

    /// Hands a `steam://` command to the bottle's client. Steam shows its own
    /// dialog for these, so they are the fallback, not the first route.
    @MainActor
    public static func openSteamURL(_ command: String, appId: Int, bottle: Bottle) async throws {
        guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottle.url) else {
            throw SteamLaunchError.steamNotInstalled
        }
        try await Wine.prepareBottlePrefix(bottle: bottle)
        try await Wine.runProgram(
            at: steamRoot.appending(path: "steam.exe"), args: ["steam://\(command)/\(appId)"], bottle: bottle
        )
    }

    /// Uninstalls without showing any Steam window.
    ///
    /// Steam's own uninstall needs its window for a confirmation, so this
    /// does what that uninstall does, with the client closed so it can't
    /// rewrite anything meanwhile: removes the game's folder, its pending
    /// download and shader cache, and finally its manifest. Only paths named
    /// by the game's own manifest inside its own library are touched, and
    /// saves (Steam Cloud, `userdata`) are left alone. The client is started
    /// again, hidden, if it was running.
    @MainActor
    public static func uninstallInBackground(appId: Int, bottle: Bottle) async throws {
        guard let steamRoot = SteamLibrary.detectInstall(bottleURL: bottle.url) else {
            throw SteamLaunchError.steamNotInstalled
        }
        guard let library = libraryHolding(appId: appId, steamRoot: steamRoot, bottleURL: bottle.url) else { return }
        let wasRunning = try await shutDownClient(steamRoot: steamRoot, bottle: bottle)
        try removeInstall(appId: appId, library: library)
        if wasRunning {
            SteamLauncher.startClient(steamExe: steamRoot.appending(path: "steam.exe"), bottle: bottle)
        }
    }

    static func libraryHolding(appId: Int, steamRoot: URL, bottleURL: URL) -> URL? {
        SteamLibrary.libraryRoots(steamRoot: steamRoot, bottleURL: bottleURL).first { library in
            let manifest = library.appending(path: "steamapps/appmanifest_\(appId).acf")
            return FileManager.default.fileExists(atPath: manifest.path(percentEncoded: false))
        }
    }

    /// Removes one game's files from one library. Separate from the client
    /// handling so it can be tested on a plain folder.
    static func removeInstall(appId: Int, library: URL) throws {
        let steamApps = library.appending(path: "steamapps")
        let manifestURL = steamApps.appending(path: "appmanifest_\(appId).acf")
        guard let manifest = SteamAppManifest(contentsOf: manifestURL), manifest.appId == appId else { return }
        var targets = [
            steamApps.appending(path: "downloading/\(appId)"),
            steamApps.appending(path: "shadercache/\(appId)"),
            steamApps.appending(path: "workshop/content/\(appId)"),
            steamApps.appending(path: "workshop/appworkshop_\(appId).acf")
        ]
        // A manifest whose installdir escapes the library is not trusted
        // with a delete; the rest still goes.
        if SteamLibrary.isSafePathComponent(manifest.installDir) {
            targets.insert(steamApps.appending(path: "common").appending(path: manifest.installDir), at: 0)
        }
        let fileManager = FileManager.default
        for target in targets where fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
            try fileManager.removeItem(at: target)
        }
        // Last, so an interrupted uninstall still shows as installed and
        // Steam can verify or finish it.
        try fileManager.removeItem(at: manifestURL)
    }

    /// Closes the bottle's client and waits for it to exit.
    /// - Returns: Whether it was running.
    @MainActor
    static func shutDownClient(steamRoot: URL, bottle: Bottle) async throws -> Bool {
        let running = await SteamLauncher.isClientRunning(bottle: bottle, hostSteamPIDs: SteamLauncher.hostSteamPIDs())
        guard running else { return false }
        try await Wine.runProgram(at: steamRoot.appending(path: "steam.exe"), args: ["-shutdown"], bottle: bottle)
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .seconds(2))
            if await !SteamLauncher.isClientRunning(bottle: bottle, hostSteamPIDs: SteamLauncher.hostSteamPIDs()) {
                break
            }
        }
        return true
    }
}

/// Installs the Steam client itself into a bottle, from Valve's own installer.
public enum SteamClientInstaller {
    static let installerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    @MainActor
    public static func install(into bottle: Bottle, session: URLSession = .shared) async throws {
        if SteamLibrary.detectInstall(bottleURL: bottle.url) != nil { return }
        let (downloaded, response) = try await session.download(from: installerURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SteamWebAPIError.http(http.statusCode)
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "BetterWhisky-SteamSetup-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = folder.appending(path: "SteamSetup.exe")
        try FileManager.default.moveItem(at: downloaded, to: setup)

        try await Wine.prepareBottlePrefix(bottle: bottle)
        let run = try await Wine.runProgram(at: setup, args: ["/S"], bottle: bottle)
        await run.outputCompletion.wait()
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        while SteamLibrary.detectInstall(bottleURL: bottle.url) == nil {
            guard ContinuousClock.now < deadline else { throw SteamLaunchError.steamNotInstalled }
            try await Task.sleep(for: .seconds(2))
        }
    }
}
