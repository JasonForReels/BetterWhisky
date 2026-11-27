//
//  ModProfiles.swift
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

public enum ModProfileError: LocalizedError {
    case nameTaken(String)
    case emptyName

    public var errorDescription: String? {
        switch self {
        case .nameTaken(let name): return "There's already a profile called \(name)."
        case .emptyName: return "Give the profile a name."
        }
    }
}

/// Profiles: several modded copies of one game, each in its own
/// `<Game> Mods/<Profile>/game` folder with any mix of mods, each of which
/// can be switched on or off. A profile starts as a clean copy of the game
/// (``create(_:game:)``) or a clone of another one; on APFS either shares
/// storage with what it was made from until one side changes.
public enum ModProfiles {
    /// Makes an empty profile: a clean copy of the game with no mods yet.
    /// Returns the new profile's game folder.
    @discardableResult
    public static func create(_ name: String, game gameFolder: URL) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModProfileError.emptyName }
        let folder = ModInstaller.modFolder(for: trimmed, game: gameFolder)
        guard !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
            throw ModProfileError.nameTaken(trimmed)
        }
        return try ModInstaller.frozenCopy(of: gameFolder, for: trimmed)
    }

    /// Moves a profile, with all its mods, to the Trash.
    public static func remove(_ copy: URL) throws {
        let folder = profileFolder(of: copy)
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        let root = folder.deletingLastPathComponent()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        if left.allSatisfy({ $0.hasPrefix(".") }) { try? FileManager.default.removeItem(at: root) }
    }

    /// The profile's folder: `<Game> Mods/<Profile>`, which holds `game`.
    static func profileFolder(of copy: URL) -> URL { copy.deletingLastPathComponent() }

    /// What a profile is called: its folder's name, or the mod's own name for
    /// the profile the install made (whose folder is the mod name made safe).
    public static func displayName(of copy: URL, modName: String) -> String {
        let folder = profileFolder(of: copy).lastPathComponent
        return folder == ModInstaller.safeName(modName) ? modName : folder
    }

    /// Clones a profile under a new name. Returns the new profile's game folder.
    @discardableResult
    public static func duplicate(_ copy: URL, as name: String) throws -> URL {
        let target = try newFolder(next: profileFolder(of: copy), name: name)
        try FileManager.default.copyItem(at: profileFolder(of: copy), to: target)
        return target.appending(path: "game")
    }

    /// Renames a profile. Returns its game folder at the new place.
    @discardableResult
    public static func rename(_ copy: URL, to name: String) throws -> URL {
        let source = profileFolder(of: copy)
        let target = try newFolder(next: source, name: name)
        try FileManager.default.moveItem(at: source, to: target)
        return target.appending(path: "game")
    }

    static func newFolder(next sibling: URL, name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModProfileError.emptyName }
        let target = sibling.deletingLastPathComponent().appending(path: ModInstaller.safeName(trimmed))
        guard !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
            throw ModProfileError.nameTaken(trimmed)
        }
        return target
    }
}

// MARK: - Turning add-ons on and off

public extension ModInstaller {
    /// Where a turned-off mod's plugin files wait, inside the game folder.
    static let disabledFolder = "BepInEx/.betterwhisky-disabled"

    /// A mod's own files that a switch moves: everything it installed except
    /// the loader and folders shared with the profile's other mods.
    static func switchableFiles(_ mod: InstalledMod) -> [String] {
        let shared = ["winhttp.dll", "doorstop_config.ini", ".doorstop_version", "changelog.txt"]
        let sharedFolders = [
            "bepinex/core/", "bepinex/config/", "bepinex/cache/", "bepinex/interop/", "bepinex/unity-libs/",
            "bepinex/unhollowed/", "dotnet/", "mono/", "\(disabledFolder.lowercased())/"
        ]
        return mod.files.filter { file in
            let lower = file.lowercased()
            return !shared.contains(lower) && !sharedFolders.contains(where: lower.hasPrefix)
        }
    }

    /// Whether a mod has files of its own to turn off, so it can be switched on its own.
    /// Plugins usually sit in `BepInEx/plugins`, but some mods also ship
    /// patchers or files at the game root; those move with the switch too.
    static func canToggle(_ mod: InstalledMod) -> Bool {
        !switchableFiles(mod).isEmpty
    }

    /// Whether a mod's files are where the game loads them.
    static func isEnabled(_ mod: InstalledMod, in gameFolder: URL) -> Bool {
        let files = switchableFiles(mod)
        guard !files.isEmpty else { return true }
        return files.contains { file in
            guard let url = try? resolve(file, in: gameFolder) else { return false }
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
    }

    /// Moves a mod's own files out of the game's folders (off) or back (on).
    /// Nothing is deleted, and the mod stays recorded either way.
    static func setEnabled(_ enabled: Bool, _ mod: InstalledMod, in gameFolder: URL) throws {
        let fileManager = FileManager.default
        for relative in switchableFiles(mod) {
            let live = try resolve(relative, in: gameFolder)
            let parked = try resolve("\(disabledFolder)/\(relative)", in: gameFolder)
            let (source, destination) = enabled ? (parked, live) : (live, parked)
            guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            try makeParent(of: destination)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    /// Whether an unpacked mod is only plugin files (.dll, with optional .pdb
    /// or text), with no loader or game folders of its own.
    static func holdsOnlyPlugins(_ folder: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return false }
        var sawDLL = false
        for case let item as URL in walker {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let name = item.lastPathComponent.lowercased()
            if ["winhttp.dll", "doorstop_config.ini"].contains(name) { return false }
            switch item.pathExtension.lowercased() {
            case "dll": sawDLL = true
            case "pdb", "txt", "md", "xml", "json": continue
            default: return false
            }
        }
        return sawDLL
    }
}
