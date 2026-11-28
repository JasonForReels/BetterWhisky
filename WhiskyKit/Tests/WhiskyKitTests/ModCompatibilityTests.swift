//
//  ModCompatibilityTests.swift
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

@Suite struct ModCompatibilityTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "ModCompat-\(UUID().uuidString)")
    let tou = "AU-Avengers/TOU-Mira"

    /// A stand-in DLL whose version resource says `version`.
    static func dll(_ version: PEVersion, tag: String = "") -> Data {
        var bytes: [UInt8] = Array("MZ fake \(tag)".utf8) + [0xBD, 0x04, 0xEF, 0xFE, 0x00, 0x00, 0x01, 0x00]
        func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
        bytes += word(version.minor) + word(version.major) + word(version.revision) + word(version.build)
        return Data(bytes)
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// A Town of Us profile: BepInEx 6.0.0 and Reactor 2.3.1 among its plugins.
    @Test func changingAModsVersionKeepsItsOwnPlugin() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try makeProfile()
        let repo = "someone/Mira-NotePad"
        func install(_ version: PEVersion, tag: String) throws -> InstalledMod {
            let staged = try stage(["BepInEx/plugins/NotePad.dll": Self.dll(version, tag: tag)])
            let report = ModCompatibility.check(name: "Mira-NotePad", repo: repo, staged: staged, profile: profile)
            #expect(!report.skipped.contains("BepInEx/plugins/NotePad.dll"))
            return try ModInstaller.installStaged(
                staged, version: tag, name: "Mira-NotePad", repo: repo,
                rule: ModInstallRule(mode: .extract), gameExecutable: profile.appending(path: "Among Us.exe"),
                gameFolder: profile, skipping: report.skipped
            ).mod
        }
        _ = try install(PEVersion(1, 4, 6), tag: "v1.4.6")
        // An older release, then the same one again: both still bring the plugin and its switch.
        for (version, tag) in [(PEVersion(1, 4, 5), "v1.4.5"), (PEVersion(1, 4, 5), "v1.4.5")] {
            let mod = try install(version, tag: tag)
            #expect(mod.files == ["BepInEx/plugins/NotePad.dll"])
            #expect(ModInstaller.canToggle(mod))
            #expect(FileManager.default.fileExists(
                atPath: profile.appending(path: "BepInEx/plugins/NotePad.dll").path(percentEncoded: false)
            ))
        }
    }

    func makeProfile() throws -> URL {
        let profile = root.appending(path: "Among Us Mods/Town of Us- Mira/game")
        try write(Self.dll(PEVersion(6, 0, 0)), to: profile.appending(path: "BepInEx/core/BepInEx.Core.dll"))
        try write(Self.dll(PEVersion(2, 3, 1)), to: profile.appending(path: "BepInEx/plugins/Reactor.dll"))
        try write(Self.dll(PEVersion(1, 7, 9)), to: profile.appending(path: "BepInEx/plugins/TownOfUsMira.dll"))
        try write(Data("cfg".utf8), to: profile.appending(path: "BepInEx/config/tou.cfg"))
        try Data("2026.9.29".utf8).write(to: profile.appending(path: ".betterwhisky-game-version"))
        let mod = InstalledMod(
            name: "Town of Us: Mira", repo: tou, version: "1.7.9", installedAt: Date(),
            files: [
                "BepInEx/core/BepInEx.Core.dll", "BepInEx/plugins/Reactor.dll",
                "BepInEx/plugins/TownOfUsMira.dll", "BepInEx/config/tou.cfg"
            ]
        )
        try ModInstaller.writeManifest([mod], to: profile)
        return profile
    }

    /// A mod unpacked as it lands in the game folder, from `files` (game path → contents).
    func stage(_ files: [String: Data]) throws -> StagedMod {
        let work = root.appending(path: "staged-\(UUID().uuidString)")
        let source = work.appending(path: "unpacked")
        for (path, data) in files { try write(data, to: source.appending(path: path)) }
        return StagedMod(work: work, source: source, prefix: "")
    }

    func severities(_ report: ModCompatibilityReport) -> [ModCompatibilityReport.Severity] {
        report.findings.map(\.severity)
    }

    @Test func readsTheFileVersionOutOfADLL() {
        #expect(PEVersion.fileVersion(in: Self.dll(PEVersion(2, 5, 1, 7))) == PEVersion(2, 5, 1, 7))
        #expect(PEVersion.fileVersion(in: Data("no version here".utf8)) == nil)
        #expect(PEVersion(2, 5, 1) > PEVersion(2, 3, 9))
        #expect(PEVersion(2, 5, 1).description == "2.5.1")
    }

    @Test func aSharedLibraryAtTheSameVersionKeepsTheOneThere() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try makeProfile()
        let staged = try stage([
            "BepInEx/plugins/Reactor.dll": Self.dll(PEVersion(2, 3, 1)),
            "BepInEx/plugins/LevelImposter.dll": Self.dll(PEVersion(1, 0, 2))
        ])
        let report = ModCompatibility.check(
            name: "LevelImposter", repo: "DigiWorm0/LevelImposter", staged: staged, profile: profile
        )
        #expect(report.canInstall)
        #expect(report.worst == .info)
        #expect(report.skipped.contains("BepInEx/plugins/Reactor.dll"))
        #expect(!report.skipped.contains("BepInEx/plugins/LevelImposter.dll"))
    }

    @Test func aSharedLibraryAMajorVersionApartBlocks() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try makeProfile()
        let staged = try stage(["BepInEx/plugins/Reactor.dll": Self.dll(PEVersion(1, 9, 0))])
        let report = ModCompatibility.check(name: "Old Mod", repo: "someone/old", staged: staged, profile: profile)
        #expect(!report.canInstall)
        #expect(report.findings.contains { $0.message.contains("Town of Us: Mira uses Reactor 2.3.1") })
    }

    @Test func aNewerSharedLibraryIsAWarningAndAnOlderOneIsLeftOut() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try makeProfile()
        let newer = ModCompatibility.check(
            name: "New Mod", repo: "someone/new",
            staged: try stage(["BepInEx/plugins/Reactor.dll": Self.dll(PEVersion(2, 5, 1))]), profile: profile
        )
        #expect(newer.canInstall)
        #expect(newer.worst == .warning)
        #expect(!newer.skipped.contains("BepInEx/plugins/Reactor.dll"))

        let older = ModCompatibility.check(
            name: "Older Mod", repo: "someone/older",
            staged: try stage(["BepInEx/plugins/Reactor.dll": Self.dll(PEVersion(2, 1, 0))]), profile: profile
        )
        #expect(older.worst == .info)
        #expect(older.skipped.contains("BepInEx/plugins/Reactor.dll"))
    }

    @Test func theProfileKeepsItsOwnLoader() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try makeProfile()
        let staged = try stage([
            "winhttp.dll": Data("loader".utf8),
            "BepInEx/core/BepInEx.Core.dll": Self.dll(PEVersion(6, 0, 1), tag: "theirs"),
            "BepInEx/plugins/Extra.dll": Self.dll(PEVersion(1, 0, 0))
        ])
        let report = ModCompatibility.check(name: "Extra", repo: "someone/extra", staged: staged, profile: profile)
        #expect(report.canInstall)
        #expect(report.skipped.isSuperset(of: ["winhttp.dll", "BepInEx/core/BepInEx.Core.dll"]))

        let otherMajor = ModCompatibility.check(
            name: "Extra", repo: "someone/extra",
            staged: try stage(["BepInEx/core/BepInEx.Core.dll": Self.dll(PEVersion(5, 4, 0))]), profile: profile
        )
        #expect(!otherMajor.canInstall)
    }

    @Test func modsAPresetSaysCantShareAreBlockedEitherWayRound() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try makeProfile()
        let staged = try stage(["BepInEx/plugins/TheOtherRoles.dll": Self.dll(PEVersion(4, 8, 0))])
        let report = ModCompatibility.check(
            name: "The Other Roles", repo: "TheOtherRolesAU/TheOtherRoles", staged: staged, profile: profile
        )
        #expect(!report.canInstall)
        #expect(report.findings.contains { $0.message.contains("both replace the game's roles") })
    }

    @Test func overwritingAnotherModsFilesIsAWarning() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try makeProfile()
        let staged = try stage(["BepInEx/config/tou.cfg": Data("mine".utf8)])
        let report = ModCompatibility.check(name: "Tweaks", repo: "someone/tweaks", staged: staged, profile: profile)
        #expect(severities(report) == [.warning])
        #expect(report.findings.first?.message.contains("Town of Us: Mira's tou.cfg") == true)
    }

    @Test func aModForAnotherGameVersionIsBlocked() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try makeProfile()
        let staged = try stage(["BepInEx/plugins/Extra.dll": Self.dll(PEVersion(1, 0, 0))])
        let report = ModCompatibility.check(
            name: "Extra", repo: "someone/extra", staged: staged, profile: profile, requiredGameVersion: "2025.5.20"
        )
        #expect(!report.canInstall)
    }

    @Test func installingSkipsWhatTheCheckLeftOut() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try makeProfile()
        let staged = try stage([
            "winhttp.dll": Data("loader".utf8),
            "BepInEx/plugins/Reactor.dll": Self.dll(PEVersion(2, 3, 1)),
            "BepInEx/plugins/LevelImposter.dll": Self.dll(PEVersion(1, 0, 2))
        ])
        let report = ModCompatibility.check(
            name: "LevelImposter", repo: "DigiWorm0/LevelImposter", staged: staged, profile: profile
        )
        let result = try ModInstaller.installStaged(
            staged, version: "v1.0.2", name: "LevelImposter", repo: "DigiWorm0/LevelImposter",
            rule: ModInstallRule(mode: .extract), gameExecutable: profile.appending(path: "Among Us.exe"),
            gameFolder: profile, skipping: report.skipped
        )
        #expect(result.mod.files == ["BepInEx/plugins/LevelImposter.dll"])
        #expect(ModInstaller.installedMods(in: profile).map(\.repo) == [tou, "DigiWorm0/LevelImposter"])
        // Removing it leaves Town of Us's Reactor where it was.
        try ModInstaller.uninstall(result.mod, from: profile)
        #expect(FileManager.default.fileExists(
            atPath: profile.appending(path: "BepInEx/plugins/Reactor.dll").path(percentEncoded: false)
        ))
    }

    @Test func picksSevenZipsMacBuildForThisChip() throws {
        let url = try #require(URL(string: "https://example.com/x"))
        let assets = ["7z2606-mac.tar.xz", "7z2606-mac-x64.tar.xz", "7z2606-linux-x64.tar.xz", "7z2606-x64.exe"]
            .map { GitHubRelease.Asset(name: $0, size: 1, browserDownloadURL: url) }
        #expect(SevenZip.macAsset(in: assets, appleSilicon: true)?.name == "7z2606-mac.tar.xz")
        #expect(SevenZip.macAsset(in: assets, appleSilicon: false)?.name == "7z2606-mac-x64.tar.xz")
    }

    @Test func betterCrewLinkRunsNextToTheGameWithItsFlags() throws {
        let companion = try #require(ModCompanion.companions(steamAppId: 945360).first)
        #expect(companion.name == "BetterCrewLink")
        #expect(companion.launchArguments.contains("--in-process-gpu"))
        #expect(ModCompanion.companions(steamAppId: nil).isEmpty)
    }

    @Test func removingACompanionTakesOnlyItsOwnFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let companion = try #require(ModCompanion.companions(steamAppId: 945360).first)
        let programFiles = root.appending(path: "drive_c/Program Files")
        try write(Data("exe".utf8), to: programFiles.appending(path: "Better-CrewLink/Better-CrewLink.exe"))
        try write(Data("other".utf8), to: programFiles.appending(path: "Steam/steam.exe"))
        let defaults = try #require(UserDefaults(suiteName: "companion-\(UUID().uuidString)"))
        companion.setStartsWithGame(false, bottleURL: root, defaults: defaults)

        #expect(companion.installedExecutable(bottleURL: root) != nil)
        try companion.uninstall(bottleURL: root, defaults: defaults)
        #expect(companion.installedExecutable(bottleURL: root) == nil)
        #expect(FileManager.default.fileExists(atPath: programFiles.appending(path: "Steam/steam.exe").path))
        #expect(companion.startsWithGame(bottleURL: root, defaults: defaults))
    }

    @Test func roleModsAreRecognised() {
        #expect(ModCompatibility.isRoleMod(name: "Town of Us: Mira", repo: "AU-Avengers/TOU-Mira"))
        #expect(ModCompatibility.isRoleMod(name: "StellarRoles", repo: "local/StellarRoles"))
        #expect(ModCompatibility.isRoleMod(name: "The Other Roles", repo: "TheOtherRolesAU/TheOtherRoles"))
        #expect(!ModCompatibility.isRoleMod(name: "LevelImposter", repo: "DigiWorm0/LevelImposter"))
        #expect(!ModCompatibility.isRoleMod(name: "Reactor", repo: "NuclearPowered/Reactor"))
    }

    @Test func readingFilesAreTold() {
        #expect(ModCompatibility.isReadingFile("changelog.txt"))
        #expect(ModCompatibility.isReadingFile("BepInEx/patchers/Splash/README.md"))
        #expect(ModCompatibility.isReadingFile("LICENSE"))
        #expect(!ModCompatibility.isReadingFile("BepInEx/config/gg.reactor.api.cfg"))
        #expect(!ModCompatibility.isReadingFile("BepInEx/plugins/Mod.dll"))
    }
}
