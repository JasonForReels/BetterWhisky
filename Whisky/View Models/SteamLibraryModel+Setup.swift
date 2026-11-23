//
//  SteamLibraryModel+Setup.swift
//  Whisky
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

import AppKit
import Foundation
import SwiftUI
import WhiskyKit

/// The steps of a one-click Steam setup, in order.
enum SteamSetupStep: Int, CaseIterable, Comparable {
    case creatingBottle
    case installingSteam
    case signingIn
    case loadingLibrary

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .creatingBottle: "Create a bottle for Steam"
        case .installingSteam: "Install Steam"
        case .signingIn: "Sign in to Steam"
        case .loadingLibrary: "Load your library"
        }
    }

    /// What to tell the person while this step runs.
    var detail: String {
        switch self {
        case .creatingBottle: "Setting up a Windows environment. This takes a minute."
        case .installingSteam: "Downloading Steam from Valve and installing it."
        case .signingIn: "Steam may update itself first. Then sign in in the Steam window."
        case .loadingLibrary: "Reading the games in your account."
        }
    }
}

extension SteamLibraryModel {
    /// Set by the first-run screen so the Steam Library page starts setup as
    /// it appears: the one click is the button that brought you here.
    static var setupRequested = false

    /// The debug switch in ``setupBottle()``, so the page starts the test run itself.
    static var debugFreshSetupRequested: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "debugSteamSetupFreshBottle")
        #else
        false
        #endif
    }

    /// One click from nothing to a filled Steam Library: makes a bottle,
    /// installs Steam, opens it for sign-in, waits, then brings BetterWhisky
    /// back with the library loaded. Every step that is already done is
    /// skipped, so it is also the way back for a signed-out client.
    func setUpSteam() {
        guard !settingUp else { return }
        setupStep = .creatingBottle
        connection = .loading
        Task {
            defer { setupStep = nil }
            do {
                let bottle = try await setupBottle()
                setupStep = .signingIn
                if SteamAccount.detectSteamID(bottleURLs: [bottle.url]) == nil {
                    try await openSteamForSignIn(in: bottle)
                    guard await waitForSignIn(in: bottle) else {
                        errorMessage = "Steam wasn't signed in. Choose Set Up Steam to try again."
                        await reload()
                        return
                    }
                }
                setupStep = .loadingLibrary
                await waitForLibraryCache(in: bottle)
                await reload()
                // Back to BetterWhisky, which is already on this page.
                NSApp.activate()
            } catch {
                errorMessage = error.localizedDescription
                await reload()
            }
        }
    }

    private func setupBottle() async throws -> Bottle {
        #if DEBUG
        // For testing the whole flow on a Mac that already has Steam set up:
        // `defaults write com.thejaysmith.BetterWhisky debugSteamSetupFreshBottle -bool YES`
        if UserDefaults.standard.bool(forKey: "debugSteamSetupFreshBottle") {
            UserDefaults.standard.removeObject(forKey: "debugSteamSetupFreshBottle")
            let name = "Steam (Setup Test)"
            var made = bottles.first { $0.settings.name == name }
            if made == nil { made = await BottleVM.shared.createBottleAndWait(named: name) }
            guard let made else {
                throw SteamLaunchError.steamNotInstalled
            }
            setupStep = .installingSteam
            try await SteamClientInstaller.install(into: made)
            return made
        }
        #endif
        return try await provisionBottle { [weak self] status in
            self?.setupStep = status == "Installing Steam…" ? .installingSteam : .creatingBottle
        }
    }

    /// Starts Steam with its window showing, which is where sign-in happens.
    private func openSteamForSignIn(in bottle: Bottle) async throws {
        guard let root = SteamLibrary.detectInstall(bottleURL: bottle.url) else {
            throw SteamLaunchError.steamNotInstalled
        }
        try await Wine.prepareBottlePrefix(bottle: bottle)
        // BetterWhisky warms Steam up hidden in every bottle, so a client may
        // already be running. A second `steam.exe` then waits on the first
        // and its window freezes; asking the running one to show itself is
        // what brings up sign-in. A cold start is told the same.
        try await Wine.runProgram(at: root.appending(path: "steam.exe"), args: ["steam://open/main"], bottle: bottle)
    }

    /// Steam writes `loginusers.vdf` once an account signs in. The first run
    /// updates the client before it shows sign-in, so this waits a long time.
    private func waitForSignIn(in bottle: Bottle) async -> Bool {
        let url = bottle.url
        for _ in 0 ..< 360 { // 30 minutes
            try? await Task.sleep(for: .seconds(5))
            if await Task.detached(operation: { SteamAccount.detectSteamID(bottleURLs: [url]) }).value != nil {
                return true
            }
        }
        return false
    }

    /// The client fills its library cache in the moments after sign-in;
    /// waits until the count stops growing, or about two minutes.
    private func waitForLibraryCache(in bottle: Bottle) async {
        let url = bottle.url
        var last = -1
        for _ in 0 ..< 24 {
            let count = await Task.detached { SteamClientLibrary.ownedAppIDs(bottleURLs: [url]).count }.value
            if count > 0, count == last { return }
            last = count
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

/// The one-click setup's checklist: done steps ticked, the current one
/// spinning with a line on what is happening.
struct SteamSetupProgress: View {
    let step: SteamSetupStep

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Setting Up Steam").font(.title2.weight(.semibold))
            ForEach(SteamSetupStep.allCases, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Group {
                        if item < step {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if item == step {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).foregroundStyle(item > step ? .secondary : .primary)
                        if item == step {
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: step)
        .frame(width: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
