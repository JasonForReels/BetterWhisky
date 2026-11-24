//
//  SteamOwnedLibraryTests.swift
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
import Testing
@testable import WhiskyKit

@Suite("Steam owned library")
struct SteamOwnedLibraryTests {
    @Test func parsesOwnedGames() throws {
        let json = """
        {"response":{"game_count":3,"games":[
          {"appid":945360,"name":"Among Us","playtime_forever":600,"rtime_last_played":1760000000},
          {"appid":620,"name":"Portal 2","playtime_forever":0,"rtime_last_played":0},
          {"appid":228980,"name":"Steamworks Common Redistributables"}
        ]}}
        """
        let games = try SteamWebAPI.parseOwnedGames(Data(json.utf8))
        #expect(games.map(\.appId) == [945_360, 620])
        #expect(games[0].lastPlayed == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(games[1].lastPlayed == nil)
    }

    @Test func privateProfileIsReported() {
        #expect(throws: SteamWebAPIError.privateProfile) {
            try SteamWebAPI.parseOwnedGames(Data(#"{"response":{}}"#.utf8))
        }
    }

    @Test func readsMostRecentAccount() {
        let text = """
        "users"
        {
            "76561197960287930" { "AccountName" "a" "MostRecent" "0" }
            "76561197960287931" { "AccountName" "b" "MostRecent" "1" }
        }
        """
        #expect(SteamAccount.steamID(inLoginUsers: text) == "76561197960287931")
        #expect(SteamAccount.normalizedSteamID(" 76561197960287931 ") == "76561197960287931")
        #expect(SteamAccount.normalizedSteamID("gabe") == nil)
    }

    @Test func stubManifestQueuesAnInstallSteamCanRead() throws {
        let text = SteamInstallService.stubManifest(appId: 620, name: "Portal 2")
        let state = try #require(try VDFParser.parse(text)["appstate"]?.objectValue)
        #expect(state["appid"]?.intValue == 620)
        #expect(state["stateflags"]?.intValue == SteamInstallService.queuedStateFlags)
        #expect(state["installdir"]?.stringValue == "Portal 2")
        #expect(SteamInstallService.installDirectoryName(for: "../..", appId: 7) == "App 7")
    }

    @Test func statusFollowsTheManifest() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func manifest(flags: Int, total: Int, done: Int) throws -> SteamAppManifest {
            let url = folder.appending(path: "appmanifest_620.acf")
            try """
            "AppState" { "appid" "620" "name" "Portal 2" "installdir" "Portal 2" "StateFlags" "\(flags)"
              "BytesToDownload" "\(total)" "BytesDownloaded" "\(done)" "SizeOnDisk" "1000" }
            """.write(to: url, atomically: true, encoding: .utf8)
            return try #require(SteamAppManifest(contentsOf: url))
        }

        #expect(SteamInstallService.status(appId: 620, manifests: [:]) == .notInstalled)
        let downloading = try manifest(flags: 1026, total: 200, done: 50)
        #expect(SteamInstallService.status(appId: 620, manifests: [620: downloading]) == .installing(fraction: 0.25))
        let installed = try manifest(flags: 4, total: 0, done: 0)
        #expect(SteamInstallService.status(appId: 620, manifests: [620: installed])
            == .installed(sizeOnDisk: 1000, lastPlayed: nil))
    }
}

@Suite("Steam client library")
struct SteamClientLibraryTests {
    @Test func readsAppIDsFromCacheNames() {
        #expect(SteamClientLibrary.appID(fromCacheName: "620") == 620)
        #expect(SteamClientLibrary.appID(fromCacheName: "945360_header.jpg") == 945_360)
        #expect(SteamClientLibrary.appID(fromCacheName: "620x.jpg") == nil)
        #expect(SteamClientLibrary.appID(fromCacheName: ".DS_Store") == nil)
    }

    @Test func readsLastPlayedFromLocalConfig() {
        let text = """
        "UserLocalConfigStore" { "Software" { "Valve" { "Steam" { "apps" {
            "620" { "LastPlayed" "1760000000" }
            "945360" { "LastPlayed" "0" }
        } } } } }
        """
        let expected = [620: Date(timeIntervalSince1970: 1_760_000_000)]
        #expect(SteamClientLibrary.lastPlayed(inLocalConfig: text) == expected)
    }

    @Test func parsesStoreData() {
        let found = Data(#"{"620":{"success":true,"data":{"type":"game","name":"Portal 2"}}}"#.utf8)
        #expect(SteamAppCatalog.parse(found, appId: 620) == .init(name: "Portal 2", type: "game"))
        let gone = Data(#"{"1":{"success":false}}"#.utf8)
        #expect(SteamAppCatalog.parse(gone, appId: 1)?.name == "")
    }
}

@Suite("Steam background uninstall")
struct SteamBackgroundUninstallTests {
    @Test func removesOnlyTheGamesOwnFiles() throws {
        let library = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: library) }
        let apps = library.appending(path: "steamapps")
        let game = apps.appending(path: "common/Untrusted")
        let other = apps.appending(path: "common/Other Game")
        let saves = library.appending(path: "userdata/1/1502660")
        for folder in [game, other, saves, apps.appending(path: "shadercache/1502660")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: game.appending(path: "Untrusted.exe"))
        let manifest = apps.appending(path: "appmanifest_1502660.acf")
        try """
        "AppState" { "appid" "1502660" "name" "Untrusted" "installdir" "Untrusted" "StateFlags" "4" }
        """.write(to: manifest, atomically: true, encoding: .utf8)

        try SteamInstallService.removeInstall(appId: 1_502_660, library: library)

        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
        #expect(!exists(game))
        #expect(!exists(manifest))
        #expect(!exists(apps.appending(path: "shadercache/1502660")))
        #expect(exists(other))
        #expect(exists(saves))
    }

    @Test func refusesAnEscapingInstallDir() throws {
        let library = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: library) }
        let apps = library.appending(path: "steamapps")
        let outside = library.appending(path: "keep")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try """
        "AppState" { "appid" "5" "name" "Bad" "installdir" "../../keep" "StateFlags" "4" }
        """.write(to: apps.appending(path: "appmanifest_5.acf"), atomically: true, encoding: .utf8)

        try SteamInstallService.removeInstall(appId: 5, library: library)
        #expect(FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
    }
}

@Suite("Mod account primer")
struct ModAccountPrimerTests {
    let save = ModAccountSave.amongUs(suffix: "_TOUMira")

    func account(_ status: Int, name: String) -> String {
        "{\r\n  \"account\": {\r\n    \"loginStatus\": \(status)\r\n  },\r\n  \"name\": \"\(name)\"\r\n}"
    }

    /// A bottle with a Windows user and the game's save folder.
    func makeBottle() throws -> (bottle: URL, folder: URL) {
        let bottle = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: bottle.appending(path: "drive_c/users/Public"), withIntermediateDirectories: true
        )
        let folder = bottle.appending(path: "drive_c/users/crossover/AppData/LocalLow/Innersloth/Among Us")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (bottle, folder)
    }

    @Test func findsTheSaveFolder() throws {
        let (bottle, folder) = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        #expect(ModAccountPrimer.saveFolder(save, bottleURL: bottle)?.standardizedFileURL
            == folder.standardizedFileURL)
    }

    @Test func plainSaveMustBeSignedIn() throws {
        let (bottle, folder) = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        #expect(!ModAccountPrimer.plainSaveReady(save, in: folder))
        try account(0, name: "plain")
            .write(to: folder.appending(path: "player.amogus"), atomically: true, encoding: .utf8)
        try "{}".write(to: folder.appending(path: "settings.amogus"), atomically: true, encoding: .utf8)
        #expect(!ModAccountPrimer.plainSaveReady(save, in: folder))
        try account(1, name: "plain")
            .write(to: folder.appending(path: "player.amogus"), atomically: true, encoding: .utf8)
        #expect(ModAccountPrimer.plainSaveReady(save, in: folder))
    }

    @Test func replacesASignedOutModSaveButKeepsAGoodOne() throws {
        let (bottle, folder) = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        try account(1, name: "plain")
            .write(to: folder.appending(path: "player.amogus"), atomically: true, encoding: .utf8)
        try "{}".write(to: folder.appending(path: "settings.amogus"), atomically: true, encoding: .utf8)
        let modPlayer = folder.appending(path: "player.amogus_TOUMira")
        try account(0, name: "failed").write(to: modPlayer, atomically: true, encoding: .utf8)

        try ModAccountPrimer.seedModSave(save, in: folder)
        #expect(try String(contentsOf: modPlayer, encoding: .utf8).contains("plain"))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "settings.amogus_TOUMira").path))

        try account(1, name: "mod").write(to: modPlayer, atomically: true, encoding: .utf8)
        try ModAccountPrimer.seedModSave(save, in: folder)
        #expect(try String(contentsOf: modPlayer, encoding: .utf8).contains("mod"))
    }

    @Test func townOfUsHasItsSaveSuffix() {
        #expect(ModPreset.named("Town of Us: Mira")?.accountSave?.suffix == "_TOUMira")
        #expect(ModPreset.named("LevelImposter")?.accountSave == nil)
    }
}
