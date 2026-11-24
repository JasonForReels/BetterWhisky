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
/// `<Game> Mods/<Profile>/game` folder with its own main mod and add-ons.
/// The first one is made by installing the mod; more are clones of an
/// existing one (on APFS a clone shares storage until either side changes).
public enum ModProfiles {
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

    /// Whether a mod has files BepInEx loads as plugins, so it can be turned off on its own.
    static func canToggle(_ mod: InstalledMod) -> Bool {
        mod.files.contains { $0.lowercased().hasPrefix("bepinex/plugins/") }
    }

    /// Whether a mod's plugins are where BepInEx loads them.
    static func isEnabled(_ mod: InstalledMod, in gameFolder: URL) -> Bool {
        guard let file = mod.files.first(where: { $0.lowercased().hasPrefix("bepinex/plugins/") }) else {
            return true
        }
        return FileManager.default.fileExists(
            atPath: gameFolder.appending(path: file).path(percentEncoded: false)
        )
    }

    /// Moves a mod's plugin files out of `BepInEx/plugins` (off) or back (on).
    /// Nothing is deleted, and the mod stays recorded either way.
    static func setEnabled(_ enabled: Bool, _ mod: InstalledMod, in gameFolder: URL) throws {
        let fileManager = FileManager.default
        for relative in mod.files where relative.lowercased().hasPrefix("bepinex/plugins/") {
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
