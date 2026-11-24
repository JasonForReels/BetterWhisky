//
//  SteamStore+Wire.swift
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

// MARK: - Wire formats

// swiftlint:disable identifier_name

struct AppDetailsEnvelope: Decodable {
    let success: Bool
    let data: AppDetails?
}

struct AppDetails: Decodable {
    struct Price: Decodable {
        let initial_formatted: String?
        let final_formatted: String?
        let discount_percent: Int?
    }

    struct Named: Decodable { let description: String }
    struct Release: Decodable {
        let coming_soon: Bool?
        let date: String?
    }

    struct Platforms: Decodable {
        let windows: Bool?
        let mac: Bool?
    }

    struct Metacritic: Decodable { let score: Int? }
    struct Screenshot: Decodable { let path_full: String? }

    let name: String
    let short_description: String?
    let is_free: Bool?
    let developers: [String]?
    let publishers: [String]?
    let genres: [Named]?
    let release_date: Release?
    let price_overview: Price?
    let platforms: Platforms?
    let metacritic: Metacritic?
    let screenshots: [Screenshot]?
    let header_image: String?
    let website: String?

    func metadata(appId: Int) -> GameMetadata {
        let finalPrice = price_overview?.final_formatted
        let initial = price_overview?.initial_formatted.flatMap { $0.isEmpty ? nil : $0 }
        return GameMetadata(
            appId: appId,
            name: name,
            shortDescription: (short_description ?? "").decodingHTMLEntities,
            developers: developers ?? [],
            publishers: publishers ?? [],
            genres: genres?.map(\.description) ?? [],
            releaseDate: release_date?.date.flatMap { $0.isEmpty ? nil : $0 },
            comingSoon: release_date?.coming_soon ?? false,
            metacritic: metacritic?.score,
            isFree: is_free ?? false,
            initialPrice: initial ?? finalPrice,
            finalPrice: finalPrice,
            discountPercent: price_overview?.discount_percent ?? 0,
            windows: platforms?.windows ?? true,
            mac: platforms?.mac ?? false,
            screenshots: (screenshots ?? []).prefix(8).compactMap { $0.path_full.flatMap(URL.init(string:)) },
            headerURL: header_image.flatMap(URL.init(string:)) ?? SteamStore.headerURL(appId: appId),
            website: website.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        )
    }
}

struct FeaturedEnvelope: Decodable {
    let specials: FeaturedCategory?
    let coming_soon: FeaturedCategory?
    let top_sellers: FeaturedCategory?
    let new_releases: FeaturedCategory?
}

struct FeaturedCategory: Decodable {
    let items: [FeaturedItem]?
}

struct FeaturedItem: Decodable {
    let id: Int
    let type: Int?
    let name: String
    let discount_percent: Int?
    let final_price: Int?
    let currency: String?

    var listing: StoreListing {
        let price: String? = final_price.map { cents in
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency ?? "USD"
            return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? ""
        }
        let free = final_price == 0
        return StoreListing(
            appId: id, name: name, price: free ? nil : price,
            discountPercent: discount_percent ?? 0, isFree: free
        )
    }
}

struct SearchEnvelope: Decodable {
    let items: [SearchItem]?
}

struct SearchItem: Decodable {
    struct Price: Decodable {
        let currency: String?
        let initial: Int?
        let final: Int?
    }

    let type: String
    let id: Int
    let name: String
    let price: Price?

    var listing: StoreListing {
        let formatted: String? = price?.final.map { cents in
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = price?.currency ?? "USD"
            return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? ""
        }
        let discount: Int = {
            guard let initial = price?.initial, let final = price?.final, initial > 0, final < initial else { return 0 }
            return Int((Double(initial - final) / Double(initial) * 100).rounded())
        }()
        return StoreListing(appId: id, name: name, price: formatted, discountPercent: discount, isFree: price == nil)
    }
}

struct ChartsEnvelope: Decodable {
    struct Response: Decodable { let ranks: [Rank]? }
    struct Rank: Decodable {
        let rank: Int
        let appid: Int
    }

    let response: Response?
}

struct PlayersEnvelope: Decodable {
    struct Response: Decodable { let player_count: Int? }
    let response: Response?
}

struct SpyItem: Decodable {
    let appid: Int
    let name: String?
    let price: String?
    let initialprice: String?
    let discount: String?
    let ccu: Int?
    let average_2weeks: Int?

    var listing: StoreListing {
        let cents = Int(price ?? "") ?? 0
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return StoreListing(
            appId: appid, name: name ?? "App \(appid)",
            price: cents > 0 ? formatter.string(from: NSNumber(value: Double(cents) / 100)) : nil,
            discountPercent: Int(discount ?? "") ?? 0, isFree: cents == 0
        )
    }
}

struct StoreItemsEnvelope: Decodable {
    struct Response: Decodable { let store_items: [Item]? }
    struct Item: Decodable {
        let appid: Int?
        let assets: Assets?
    }

    struct Assets: Decodable {
        let asset_url_format: String?
        let library_hero: String?
        let library_hero_2x: String?
        let header: String?

        var artwork: StoreArtwork {
            func url(_ file: String?) -> URL? {
                guard let file, let format = asset_url_format else { return nil }
                let path = format.replacingOccurrences(of: "${FILENAME}", with: file)
                return URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/\(path)")
            }
            return StoreArtwork(hero: url(library_hero_2x ?? library_hero), header: url(header))
        }
    }

    let response: Response?
}

// swiftlint:enable identifier_name

extension String {
    /// The store sends descriptions with a few HTML entities left in.
    var decodingHTMLEntities: String {
        [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")]
            .reduce(self) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}
