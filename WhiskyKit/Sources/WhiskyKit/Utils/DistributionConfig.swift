//
//  DistributionConfig.swift
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

public enum DistributionConfig {
    /// BetterWhisky's home: the Help menu's links and where releases are published.
    public static let siteURL = "https://github.com/JasonForReels/BetterWhisky"

    /// Where people report problems.
    public static let issuesURL = "\(siteURL)/issues"

    /// Base URL for the Wine engine feeds.
    ///
    /// BetterWhisky uses the Wine engine frankea/Whisky builds and hosts, so
    /// engine downloads stay there; only the app itself is released from
    /// BetterWhisky's repository.
    public static let baseURL = "https://frankea.github.io/Whisky"

    /// URL for the WhiskyWine version plist file, which names the engine to
    /// install and offers as an update.
    ///
    /// Apps before 3.10.0 read `WhiskyWineVersion.plist`, which stays on the
    /// stock 3.1.1 engine: the GPTK-capable engine was tested with 3.10.0 and
    /// its D3DMetal, DLL override and environment fixes, so older apps are not
    /// offered an engine switch nobody tested them with. This feed is the one
    /// that moves.
    public static let versionPlistURL = "\(baseURL)/WhiskyWineVersion-v4.plist"

    /// The feed apps before 3.10.0 read, frozen on the stock 3.1.1 engine.
    static let legacyVersionPlistURL = "\(baseURL)/WhiskyWineVersion.plist"

    /// BetterWhisky's releases page, which lists app releases.
    public static let releasesPageURL = "\(siteURL)/releases"

    /// The releases page for the Wine engine builds BetterWhisky installs.
    public static let engineReleasesPageURL = "https://github.com/frankea/Whisky/releases"

    /// Base URL for Wine engine downloads.
    public static let releasesBaseURL = "\(engineReleasesPageURL)/download"

    /// The in-app updater's feed (also set as SUFeedURL in Info.plist).
    public static let appcastURL = "https://raw.githubusercontent.com/JasonForReels/BetterWhisky/main/appcast.xml"

    /// Constructs the download URL for Wine Libraries from GitHub Releases
    /// - Parameter version: The version string (e.g., "2.5.0")
    /// - Returns: The full URL to download Libraries.tar.gz from GitHub Releases
    public static func librariesURL(version: String) -> String {
        "\(releasesBaseURL)/v\(version)/Libraries.tar.gz"
    }
}
