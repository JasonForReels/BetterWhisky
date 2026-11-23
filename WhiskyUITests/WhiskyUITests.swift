//
//  WhiskyUITests.swift
//  WhiskyUITests
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

import XCTest

final class WhiskyUITests: WhiskyUITestCase {
    func testAppLaunchesAndShowsBottleDetail() throws {
        try requireBottleFixture()
        require(app.buttons["nav.bottleConfiguration"], "bottle nav row", timeout: 8)
        XCTAssertTrue(app.buttons["nav.installedPrograms"].exists)
        XCTAssertTrue(app.buttons["nav.runningProcesses"].exists)
        XCTAssertTrue(app.buttons["nav.gameConfigurations"].exists)
    }

    func testToolbarShowsBottleActions() throws {
        try requireBottleFixture()
        // Run is the bottle's one prominent toolbar button; the rest live in More.
        XCTAssertTrue(
            app.buttons.matching(identifier: "bottle.runProgram").firstMatch.exists,
            "Run toolbar button missing"
        )
        let more = require(app.menuButtons["More"], "More toolbar menu", timeout: 5)
        more.click()
        XCTAssertTrue(app.menuItems["Open C: Drive"].waitForExistence(timeout: 3), "Open C: Drive missing")
        XCTAssertTrue(app.menuItems["Terminal..."].exists, "Terminal missing")
        XCTAssertTrue(app.menuItems["Winetricks..."].exists, "Winetricks missing")
        XCTAssertTrue(app.menuItems["Duplicate Bottle..."].exists, "Duplicate Bottle missing")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testTabBarSwitchesPages() throws {
        try requireBottleFixture()
        openTab("Search")
        XCTAssertTrue(
            app.textFields.matching(identifier: "search.field").firstMatch.waitForExistence(timeout: 5),
            "Search tab did not show its search field"
        )
        openTab("Library")
        // Coming back to Bottles returns to the bottle that was open.
        openBottlesTab()
        XCTAssertTrue(
            app.buttons["nav.bottleConfiguration"].waitForExistence(timeout: 5),
            "Bottles tab did not return to the open bottle"
        )
    }

    func testCreateBottleButtonPresentInToolbar() throws {
        try requireBottleFixture()
        XCTAssertTrue(
            app.buttons.matching(identifier: "toolbar.createBottle").firstMatch.exists,
            "+ toolbar button missing"
        )
    }

    // MARK: - Bottle Configuration

    func testBottleConfigurationSectionsRender() throws {
        try requireBottleFixture()
        openBottleConfigurationList()
        for page in Self.configPages {
            XCTAssertTrue(app.buttons["config.page.\(page)"].exists, "\(page) row missing from Configuration")
        }
        openConfigPage("general")
        XCTAssertTrue(app.staticTexts["Wine"].waitForExistence(timeout: 5), "General page has no Wine section")
    }

    /// The Controllers & Input page shows the controller settings.
    func testControllerAndInputSectionExists() throws {
        try requireBottleFixture()
        openBottleConfigurationList()
        openConfigPage("input")
        let controller = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Controller'"))
            .firstMatch
        XCTAssertTrue(controller.waitForExistence(timeout: 5), "Controllers & Input page has no controller settings")
    }

    // MARK: - Game Configurations browser
}
