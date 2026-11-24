//
//  SteamStore+PopularNew.swift
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

extension SteamStore {
    /// The most popular games released in the last year, newest first: the
    /// store's best-seller search, filtered by release date here because
    /// Steam ignores its own "popular new" filter in this response.
    public func popularNew(limit: Int = 8) async throws -> [StoreListing] {
        var components = URLComponents(string: "https://store.steampowered.com/search/results/")
        components?.queryItems = [
            URLQueryItem(name: "start", value: "0"), URLQueryItem(name: "count", value: "75"),
            URLQueryItem(name: "infinite", value: "1"), URLQueryItem(name: "category1", value: "998"),
            URLQueryItem(name: "cc", value: countryCode), URLQueryItem(name: "l", value: "english")
        ]
        guard let url = components?.url else { throw SteamStoreError.malformedResponse }
        let data = try await fetch(url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let html = object["results_html"] as? String else { throw SteamStoreError.malformedResponse }

        // Steam writes "Aug 21, 2012" or "21 Aug, 2012" depending on the region.
        let formatters = ["MMM d, yyyy", "d MMM, yyyy", "d MMM yyyy", "MMM yyyy"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
        let cutoff = Date().addingTimeInterval(-365 * 86_400)
        let now = Date().addingTimeInterval(86_400)

        // One result per <a ... data-ds-appid="..."> row.
        let rows = html.components(separatedBy: "<a href=").dropFirst()
        var found: [(listing: StoreListing, released: Date)] = []
        var seen = Set<Int>()
        for row in rows {
            guard let appId = Self.capture(#"data-ds-appid="(\d+)""#, in: row).flatMap(Int.init),
                  seen.insert(appId).inserted,
                  let name = Self.capture(#"<span class="title">([^<]+)"#, in: row),
                  let dateText = Self.capture(#"search_released[^>]*>\s*([^<]*?)\s*<"#, in: row),
                  let released = formatters.lazy.compactMap({ $0.date(from: dateText) }).first,
                  released > cutoff, released < now else { continue }
            let price = Self.capture(#"discount_final_price[^>]*>([^<]+)"#, in: row)
            let discount = Self.capture(#"discount_pct">-(\d+)%"#, in: row).flatMap(Int.init) ?? 0
            let free = price?.localizedCaseInsensitiveContains("free") ?? false
            found.append((
                StoreListing(
                    appId: appId, name: name.decodingHTMLEntities, price: free ? nil : price,
                    discountPercent: discount, isFree: free
                ),
                released
            ))
        }
        return found.sorted { $0.released > $1.released }.prefix(limit).map(\.listing)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
