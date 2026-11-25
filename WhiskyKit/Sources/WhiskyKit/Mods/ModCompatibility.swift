//
//  ModCompatibility.swift
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

/// A mod downloaded and unpacked, not yet installed, so it can be checked
/// against the mods already in a profile first.
public struct StagedMod: Sendable {
    /// Temporary folder holding everything; ``ModInstaller/discard(_:)`` removes it.
    public let work: URL
    /// The unpacked files, laid out as they'd land under ``prefix``.
    public let source: URL
    /// Where in the game folder ``source`` merges to (`""`, `BepInEx/plugins`, …).
    public let prefix: String

    /// Every file, as its path in the game folder.
    public var gamePaths: [String] {
        guard let walker = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        let root = source.standardizedFileURL.resolvingSymlinksInPath().path
        return walker.compactMap { item -> String? in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root + "/") else { return nil }
            let relative = String(path.dropFirst(root.count + 1))
            return prefix.isEmpty ? relative : "\(prefix)/\(relative)"
        }
        .sorted()
    }

    /// Drops staged files that another mod in `gameFolder` already put there,
    /// so installing never replaces another mod's files. The game's own files
    /// are still replaced (and backed up). Returns the game paths it dropped.
    @discardableResult
    public func keepingExisting(in gameFolder: URL, except repo: String? = nil) -> [String] {
        let owned = Set(ModInstaller.installedMods(in: gameFolder)
            .filter { $0.repo != repo }
            .flatMap(\.files)
            .map { $0.lowercased() })
        return gamePaths.filter { path in
            guard owned.contains(path.lowercased()) else { return false }
            try? FileManager.default.removeItem(at: file(atGamePath: path))
            return true
        }
    }

    /// The file at a game-folder path.
    func file(atGamePath path: String) -> URL {
        let relative = prefix.isEmpty ? path : String(path.dropFirst(prefix.count + 1))
        return source.appending(path: relative)
    }
}

/// What the check found about putting one mod in with others.
public struct ModCompatibilityReport: Sendable, Equatable {
    public enum Severity: Int, Comparable, Sendable {
        /// Worth knowing; nothing to decide.
        case info
        /// Can go in, but something changes for the mods already there.
        case warning
        /// Can't go in.
        case blocker

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Finding: Hashable, Sendable {
        public var severity: Severity
        public var message: String
    }

    public var findings: [Finding] = []
    /// Game-folder paths left out of the install: the loader the profile
    /// already runs, and shared plugins the profile has at the same or a
    /// newer version.
    public var skipped: Set<String> = []

    public var canInstall: Bool { !findings.contains { $0.severity == .blocker } }
    public var worst: Severity { findings.map(\.severity).max() ?? .info }

    mutating func add(_ severity: Severity, _ message: String) {
        findings.append(Finding(severity: severity, message: message))
    }
}

/// Checks a mod against the mods already in a profile before it joins them.
///
/// Mods in one profile share a single BepInEx and one `BepInEx/plugins`
/// folder, so what can go wrong is between the mods: two that are known not
/// to run together, two that bundle the same library (Reactor, MiraAPI) at
/// versions that don't match, two built on different BepInEx versions, or
/// one overwriting another's files.
public enum ModCompatibility {
    /// Files that make up the loader. A profile keeps the loader it has; a
    /// second copy from the new mod would replace it under the first mod.
    static let loaderPrefixes = [
        "bepinex/core/", "bepinex/unity-libs/", "bepinex/interop/", "bepinex/cache/", "dotnet/"
    ]
    static let loaderFiles = ["winhttp.dll", "doorstop_config.ini", ".doorstop_version", "bepinex/config/bepinex.cfg"]

    public static func isLoaderFile(_ gamePath: String) -> Bool {
        let lower = gamePath.lowercased()
        return loaderFiles.contains(lower) || loaderPrefixes.contains { lower.hasPrefix($0) }
    }

    /// - Parameters:
    ///   - name: the new mod's name, for messages.
    ///   - repo: the new mod's `owner/name`.
    ///   - staged: its unpacked files.
    ///   - profile: the profile's game folder.
    ///   - requiredGameVersion: the game version its release says it needs, if any.
    public static func check(
        name: String, repo: String, staged: StagedMod, profile: URL,
        requiredGameVersion: String? = nil, presets: [ModPreset] = ModPreset.builtIn
    ) -> ModCompatibilityReport {
        var report = ModCompatibilityReport()
        let present = ModInstaller.installedMods(in: profile)
        let others = present.filter { $0.repo.lowercased() != repo.lowercased() }
        let paths = staged.gamePaths

        if present.contains(where: { $0.repo.lowercased() == repo.lowercased() }) {
            report.add(.info, "\(name) is already in this profile; this replaces it.")
        }
        checkConflicts(name: name, repo: repo, with: others, presets: presets, into: &report)
        checkRoleMods(name: name, repo: repo, with: others, into: &report)
        checkLoader(name: name, paths: paths, staged: staged, profile: profile, into: &report)
        checkPlugins(name: name, paths: paths, staged: staged, profile: profile, owners: others, into: &report)
        checkOverwrites(name: name, paths: paths, skipping: report.skipped, owners: others, into: &report)

        if let required = requiredGameVersion,
           let profileVersion = ModInstaller.frozenVersion(profile) ?? ModGameVersion.installed(gameFolder: profile),
           !ModGameVersion.matches(required, profileVersion) {
            report.add(.blocker, "\(name) is built for Among Us \(required); the mods here run on \(profileVersion).")
        }
        if report.findings.isEmpty, let first = others.first {
            let names = others.count == 1 ? first.name : "the \(others.count) mods here"
            report.add(.info, "No conflicts with \(names).")
        }
        return report
    }

    /// Mods a preset says can't share a game with it, either way round.
    static func checkConflicts(
        name: String, repo: String, with others: [InstalledMod], presets: [ModPreset],
        into report: inout ModCompatibilityReport
    ) {
        let newPreset = presets.first { $0.repo.lowercased() == repo.lowercased() }
        for other in others {
            let otherPreset = presets.first { $0.repo.lowercased() == other.repo.lowercased() }
            let reason = newPreset?.conflict(with: other.repo) ?? otherPreset?.conflict(with: repo)
            if let reason {
                report.add(.blocker, "\(name) and \(other.name) can't run together: \(reason)")
            }
        }
    }

    /// Mods that each change Among Us's roles, meetings and game settings.
    /// Two of them in one profile often clash once the game runs, which no
    /// file check can see.
    static let roleModNames = [
        "townofus", "touMira", "theotherroles", "stellarroles", "tohe", "townofhost", "extraroles", "laschesroles"
    ].map { $0.lowercased() }

    public static func isRoleMod(name: String, repo: String) -> Bool {
        let keys = [name, repo, (repo as NSString).lastPathComponent].map {
            $0.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        return keys.contains { key in roleModNames.contains { key.contains($0) } }
    }

    static func checkRoleMods(
        name: String, repo: String, with others: [InstalledMod], into report: inout ModCompatibilityReport
    ) {
        guard isRoleMod(name: name, repo: repo) else { return }
        for other in others where isRoleMod(name: other.name, repo: other.repo) {
            report.add(.warning, "\(name) and \(other.name) are both role mods: each changes the roles, meetings "
                + "and game settings, so together they may crash or act oddly. Nothing is lost if they do: remove "
                + "\(name) with its ⋯ menu, or keep each in its own profile and pick one with Play With.")
        }
    }

    /// One BepInEx per profile: the new mod's loader is left out, and a
    /// different major version of it means its plugins were built for
    /// something else.
    static func checkLoader(
        name: String, paths: [String], staged: StagedMod, profile: URL, into report: inout ModCompatibilityReport
    ) {
        let loaderPaths = paths.filter(isLoaderFile)
        let pluginPaths = paths.filter { $0.lowercased().hasPrefix("bepinex/plugins/") }
        guard !loaderPaths.isEmpty || !pluginPaths.isEmpty else { return }
        guard ModInstaller.hasBepInEx(profile) else {
            if loaderPaths.isEmpty {
                report.add(.blocker, "\(name) is a BepInEx plugin, and this profile has no BepInEx to load it.")
            }
            return
        }
        report.skipped.formUnion(loaderPaths)
        let core = paths.first { isBepInExCore($0) }
        let profileCore = coreDLL(in: profile)
        if let core, let profileCore,
           let mine = PEVersion.fileVersion(of: staged.file(atGamePath: core)),
           let theirs = PEVersion.fileVersion(of: profileCore) {
            if mine.major != theirs.major {
                report.add(.blocker, "\(name) is built on BepInEx \(mine); the mods here run on BepInEx \(theirs).")
            } else if mine != theirs {
                report.add(.info, "\(name) comes with BepInEx \(mine); it'll use the profile's \(theirs).")
            }
        } else if !loaderPaths.isEmpty {
            report.add(.info, "\(name) comes with its own BepInEx; it'll use the one already here.")
        }
    }

    /// Libraries two mods both bundle (Reactor, MiraAPI): one copy stays,
    /// the newer, unless the versions differ in a way that breaks one of them.
    static func checkPlugins( // swiftlint:disable:this function_parameter_count
        name: String, paths: [String], staged: StagedMod, profile: URL, owners: [InstalledMod],
        into report: inout ModCompatibilityReport
    ) {
        let existing = pluginFiles(in: profile)
        for path in paths where path.lowercased().hasPrefix("bepinex/plugins/") && path.lowercased().hasSuffix(".dll") {
            let fileName = (path as NSString).lastPathComponent
            guard let current = existing[fileName.lowercased()] else { continue }
            let library = (fileName as NSString).deletingPathExtension
            let owner = owners.first { mod in
                mod.files.contains { ($0 as NSString).lastPathComponent.lowercased() == fileName.lowercased() }
            }?.name ?? "the mods here"
            let incoming = staged.file(atGamePath: path)
            if FileManager.default.contentsEqual(atPath: incoming.path, andPath: current.path) {
                report.skipped.insert(path)
                continue
            }
            guard let mine = PEVersion.fileVersion(of: incoming),
                  let theirs = PEVersion.fileVersion(of: current) else {
                report.add(.warning, "\(name) and \(owner) both include \(library), and their copies differ. "
                    + "\(name)'s replaces it for the whole profile.")
                continue
            }
            if mine.major != theirs.major {
                report.add(.blocker, "\(name) needs \(library) \(mine) and \(owner) uses \(library) \(theirs). "
                    + "Only one can be loaded, and they aren't compatible.")
            } else if mine <= theirs {
                report.skipped.insert(path)
                report.add(.info, "Shares \(library) with \(owner) and uses the \(theirs) already here.")
            } else {
                report.add(.warning, "Updates \(library) from \(theirs) to \(mine), which \(owner) uses too.")
            }
        }
    }

    /// Any other file the new mod would write over that belongs to a mod already there.
    static func checkOverwrites(
        name: String, paths: [String], skipping skipped: Set<String>, owners: [InstalledMod],
        into report: inout ModCompatibilityReport
    ) {
        for owner in owners {
            let theirs = Set(owner.files.map { $0.lowercased() })
            let clashes = paths.filter { path in
                !skipped.contains(path) && !path.lowercased().hasSuffix(".dll") && theirs.contains(path.lowercased())
            }
            guard !clashes.isEmpty else { continue }
            let notes = clashes.filter(isReadingFile)
            let files = clashes.filter { !isReadingFile($0) }
            if !notes.isEmpty {
                let theirs = possessive(owner.name)
                report.add(.info, "Both include \(list(notes)), a text file for reading that the game doesn't use. "
                    + "\(possessive(name)) copy is shown, and \(theirs) comes back if you remove \(name).")
            }
            if !files.isEmpty {
                let theirs = possessive(owner.name)
                report.add(.warning, "Replaces \(theirs) \(list(files)). BetterWhisky keeps \(theirs) "
                    + "copy and puts it back if you remove \(name).")
            }
        }
    }

    /// Notes for people, not the game: readme, changelog, licence and the like.
    static func isReadingFile(_ path: String) -> Bool {
        let file = (path as NSString).lastPathComponent.lowercased()
        let ext = (file as NSString).pathExtension
        if ["txt", "md", "rtf", "pdf", "html", "htm"].contains(ext) { return true }
        return ["readme", "license", "licence", "changelog", "changes", "notice", "credits"]
            .contains((file as NSString).deletingPathExtension)
    }

    /// "StellarRoles'" rather than "StellarRoles's".
    static func possessive(_ name: String) -> String {
        name.lowercased().hasSuffix("s") ? "\(name)'" : "\(name)'s"
    }

    static func list(_ paths: [String]) -> String {
        let names = paths.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return paths.count > 2 ? "\(names) and \(paths.count - 2) more" : names
    }

    // MARK: Helpers

    static func isBepInExCore(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower == "bepinex/core/bepinex.core.dll" || lower == "bepinex/core/bepinex.dll"
    }

    static func coreDLL(in gameFolder: URL) -> URL? {
        ["BepInEx/core/BepInEx.Core.dll", "BepInEx/core/BepInEx.dll"]
            .map { gameFolder.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// The profile's plugin DLLs by lowercased file name, including ones
    /// parked by an add-on's off switch: turning it back on would bring them back.
    static func pluginFiles(in gameFolder: URL) -> [String: URL] {
        var found: [String: URL] = [:]
        for root in ["\(ModInstaller.disabledFolder)/BepInEx/plugins", "BepInEx/plugins"] {
            guard let walker = FileManager.default.enumerator(
                at: gameFolder.appending(path: root), includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in walker where url.pathExtension.lowercased() == "dll" {
                found[url.lastPathComponent.lowercased()] = url
            }
        }
        return found
    }
}

// MARK: - Conflicts declared by presets

public extension ModPreset {
    /// Why this mod can't run alongside `repo`, if its preset says so.
    func conflict(with repo: String) -> String? {
        conflictsWith?.first { $0.repo.lowercased() == repo.lowercased() }?.reason
    }
}

/// A mod a preset can't share a game with, and why.
public struct ModConflict: Codable, Hashable, Sendable {
    public var repo: String
    public var reason: String

    public init(repo: String, reason: String) {
        self.repo = repo
        self.reason = reason
    }
}
