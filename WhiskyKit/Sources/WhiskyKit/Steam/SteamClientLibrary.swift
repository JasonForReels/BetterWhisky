//
//  SteamClientLibrary.swift
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

/// The owned-games list, read from the Steam client signed in inside a bottle.
///
/// No key and no extra sign-in: once someone signs in to Steam, the client
/// caches library art for every game in the account's library, installed or
/// not, in `appcache/librarycache/<appid>`. Those folders are the list. It is
/// not a documented format, so it is read loosely: any numeric folder or
/// `<appid>_*.jpg` file counts, and installed manifests are always added.
public enum SteamClientLibrary {
    /// What the clients in `bottleURLs` know: owned App IDs, last played
    /// dates, and the names installed manifests carry.
    public struct Snapshot: Sendable {
        public let appIDs: Set<Int>
        public let lastPlayed: [Int: Date]
        public let installedNames: [Int: String]
    }

    public static func snapshot(bottleURLs: [URL]) -> Snapshot {
        var names: [Int: String] = [:]
        for url in bottleURLs {
            for (id, manifest) in SteamInstallService.manifests(bottleURL: url) where names[id] == nil {
                names[id] = manifest.name
            }
        }
        return Snapshot(
            appIDs: ownedAppIDs(bottleURLs: bottleURLs), lastPlayed: lastPlayed(bottleURLs: bottleURLs),
            installedNames: names
        )
    }

    /// A signed-in Steam client is the signal that the list can be read.
    public static func isSignedIn(bottleURL: URL) -> Bool {
        guard let root = SteamLibrary.detectInstall(bottleURL: bottleURL) else { return false }
        return SteamAccount.detectSteamID(bottleURLs: [bottleURL]) != nil
            || !librarycacheAppIDs(steamRoot: root).isEmpty
            || FileManager.default.fileExists(atPath: root.appending(path: "userdata").path(percentEncoded: false))
    }

    /// Every App ID the client knows the account has, across `bottleURLs`.
    public static func ownedAppIDs(bottleURLs: [URL]) -> Set<Int> {
        var ids = Set<Int>()
        for url in bottleURLs {
            guard let root = SteamLibrary.detectInstall(bottleURL: url) else { continue }
            ids.formUnion(librarycacheAppIDs(steamRoot: root))
            ids.formUnion(SteamInstallService.manifests(bottleURL: url).keys)
        }
        return ids.subtracting(SteamLibrary.nonGameAppIds).subtracting([7]) // 7 is the client itself
    }

    static func librarycacheAppIDs(steamRoot: URL) -> Set<Int> {
        let cache = steamRoot.appending(path: "appcache/librarycache")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cache.path(percentEncoded: false))) ?? []
        return Set(names.compactMap(appID(fromCacheName:)))
    }

    /// `620`, `620_header.jpg` and `620_library_600x900.jpg` all mean app 620.
    static func appID(fromCacheName name: String) -> Int? {
        let prefix = name.prefix { $0.isNumber }
        guard !prefix.isEmpty, prefix.count == name.count || name.dropFirst(prefix.count).hasPrefix("_") else {
            return nil
        }
        return Int(prefix).flatMap { $0 > 0 ? $0 : nil }
    }

    /// When the account last played each app, from every signed-in user's
    /// `localconfig.vdf` (Steam's own record, written as it exits a game).
    public static func lastPlayed(bottleURLs: [URL]) -> [Int: Date] {
        var result: [Int: Date] = [:]
        for url in bottleURLs {
            guard let root = SteamLibrary.detectInstall(bottleURL: url) else { continue }
            let userdata = root.appending(path: "userdata")
            let users = (try? FileManager.default.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil))
                ?? []
            for user in users {
                let file = user.appending(path: "config/localconfig.vdf")
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for (appId, date) in lastPlayed(inLocalConfig: text) where date > (result[appId] ?? .distantPast) {
                    result[appId] = date
                }
            }
        }
        return result
    }

    static func lastPlayed(inLocalConfig text: String) -> [Int: Date] {
        guard let root = try? VDFParser.parse(text),
              let apps = root["userlocalconfigstore"]?.objectValue?["software"]?.objectValue?["valve"]?
              .objectValue?["steam"]?.objectValue?["apps"]?.objectValue else { return [:] }
        var result: [Int: Date] = [:]
        for (key, value) in apps {
            guard let appId = Int(key), let seconds = value.objectValue?["lastplayed"]?.intValue, seconds > 0 else {
                continue
            }
            result[appId] = Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        return result
    }
}

/// Names and kinds of Steam apps, from Steam's public store data (no key).
///
/// Cached on disk for good: a game's name rarely changes, and the store
/// endpoint is rate limited.
public actor SteamAppCatalog {
    public struct Info: Codable, Sendable, Equatable {
        public let name: String
        /// "game", "dlc", "demo", "tool", "application", ...
        public let type: String
    }

    public static let shared = SteamAppCatalog()

    private var cache: [Int: Info]
    private let fileURL: URL

    init(fileURL: URL = SteamAppCatalog.defaultFileURL) {
        self.fileURL = fileURL
        let data = try? Data(contentsOf: fileURL)
        let decoded = data.flatMap { try? JSONDecoder().decode([String: Info].self, from: $0) } ?? [:]
        cache = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "BetterWhisky/SteamAppCatalog.json")
    }

    public func cached(_ appId: Int) -> Info? { cache[appId] }

    /// Looks up whatever is missing, a few at a time, then returns everything known.
    public func info(for appIds: Set<Int>, session: URLSession = .shared) async -> [Int: Info] {
        let missing = appIds.filter { cache[$0] == nil }.sorted()
        if !missing.isEmpty {
            await withTaskGroup(of: (Int, Info?).self) { group in
                for (index, appId) in missing.enumerated() {
                    if index >= 4, let (id, info) = await group.next() { store(id, info) }
                    group.addTask { (appId, await Self.fetch(appId, session: session)) }
                }
                for await (id, info) in group { store(id, info) }
            }
            save()
        }
        return cache.filter { appIds.contains($0.key) }
    }

    private func store(_ appId: Int, _ info: Info?) {
        if let info { cache[appId] = info }
    }

    private func save() {
        let encoded = Dictionary(uniqueKeysWithValues: cache.map { (String($0.key), $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    static func fetch(_ appId: Int, session: URLSession) async -> Info? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appId)&filters=basic"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data, appId: appId)
    }

    /// Saves a game's header art to `destination`: the plain store path
    /// first, then the hashed one the store data names for newer games.
    public static func downloadHeader(appId: Int, to destination: URL, session: URLSession = .shared) async {
        func fetch(_ source: URL?) async -> Bool {
            guard let source, let (data, response) = try? await session.data(from: source),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            try? data.write(to: destination, options: .atomic)
            return true
        }
        if await fetch(URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/header.jpg")) { return }
        _ = await fetch(await headerImageURL(appId, session: session))
    }

    /// The store's header image for a game, which carries a hashed path for
    /// newer games where the plain `header.jpg` path no longer resolves.
    public static func headerImageURL(_ appId: Int, session: URLSession = .shared) async -> URL? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appId)&filters=basic"),
              let (data, _) = try? await session.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = (root[String(appId)] as? [String: Any])?["data"] as? [String: Any],
              let header = body["header_image"] as? String else { return nil }
        return URL(string: header)
    }

    static func parse(_ data: Data, appId: Int) -> Info? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[String(appId)] as? [String: Any] else { return nil }
        guard entry["success"] as? Bool == true, let body = entry["data"] as? [String: Any],
              let name = body["name"] as? String else {
            // Delisted or region-locked: still owned, just nameless here.
            return entry["success"] as? Bool == false ? Info(name: "", type: "unknown") : nil
        }
        return Info(name: name, type: body["type"] as? String ?? "game")
    }
}
