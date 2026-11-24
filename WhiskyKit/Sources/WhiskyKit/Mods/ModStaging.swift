//
//  ModStaging.swift
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

private let stagingLogger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "ModInstaller")

/// Installing in two steps, unpack then install, so a mod going in with
/// others can be checked by ``ModCompatibility`` in between.
public extension ModInstaller {
    /// The folder a mod goes into under `rule`, making it when it's a copy of the game.
    static func targetFolder(
        rule: ModInstallRule, name: String, gameExecutable: URL, profile: String?
    ) throws -> URL {
        let gameFolder = gameExecutable.deletingLastPathComponent()
        if rule.frozenCopy {
            // Into the named profile's copy, or the mod's own when there's none.
            return try frozenCopy(of: gameFolder, for: profile ?? name)
        } else if rule.ownFolder {
            let folder = modFolder(for: name, game: gameFolder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } else if rule.copyGame {
            return try copyGameFolder(gameFolder, for: name)
        }
        return gameFolder
    }

    /// Downloads a release asset and unpacks it, without installing, so it
    /// can be checked against a profile's mods first.
    public static func stage(
        asset: GitHubRelease.Asset, rule: ModInstallRule, into gameFolder: URL, session: URLSession = .shared
    ) async throws -> StagedMod {
        let download = try makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: download) }
        let (downloaded, _) = try await session.download(from: asset.browserDownloadURL)
        let file = download.appending(path: asset.name)
        try FileManager.default.moveItem(at: downloaded, to: file)
        return try await stage(file, rule: rule, gameFolder: gameFolder)
    }

    /// Unpacks a local `.zip` or `.dll` for checking, as ``installLocal`` would install it.
    public static func stageLocal(file: URL, rule: ModInstallRule, into gameFolder: URL) async throws -> StagedMod {
        let ext = file.pathExtension.lowercased()
        guard ext == "zip" || ext == "dll" else { throw ModInstallError.unsupportedFile(file.lastPathComponent) }
        return try await stage(file, rule: rule, gameFolder: gameFolder)
    }

    static func stage(_ file: URL, rule: ModInstallRule, gameFolder: URL) async throws -> StagedMod {
        let work = try makeWorkFolder()
        do {
            let source: URL
            switch rule.mode {
            case .extract:
                source = try await extract(
                    file, into: work.appending(path: "unpacked"), stripTopFolder: rule.stripTopFolder
                )
            case .copyFile:
                source = work.appending(path: "single")
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: source.appending(path: file.lastPathComponent))
            }
            // A BepInEx plugin packed as a bare .dll in a zip belongs in the plugins
            // folder; at the game root BepInEx never loads it.
            var prefix = rule.subpath
            if prefix.isEmpty, hasBepInEx(gameFolder), holdsOnlyPlugins(source) {
                prefix = "BepInEx/plugins"
            }
            _ = try resolve(prefix, in: gameFolder)
            return StagedMod(work: work, source: source, prefix: prefix)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Removes a staged mod's temporary files.
    public static func discard(_ staged: StagedMod) {
        try? FileManager.default.removeItem(at: staged.work)
    }

    /// Installs a staged mod into `gameFolder`, leaving out `skipping`
    /// (game-folder paths: the profile's loader and shared plugins it keeps).
    public static func installStaged( // swiftlint:disable:this function_parameter_count
        _ staged: StagedMod, version: String, name: String, repo: String, rule: ModInstallRule,
        gameExecutable: URL, gameFolder: URL, skipping: Set<String> = []
    ) throws -> ModInstallResult {
        let target = try resolve(staged.prefix, in: gameFolder)
        // Replacing an older copy of the same mod: take it out first.
        if let previous = installedMods(in: gameFolder).first(where: { $0.repo == repo }) {
            try uninstall(previous, from: gameFolder)
        }
        for path in skipping {
            try? FileManager.default.removeItem(at: staged.file(atGamePath: path))
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let written = try merge(staged.source, into: target, gameFolder: gameFolder, backupKey: safeName(repo))
        let mod = InstalledMod(name: name, repo: repo, version: version, installedAt: Date(), files: written)
        try writeManifest(installedMods(in: gameFolder).filter { $0.repo != repo } + [mod], to: gameFolder)
        stagingLogger.info(
            "Installed \(name, privacy: .public) (\(written.count) files) into \(gameFolder.path, privacy: .public)"
        )
        // A mod in its own folder runs through the game's own executable.
        let executable = rule.ownFolder && !rule.frozenCopy
            ? gameExecutable : gameFolder.appending(path: gameExecutable.lastPathComponent)
        return ModInstallResult(gameFolder: gameFolder, executable: executable, mod: mod)
    }
}
