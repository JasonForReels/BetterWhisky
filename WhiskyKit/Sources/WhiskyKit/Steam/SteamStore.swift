//
//  SteamStore.swift
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

/// A game as a store list shows it: enough for a tile.
public struct StoreListing: Identifiable, Hashable, Sendable {
    public var id: Int { appId }
    public let appId: Int
    public let name: String
    /// The formatted price, such as "$19.99", or nil when free or unknown.
    public let price: String?
    /// Percent off, 0 when not on sale.
    public let discountPercent: Int
    public let isFree: Bool
    private let knownHeaderURL: URL?

    public init(
        appId: Int, name: String, price: String?, discountPercent: Int = 0, isFree: Bool = false,
        headerURL: URL? = nil
    ) {
        self.appId = appId
        self.name = name
        self.price = price
        self.discountPercent = discountPercent
        self.isFree = isFree
        knownHeaderURL = headerURL
    }

    /// Steam's wide header art.
    public var headerURL: URL { knownHeaderURL ?? SteamStore.headerURL(appId: appId) }
    /// Steam's portrait library art, which not every game has.
    public var posterURL: URL { SteamStore.posterURL(appId: appId) }
}

/// A game's art, at the addresses Steam actually serves it from.
public struct StoreArtwork: Hashable, Sendable {
    /// 3840x1240 library hero, falling back to the 1920 one.
    public var hero: URL?
    public var header: URL?

    public init(hero: URL? = nil, header: URL? = nil) {
        self.hero = hero
        self.header = header
    }
}

/// Everything the store page knows about a game.
public struct GameMetadata: Identifiable, Hashable, Sendable, Codable {
    public var id: Int { appId }
    public let appId: Int
    public let name: String
    public let shortDescription: String
    public let developers: [String]
    public let publishers: [String]
    public let genres: [String]
    public let releaseDate: String?
    public let comingSoon: Bool
    public let metacritic: Int?
    public let isFree: Bool
    /// The formatted price before any discount, such as "$29.99".
    public let initialPrice: String?
    /// The formatted price now.
    public let finalPrice: String?
    public let discountPercent: Int
    public let windows: Bool
    public let mac: Bool
    public let screenshots: [URL]
    public let headerURL: URL
    public let website: URL?

    public var storeURL: URL { SteamStore.storePageURL(appId: appId) }

    /// What the buy button says.
    public var priceLabel: String {
        if isFree { return "Free" }
        if comingSoon, finalPrice == nil { return "Coming Soon" }
        return finalPrice ?? "See Price"
    }
}

public enum SteamStoreError: LocalizedError, Equatable {
    case http(Int)
    case notFound
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case let .http(code): "The Steam Store answered with an error (\(code))."
        case .notFound: "The Steam Store has no page for this game."
        case .malformedResponse: "The Steam Store's answer couldn't be read."
        }
    }
}

/// Steam's public storefront endpoints, the ones its own store pages use.
///
/// None of them need an account or a key. Purchases are not made here: the
/// buy button hands the game to the Steam client in a bottle (or the store
/// website), so checkout, payment details and the receipt stay with Steam.
public actor SteamStore {
    public static let shared = SteamStore()

    private let session: URLSession
    private var metadataCache: [Int: GameMetadata] = [:]
    private let diskCache: URL?

    public init(session: URLSession = .shared) {
        self.session = session
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        diskCache = caches?.appending(path: "com.franke.Whisky/StoreMetadata", directoryHint: .isDirectory)
        if let diskCache {
            try? FileManager.default.createDirectory(at: diskCache, withIntermediateDirectories: true)
        }
    }

    // MARK: URLs

    // swiftlint:disable force_unwrapping
    public static func headerURL(appId: Int) -> URL {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/header.jpg")!
    }

    public static func posterURL(appId: Int) -> URL {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/library_600x900.jpg")!
    }

    /// Wide 1920x620 key art from the Steam library, when the game has it.
    public static func heroURL(appId: Int) -> URL {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/library_hero.jpg")!
    }

    /// The game's transparent logo, when it has one.
    public static func logoURL(appId: Int) -> URL {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/logo.png")!
    }

    public static func storePageURL(appId: Int) -> URL {
        URL(string: "https://store.steampowered.com/app/\(appId)/")!
    }
    // swiftlint:enable force_unwrapping

    var countryCode: String {
        Locale.current.region?.identifier.lowercased() ?? "us"
    }

    // MARK: Metadata

    /// The store page's details for a game. Cached in memory, and on disk for a
    /// day so the library can show details offline after one visit.
    public func metadata(appId: Int) async throws -> GameMetadata {
        if let cached = metadataCache[appId] { return cached }
        if let cached = readDisk(appId: appId) {
            metadataCache[appId] = cached
            return cached
        }
        var components = URLComponents(string: "https://store.steampowered.com/api/appdetails")
        components?.queryItems = [
            URLQueryItem(name: "appids", value: "\(appId)"),
            URLQueryItem(name: "cc", value: countryCode),
            URLQueryItem(name: "l", value: "english")
        ]
        guard let url = components?.url else { throw SteamStoreError.malformedResponse }
        let data = try await fetch(url)
        guard let envelope = try? JSONDecoder().decode([String: AppDetailsEnvelope].self, from: data),
              let entry = envelope["\(appId)"] else { throw SteamStoreError.malformedResponse }
        guard entry.success, let details = entry.data else { throw SteamStoreError.notFound }
        let metadata = details.metadata(appId: appId)
        metadataCache[appId] = metadata
        writeDisk(metadata)
        return metadata
    }

    // MARK: Lists

    /// The store front's own shelves: specials, top sellers, new releases and coming soon.
    public func featured() async throws -> [(title: String, items: [StoreListing])] {
        var components = URLComponents(string: "https://store.steampowered.com/api/featuredcategories")
        components?.queryItems = [
            URLQueryItem(name: "cc", value: countryCode), URLQueryItem(name: "l", value: "english")
        ]
        guard let url = components?.url else { throw SteamStoreError.malformedResponse }
        let data = try await fetch(url)
        guard let decoded = try? JSONDecoder().decode(FeaturedEnvelope.self, from: data) else {
            throw SteamStoreError.malformedResponse
        }
        let shelves: [(String, FeaturedCategory?)] = [
            ("Top Sellers", decoded.top_sellers),
            ("Specials", decoded.specials),
            ("New Releases", decoded.new_releases),
            ("Coming Soon", decoded.coming_soon)
        ]
        return shelves.compactMap { title, category in
            var seen = Set<Int>()
            let items = (category?.items ?? [])
                .filter { $0.type == nil || $0.type == 0 }
                .filter { seen.insert($0.id).inserted }
                .map(\.listing)
            return items.isEmpty ? nil : (title, items)
        }
    }

    /// Steam Charts' most played games by daily peak, named and priced from
    /// each game's store details (cached, so this is cheap after the first visit).
    public func mostPlayed(limit: Int = 15) async throws -> [StoreListing] {
        guard let url = URL(string: "https://api.steampowered.com/ISteamChartsService/GetMostPlayedGames/v1/") else {
            throw SteamStoreError.malformedResponse
        }
        let data = try await fetch(url)
        guard let decoded = try? JSONDecoder().decode(ChartsEnvelope.self, from: data) else {
            throw SteamStoreError.malformedResponse
        }
        let ids = (decoded.response?.ranks ?? []).sorted { $0.rank < $1.rank }.prefix(limit).map(\.appid)
        return await listings(for: Array(ids))
    }

    /// SteamSpy's most played over the last two weeks: what is trending
    /// rather than what has always been big.
    public func trending(limit: Int = 15) async throws -> [StoreListing] {
        guard let cached = trendingCache, Date().timeIntervalSince(cached.date) < 3_600 else {
            guard let url = URL(string: "https://steamspy.com/api.php?request=top100in2weeks") else {
                throw SteamStoreError.malformedResponse
            }
            let data = try await fetch(url)
            guard let decoded = try? JSONDecoder().decode([String: SpyItem].self, from: data) else {
                throw SteamStoreError.malformedResponse
            }
            let items = decoded.values
                .sorted { ($0.average_2weeks ?? 0) * ($0.ccu ?? 0) > ($1.average_2weeks ?? 0) * ($1.ccu ?? 0) }
                .map(\.listing)
            trendingCache = (Date(), items)
            return Array(items.prefix(limit))
        }
        return Array(cached.items.prefix(limit))
    }

    private var trendingCache: (date: Date, items: [StoreListing])?

    /// Listings for app IDs, in order, skipping any the store has no page for.
    private func listings(for ids: [Int]) async -> [StoreListing] {
        // In parallel: one at a time, fifteen store lookups kept the shelf
        // empty for several seconds on a first visit.
        let found = await withTaskGroup(of: StoreListing?.self) { group in
            for id in ids {
                group.addTask {
                    guard let meta = try? await self.metadata(appId: id) else { return nil }
                    return StoreListing(
                        appId: id, name: meta.name, price: meta.isFree ? nil : meta.finalPrice,
                        discountPercent: meta.discountPercent, isFree: meta.isFree, headerURL: meta.headerURL
                    )
                }
            }
            var byID: [Int: StoreListing] = [:]
            for await listing in group {
                if let listing { byID[listing.appId] = listing }
            }
            return byID
        }
        return ids.compactMap { found[$0] }
    }

    /// Each game's real art addresses. Newer games keep their art under
    /// hashed paths, so the fixed `library_hero.jpg` address 404s for them;
    /// Steam's own store browser API names the actual files.
    public func artwork(appIds: [Int]) async -> [Int: StoreArtwork] {
        let missing = appIds.filter { artworkCache[$0] == nil }
        if !missing.isEmpty {
            let ids = missing.map { "{\"appid\":\($0)}" }.joined(separator: ",")
            let input = """
            {"ids":[\(ids)],"context":{"language":"english","country_code":"\(countryCode.uppercased())"},\
            "data_request":{"include_assets":true}}
            """
            var components = URLComponents(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/")
            components?.queryItems = [URLQueryItem(name: "input_json", value: input)]
            if let url = components?.url, let data = try? await fetch(url),
               let decoded = try? JSONDecoder().decode(StoreItemsEnvelope.self, from: data) {
                for item in decoded.response?.store_items ?? [] {
                    guard let appId = item.appid, let assets = item.assets else { continue }
                    artworkCache[appId] = assets.artwork
                }
            }
            for id in missing where artworkCache[id] == nil { artworkCache[id] = StoreArtwork() }
        }
        return appIds.reduce(into: [:]) { $0[$1] = artworkCache[$1] }
    }

    private var artworkCache: [Int: StoreArtwork] = [:]

    /// How many people are in the game right now.
    public func currentPlayers(appId: Int) async -> Int? {
        guard let url = URL(
            string: "https://api.steampowered.com/ISteamUserStats/GetNumberOfCurrentPlayers/v1/?appid=\(appId)"
        ), let data = try? await fetch(url),
            let decoded = try? JSONDecoder().decode(PlayersEnvelope.self, from: data) else { return nil }
        return decoded.response?.player_count
    }

    /// Searches the store by name.
    public func search(_ term: String) async throws -> [StoreListing] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/")
        components?.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "cc", value: countryCode),
            URLQueryItem(name: "l", value: "english")
        ]
        guard let url = components?.url else { throw SteamStoreError.malformedResponse }
        let data = try await fetch(url)
        guard let decoded = try? JSONDecoder().decode(SearchEnvelope.self, from: data) else {
            throw SteamStoreError.malformedResponse
        }
        return (decoded.items ?? []).filter { $0.type == "app" }.map(\.listing)
    }

    // MARK: Plumbing

    func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SteamStoreError.http(http.statusCode)
        }
        return data
    }

    private func diskURL(appId: Int) -> URL? {
        diskCache?.appending(path: "\(appId)-\(countryCode).json")
    }

    private func readDisk(appId: Int) -> GameMetadata? {
        guard let url = diskURL(appId: appId),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 86_400,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GameMetadata.self, from: data)
    }

    private func writeDisk(_ metadata: GameMetadata) {
        guard let url = diskURL(appId: metadata.appId),
              let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
