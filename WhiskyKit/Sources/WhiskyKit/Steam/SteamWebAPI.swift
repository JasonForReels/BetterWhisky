//
//  SteamWebAPI.swift
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
import Security

/// A game the Steam account owns, as Steam reports it.
public struct SteamOwnedGame: Identifiable, Hashable, Sendable {
    public var id: Int { appId }
    public let appId: Int
    public let name: String
    /// Minutes played, across every platform.
    public let playtimeMinutes: Int
    /// When Steam last saw it played, nil if never.
    public let lastPlayed: Date?

    public init(appId: Int, name: String, playtimeMinutes: Int, lastPlayed: Date?) {
        self.appId = appId
        self.name = name
        self.playtimeMinutes = playtimeMinutes
        self.lastPlayed = lastPlayed
    }

    /// Steam's public store art for the game. Used for games that are not
    /// installed, whose art is not in the bottle's own library cache yet.
    public var headerArtworkURL: URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)/header.jpg")!
    }
}

public enum SteamWebAPIError: LocalizedError, Equatable {
    case missingKey
    case missingAccount
    /// Steam refused the key.
    case unauthorized
    /// The profile's game details are private, so Steam returned no games.
    case privateProfile
    case http(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add a Steam Web API key to see the games you own."
        case .missingAccount: "Sign in to Steam in a bottle, or enter your Steam ID."
        case .unauthorized: "Steam didn't accept this Web API key."
        case .privateProfile: "Steam returned no games. Make your game details public, or check the Steam ID."
        case let .http(code): "Steam answered with an error (\(code))."
        case .malformedResponse: "Steam's answer couldn't be read."
        }
    }
}

private struct OwnedGamesEnvelope: Decodable {
    let response: OwnedGamesResponse?
}

private struct OwnedGamesResponse: Decodable {
    let games: [OwnedGameRecord]?
}

private struct OwnedGameRecord: Decodable {
    let appid: Int
    let name: String?
    let playtime_forever: Int? // swiftlint:disable:this identifier_name
    let rtime_last_played: Int? // swiftlint:disable:this identifier_name
}

/// Reads the owned-games list from Steam's Web API.
///
/// This is Steam's own record of the account's licences, which is what makes
/// it the Steam Library: the local client only knows about what it has
/// touched on this Mac.
public enum SteamWebAPI {
    static let ownedGamesEndpoint = "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/"

    public static func ownedGames(
        key: String, steamID: String, session: URLSession = .shared
    ) async throws -> [SteamOwnedGame] {
        guard !key.isEmpty else { throw SteamWebAPIError.missingKey }
        guard !steamID.isEmpty else { throw SteamWebAPIError.missingAccount }
        // swiftlint:disable:next force_unwrapping
        var components = URLComponents(string: ownedGamesEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "steamid", value: steamID),
            URLQueryItem(name: "include_appinfo", value: "1"),
            URLQueryItem(name: "include_played_free_games", value: "1"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { throw SteamWebAPIError.malformedResponse }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw http.statusCode == 401 || http.statusCode == 403
                ? SteamWebAPIError.unauthorized : SteamWebAPIError.http(http.statusCode)
        }
        return try parseOwnedGames(data)
    }

    /// Parses a `GetOwnedGames` response.
    static func parseOwnedGames(_ data: Data) throws -> [SteamOwnedGame] {
        guard let envelope = try? JSONDecoder().decode(OwnedGamesEnvelope.self, from: data),
              let response = envelope.response
        else { throw SteamWebAPIError.malformedResponse }
        // An empty object is what a private profile gets.
        guard let games = response.games else { throw SteamWebAPIError.privateProfile }
        return games.compactMap { game in
            guard !SteamLibrary.nonGameAppIds.contains(game.appid) else { return nil }
            return SteamOwnedGame(
                appId: game.appid,
                name: game.name ?? "App \(game.appid)",
                playtimeMinutes: game.playtime_forever ?? 0,
                lastPlayed: game.rtime_last_played.flatMap {
                    $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
                }
            )
        }
    }
}

/// Which Steam account is connected, read from the Steam client in a bottle.
public enum SteamAccount {
    /// The SteamID64 of the account most recently signed in to Steam in any
    /// of `bottleURLs`, from the client's `config/loginusers.vdf`.
    public static func detectSteamID(bottleURLs: [URL]) -> String? {
        for url in bottleURLs {
            guard let root = SteamLibrary.detectInstall(bottleURL: url) else { continue }
            let file = root.appending(path: "config/loginusers.vdf")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let id = steamID(inLoginUsers: text) else { continue }
            return id
        }
        return nil
    }

    static func steamID(inLoginUsers text: String) -> String? {
        guard let users = (try? VDFParser.parse(text))?["users"]?.objectValue else { return nil }
        let ids = users.keys.filter { $0.count == 17 && $0.allSatisfy(\.isNumber) }
        return ids.first { users[$0]?.objectValue?["mostrecent"]?.stringValue == "1" } ?? ids.sorted().first
    }

    /// A pasted Steam ID, or nil if it isn't a SteamID64.
    public static func normalizedSteamID(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 17 && trimmed.allSatisfy(\.isNumber) ? trimmed : nil
    }
}

/// The Steam Web API key, kept in the login Keychain.
public enum SteamAPIKeyStore {
    static let service = "com.betterwhisky.steam-web-api"
    static let account = "default"

    public static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        delete()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(trimmed.utf8)
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
