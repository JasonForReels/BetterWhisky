//
//  ModCompanion.swift
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

/// A mod that is its own Windows app, running next to the game rather than
/// inside it: BetterCrewLink reads Among Us's memory for proximity voice
/// chat. It's installed once into the bottle, and starts with the game
/// whichever profile is on, so it works alongside the profile's mods.
public struct ModCompanion: Hashable, Sendable, Identifiable {
    public var id: String { repo }
    public var name: String
    /// `owner/name` on GitHub.
    public var repo: String
    /// Regular expression for the Windows installer among the release files.
    public var installerPattern: String
    /// The app inside the installer, as a path 7-Zip can extract: the
    /// installer itself can't run under Wine (see ``SevenZip``).
    public var payload: String
    /// Where in the bottle's `drive_c` the app goes.
    public var installFolder: String
    /// The app's executable, as the installer names it.
    public var executableName: String
    /// The Steam game it runs alongside.
    public var steamAppId: Int
    /// Arguments it needs under Wine.
    public var launchArguments: [String]
    /// The logo the app ships for it, by asset name.
    public var logoAsset: String?
    public var summary: String

    public static let builtIn: [ModCompanion] = [
        ModCompanion(
            name: "BetterCrewLink",
            repo: "OhMyGuus/BetterCrewLink",
            installerPattern: #"^Better-CrewLink-Setup-[\d.]+\.exe$"#,
            payload: "$PLUGINSDIR/app-64.7z",
            installFolder: "Program Files/Better-CrewLink",
            executableName: "Better-CrewLink.exe",
            steamAppId: 945360,
            // Electron's sandbox needs kernel features Wine doesn't have. Its
            // GPU process draws into the main window through a cross-process
            // swap chain, which Wine lacks (the window stays white): drawing
            // in the main process avoids it.
            launchArguments: ["--no-sandbox", "--in-process-gpu"],
            logoAsset: "ModLogo-BetterCrewLink",
            summary: "Proximity voice chat. Runs next to the game, so it works with any profile's mods."
        )
    ]

    public static func companions(steamAppId: Int?) -> [ModCompanion] {
        guard let steamAppId else { return [] }
        return builtIn.filter { $0.steamAppId == steamAppId }
    }

    /// The installed app in a bottle: per-user installs land in
    /// `AppData/Local/Programs`, machine-wide ones in `Program Files`.
    public func installedExecutable(bottleURL: URL) -> URL? {
        let driveC = bottleURL.appending(path: "drive_c")
        let fileManager = FileManager.default
        var roots = [driveC.appending(path: "Program Files"), driveC.appending(path: "Program Files (x86)")]
        let users = driveC.appending(path: "users")
        for user in (try? fileManager.contentsOfDirectory(atPath: users.path(percentEncoded: false))) ?? [] {
            roots.append(users.appending(path: user).appending(path: "AppData/Local/Programs"))
        }
        for root in roots {
            for folder in (try? fileManager.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? [] {
                let exe = root.appending(path: folder).appending(path: executableName)
                if fileManager.fileExists(atPath: exe.path(percentEncoded: false)) { return exe }
            }
        }
        return nil
    }

    // MARK: Installing

    /// Downloads the latest release's installer and unpacks the app inside
    /// it into the bottle with 7-Zip, fetching 7-Zip first if needed.
    /// Returns the version installed.
    @discardableResult
    public func install(
        bottleURL: URL, session: URLSession = .shared, progress: @Sendable (String) async -> Void = { _ in }
    ) async throws -> String {
        let release = try await GitHubReleases.latestRelease(repo: repo, session: session)
        guard let asset = release.assets.first(where: {
            $0.name.range(of: installerPattern, options: .regularExpression) != nil
        }) else { throw ModCompanionError.noInstaller(name, release.tagName) }

        if !SevenZip.isInstalled {
            await progress("Getting 7-Zip…")
            try await SevenZip.ensureInstalled(session: session)
        }
        await progress("Downloading \(name) \(release.tagName)…")
        let work = FileManager.default.temporaryDirectory
            .appending(path: "BetterWhiskyCompanion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let (downloaded, _) = try await session.download(from: asset.browserDownloadURL)
        let installer = work.appending(path: asset.name)
        try FileManager.default.moveItem(at: downloaded, to: installer)

        await progress("Unpacking \(name)…")
        try await SevenZip.extract(installer, paths: [payload], to: work.appending(path: "installer"))
        let app = work.appending(path: "app")
        try await SevenZip.extract(work.appending(path: "installer").appending(path: payload), to: app)
        guard FileManager.default.fileExists(atPath: app.appending(path: executableName).path(percentEncoded: false))
        else { throw ModCompanionError.notInInstaller(name, executableName) }

        // Replaces an earlier version in one move, so a failed unpack leaves it as it was.
        let target = bottleURL.appending(path: "drive_c").appending(path: installFolder)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: app, to: target)
        return release.tagName
    }

    /// Takes the app out of the bottle: the folder its executable is in, which
    /// for an install by ``install(bottleURL:session:progress:)`` is ``installFolder``.
    /// Its settings in `AppData/Roaming` stay, so a reinstall picks them up.
    public func uninstall(bottleURL: URL, defaults: UserDefaults = .standard) throws {
        guard let exe = installedExecutable(bottleURL: bottleURL) else { return }
        let folder = exe.deletingLastPathComponent()
        // Only ever an app folder of its own, never Program Files itself.
        let driveC = bottleURL.appending(path: "drive_c").standardizedFileURL.path
        guard folder.standardizedFileURL.path.hasPrefix(driveC + "/"),
              !["program files", "program files (x86)", "programs"].contains(folder.lastPathComponent.lowercased())
        else { return }
        try FileManager.default.removeItem(at: folder)
        defaults.removeObject(forKey: defaultsKey(bottleURL: bottleURL))
    }

    /// The installed app as a program of `bottle`, with the arguments it
    /// needs under Wine saved on it unless the person set their own, so a
    /// Library card or the Run button starts it like the Mods row does.
    @MainActor
    public func program(in bottle: Bottle) -> Program? {
        guard let exe = installedExecutable(bottleURL: bottle.url) else { return nil }
        let program = bottle.programs.first { $0.url == exe } ?? Program(url: exe, bottle: bottle)
        if program.settings.arguments.trimmingCharacters(in: .whitespaces).isEmpty {
            program.settings.arguments = launchArguments.joined(separator: " ")
        }
        return program
    }

    // MARK: Starting with the game

    private func defaultsKey(bottleURL: URL) -> String {
        "modCompanion.startWithGame.\(repo).\(bottleURL.path(percentEncoded: false))"
    }

    /// Whether it starts when the game does. On once it's installed, until turned off.
    public func startsWithGame(bottleURL: URL, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey(bottleURL: bottleURL)) as? Bool ?? true
    }

    public func setStartsWithGame(_ isOn: Bool, bottleURL: URL, defaults: UserDefaults = .standard) {
        defaults.set(isOn, forKey: defaultsKey(bottleURL: bottleURL))
    }

    // MARK: Compatibility

    /// What to know before using it with a profile's mods.
    ///
    /// It reads the game's memory by offsets it downloads for each Among Us
    /// release and falls back to the newest ones for a version it doesn't
    /// know. A profile frozen at an older version than Steam's game is the
    /// case that goes wrong; the mods themselves are a different process.
    public func compatibility(
        profileFolder: URL?, gameFolder: URL, mods: [InstalledMod]
    ) -> ModCompatibilityReport {
        var report = ModCompatibilityReport()
        if let profileFolder,
           let frozen = ModInstaller.frozenVersion(profileFolder),
           let current = ModGameVersion.installed(gameFolder: gameFolder),
           !ModGameVersion.matches(frozen, current) {
            report.add(.warning, "This profile is frozen at Among Us \(frozen) and Steam has \(current). "
                + "\(name) follows the newest version, so it may not connect to this one.")
        }
        if !mods.isEmpty {
            let names = mods.map(\.name).joined(separator: ", ")
            report.add(.info, "Runs as its own app next to the game, so it doesn't share files with \(names).")
        }
        report.add(.info, "Everyone in the lobby needs \(name) to hear each other.")
        return report
    }
}

public enum ModCompanionError: LocalizedError {
    case noInstaller(String, String)
    case notInInstaller(String, String)

    public var errorDescription: String? {
        switch self {
        case .noInstaller(let name, let version): return "\(name) \(version) has no Windows installer."
        case .notInInstaller(let name, let exe): return "\(name)'s installer doesn't have \(exe) where expected."
        }
    }
}
