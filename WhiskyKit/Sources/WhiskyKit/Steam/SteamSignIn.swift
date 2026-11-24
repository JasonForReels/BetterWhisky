//
//  SteamSignIn.swift
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

/// Whether the bottle's Steam client is signed in, read from its connection log.
///
/// A client started hidden (`-silent`) with no saved sign-in never shows its
/// sign-in window and drops `-applaunch` without a word, so a launch checks
/// first. Every line of `logs/connection_log.txt` carries the client's state
/// and Steam ID, as in `[Logged On, 4, 7] [U:1:1172597968] …`; the last such
/// line is the current one. A client with no account to sign in with sits at
/// `[Logged Off, …] [U:1:0]`.
public enum SteamSignIn {
    public enum State: Equatable, Sendable {
        case signedIn
        /// Logged off with no account: it won't sign in on its own.
        case signedOut
        /// Connecting, or the log says nothing yet.
        case pending
    }

    /// Posted with the bottle's URL as the object when a launch stopped for sign-in.
    public static let signInNeededNotification = Notification.Name("SteamSignInNeeded")

    public static func state(steamRoot: URL) -> State {
        let log = steamRoot.appending(path: "logs/connection_log.txt")
        guard let handle = try? FileHandle(forReadingFrom: log) else { return .pending }
        defer { try? handle.close() }
        // The tail is enough: the log grows across sessions.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let text = String(bytes: handle.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return state(logTail: text)
    }

    static func state(logTail text: String) -> State {
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard let open = line.range(of: "] [")?.upperBound,
                  let comma = line[open...].firstIndex(of: ",") else { continue }
            let status = line[open ..< comma]
            switch status {
            case "Logged On":
                return .signedIn
            case "Logged Off":
                return line.contains("[U:1:0]") ? .signedOut : .pending
            case "Logging On", "Connecting", "Logging Off":
                return .pending
            default:
                continue
            }
        }
        return .pending
    }

    /// Waits for the client to settle, up to `timeout`; anything still not
    /// signed in by then counts as signed out only if it has no account.
    @MainActor
    public static func waitForState(
        steamRoot: URL, timeout: Duration = .seconds(20), pollInterval: Duration = .seconds(1)
    ) async -> State {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var current = state(steamRoot: steamRoot)
        while current != .signedIn, ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            current = state(steamRoot: steamRoot)
        }
        return current
    }

    /// Waits for the person to sign in through the client's window, up to `timeout`.
    @MainActor
    public static func waitForSignIn(
        steamRoot: URL, timeout: Duration = .seconds(600), pollInterval: Duration = .seconds(2)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if state(steamRoot: steamRoot) == .signedIn { return true }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }
}
