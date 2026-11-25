//
//  ModAccountSeedTests.swift
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

@Suite struct ModAccountSeedTests {
    let signedIn = Data(#"{"account":{"loginStatus":1}}"#.utf8)
    let signedOut = Data(#"{"account":{"loginStatus":0}}"#.utf8)

    func makeBottle() throws -> (bottle: URL, saves: URL) {
        let bottle = FileManager.default.temporaryDirectory.appending(path: "Seed-\(UUID().uuidString)")
        let saves = bottle.appending(path: "drive_c/users/crossover/AppData/LocalLow/Innersloth/Among Us")
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        return (bottle, saves)
    }

    @Test func anyModsSaveGetsTheAccount() throws {
        let (bottle, saves) = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        try signedIn.write(to: saves.appending(path: "player.amogus"))
        try Data("{}".utf8).write(to: saves.appending(path: "settings.amogus"))
        // StellarRoles' first start: its settings copy, then a hang as a new player.
        try Data("{}".utf8).write(to: saves.appending(path: "settings.amogus_SR"))
        try signedOut.write(to: saves.appending(path: "player.amogus_XY"))

        #expect(ModAccountPrimer.seedDiscoveredSaves(bottleURL: bottle) == ["_SR", "_XY"])
        #expect(ModAccountPrimer.isSignedIn(saves.appending(path: "player.amogus_SR")))
        #expect(ModAccountPrimer.isSignedIn(saves.appending(path: "player.amogus_XY")))
    }

    @Test func signedInModSaveIsKept() throws {
        let (bottle, saves) = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        try signedIn.write(to: saves.appending(path: "player.amogus"))
        try Data("{}".utf8).write(to: saves.appending(path: "settings.amogus"))
        let own = Data(#"{"account":{"loginStatus":1,"name":"mine"}}"#.utf8)
        try own.write(to: saves.appending(path: "player.amogus_SR"))

        #expect(ModAccountPrimer.seedDiscoveredSaves(bottleURL: bottle).isEmpty)
        #expect(try Data(contentsOf: saves.appending(path: "player.amogus_SR")) == own)
    }

    @Test func nothingHappensBeforeThePlainGameSignsIn() throws {
        let (bottle, saves) = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle) }
        try signedOut.write(to: saves.appending(path: "player.amogus"))
        try Data("{}".utf8).write(to: saves.appending(path: "settings.amogus"))
        try Data("{}".utf8).write(to: saves.appending(path: "settings.amogus_SR"))
        #expect(ModAccountPrimer.seedDiscoveredSaves(bottleURL: bottle).isEmpty)
    }
}
