//
//  SevenZip.swift
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

public enum SevenZipError: LocalizedError {
    case noMacBuild(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noMacBuild(let version): return "7-Zip \(version) has no Mac download."
        case .failed(let message): return "7-Zip couldn't unpack it: \(message)"
        }
    }
}

/// 7-Zip's own command-line tool for macOS, fetched the first time it's needed.
///
/// Installers made with electron-builder (BetterCrewLink's) can't run under
/// Wine: they ask whether the app is already running through PowerShell and
/// `tasklist`, and Wine's versions of those answer yes. 7-Zip opens the
/// installer as an archive instead, so the app inside goes straight into
/// the bottle. It comes from 7-Zip's releases on GitHub, published by its author.
public enum SevenZip {
    static let repo = "ip7z/7zip"

    /// `<Application Support>/Libraries/7-Zip`, next to Wine.
    public static var folder: URL {
        WhiskyWineInstaller.applicationFolder.appending(path: "Libraries/7-Zip")
    }

    public static var tool: URL { folder.appending(path: "7zz") }

    public static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: tool.path(percentEncoded: false))
    }

    /// The Mac build in a release: `7z2606-mac.tar.xz` is Apple silicon,
    /// `-mac-x64` Intel.
    static func macAsset(in assets: [GitHubRelease.Asset], appleSilicon: Bool) -> GitHubRelease.Asset? {
        assets.first { asset in
            let name = asset.name.lowercased()
            guard name.hasSuffix(".tar.xz"), name.contains("-mac") else { return false }
            return appleSilicon ? !name.contains("x64") : name.contains("x64")
        }
    }

    /// The tool, downloading 7-Zip's latest release first if it isn't here yet.
    @discardableResult
    public static func ensureInstalled(session: URLSession = .shared) async throws -> URL {
        if isInstalled { return tool }
        let release = try await GitHubReleases.latestRelease(repo: repo, session: session)
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        guard let asset = macAsset(in: release.assets, appleSilicon: appleSilicon) else {
            throw SevenZipError.noMacBuild(release.tagName)
        }
        let (downloaded, _) = try await session.download(from: asset.browserDownloadURL)
        let work = FileManager.default.temporaryDirectory.appending(path: "BetterWhisky7z-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appending(path: asset.name)
        try FileManager.default.moveItem(at: downloaded, to: archive)
        try await ModInstaller.run("/usr/bin/tar", [
            "-xf", archive.path(percentEncoded: false), "-C", work.path(percentEncoded: false)
        ])
        let unpacked = work.appending(path: "7zz")
        guard FileManager.default.fileExists(atPath: unpacked.path(percentEncoded: false)) else {
            throw SevenZipError.noMacBuild(release.tagName)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: tool)
        try FileManager.default.moveItem(at: unpacked, to: tool)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false)
        )
        return tool
    }

    /// Extracts `archive` (or just `paths` in it) into `destination`.
    public static func extract(_ archive: URL, paths: [String] = [], to destination: URL) async throws {
        let tool = try await ensureInstalled()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try await ModInstaller.run(tool.path(percentEncoded: false), [
                "x", archive.path(percentEncoded: false), "-o" + destination.path(percentEncoded: false), "-y"
            ] + paths)
        } catch ModInstallError.extractFailed(let message) {
            throw SevenZipError.failed(message)
        }
    }
}
