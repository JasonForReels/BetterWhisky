//
//  ModProfilesTests.swift
//  WhiskyKitTests
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
import Testing
@testable import WhiskyKit

@Suite struct ModProfilesTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "ModProfiles-\(UUID().uuidString)")

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    /// `<root>/Among Us Mods/Town of Us/game` with BepInEx and one add-on plugin.
    func makeProfile() async throws -> (copy: URL, addOn: InstalledMod) {
        let copy = root.appending(path: "Among Us Mods/Town of Us/game")
        try FileManager.default.createDirectory(
            at: copy.appending(path: "BepInEx/plugins"), withIntermediateDirectories: true
        )
        let dll = root.appending(path: "Extension.dll")
        try Data("dll".utf8).write(to: dll)
        let result = try await ModInstaller.installLocal(
            file: dll, rule: ModInstallRule(mode: .copyFile, subpath: "BepInEx/plugins"),
            gameExecutable: copy.appending(path: "Among Us.exe")
        )
        return (copy, result.mod)
    }

    @Test func turningAnAddOnOffParksItAndOnBringsItBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (copy, mod) = try await makeProfile()
        let live = copy.appending(path: "BepInEx/plugins/Extension.dll")
        #expect(ModInstaller.canToggle(mod))
        #expect(ModInstaller.isEnabled(mod, in: copy))

        try ModInstaller.setEnabled(false, mod, in: copy)
        #expect(!exists(live))
        #expect(!ModInstaller.isEnabled(mod, in: copy))
        #expect(ModInstaller.installedMods(in: copy).contains { $0.repo == mod.repo })

        try ModInstaller.setEnabled(true, mod, in: copy)
        #expect(exists(live))
        #expect(ModInstaller.isEnabled(mod, in: copy))
    }

    @Test func removingATurnedOffAddOnLeavesNothingBehind() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (copy, mod) = try await makeProfile()
        try ModInstaller.setEnabled(false, mod, in: copy)
        try ModInstaller.uninstall(mod, from: copy)
        #expect(!exists(copy.appending(path: "\(ModInstaller.disabledFolder)/BepInEx/plugins/Extension.dll")))
        #expect(ModInstaller.installedMods(in: copy).isEmpty)
    }

    @Test func duplicateAndRenameMakeIndependentProfiles() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (copy, mod) = try await makeProfile()
        let second = try ModProfiles.duplicate(copy, as: "Chaos")
        #expect(second.path.hasSuffix("Among Us Mods/Chaos/game"))
        #expect(ModProfiles.displayName(of: second, modName: "Town of Us") == "Chaos")
        #expect(ModProfiles.displayName(of: copy, modName: "Town of Us") == "Town of Us")

        // Turning the add-on off in one profile leaves the other alone.
        try ModInstaller.setEnabled(false, mod, in: second)
        #expect(ModInstaller.isEnabled(mod, in: copy))

        #expect(throws: ModProfileError.self) { try ModProfiles.duplicate(copy, as: "Chaos") }
        #expect(throws: ModProfileError.self) { try ModProfiles.rename(copy, to: "  ") }
        let renamed = try ModProfiles.rename(second, to: "Casual")
        #expect(exists(renamed) && !exists(second))
    }

    @Test func installIntoANamedProfile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appending(path: "Among Us")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try Data().write(to: game.appending(path: "Among Us.exe"))
        let dll = root.appending(path: "Mod.dll")
        try Data("dll".utf8).write(to: dll)
        let result = try await ModInstaller.installFile(
            dll, version: "v1", name: "Town of Us", repo: "x/tou",
            rule: ModInstallRule(mode: .copyFile, frozenCopy: true),
            gameExecutable: game.appending(path: "Among Us.exe"), profile: "Chaos"
        )
        #expect(result.gameFolder.path.hasSuffix("Among Us Mods/Chaos/game"))
    }

    @Test func emptyProfileIsListedAndRemovable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ModEmpty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appending(path: "Among Us")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try Data().write(to: game.appending(path: "Among Us.exe"))

        let copy = try ModProfiles.create("Stellar Night", game: game)
        let exe = copy.appending(path: "Among Us.exe").path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: exe))
        #expect(ModInstaller.installedModFolders(forGame: game).map(\.name) == ["Stellar Night"])
        #expect(throws: ModProfileError.self) { try ModProfiles.create("Stellar Night", game: game) }
    }
}
