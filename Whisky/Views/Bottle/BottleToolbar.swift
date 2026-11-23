//
//  BottleActionBar.swift
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

import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

/// A bottle's actions, in the window toolbar where macOS keeps them.
///
/// Run is the reason the app exists, so it is the one prominent item. The
/// other three are things you reach for occasionally and live in a menu, the
/// way Finder and Xcode tuck secondary commands behind a single "More" item.
struct BottleToolbar: ToolbarContent {
    @ObservedObject var bottle: Bottle
    @Binding var showWinetricksSheet: Bool
    @Binding var showDuplicate: Bool
    @Binding var programLoading: Bool
    @Binding var toast: ToastData?
    /// Called after a launch so the caller can refresh what it keeps in step
    /// with the prefix, the start menu among it.
    let onLaunch: () async -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("button.cDrive", systemImage: "folder") {
                    bottle.openCDrive()
                }
                .accessibilityIdentifier("bottle.openCDrive")
                Button("button.terminal", systemImage: "terminal") {
                    bottle.openTerminal()
                }
                .accessibilityIdentifier("bottle.openTerminal")
                Button("button.winetricks", systemImage: "wrench.and.screwdriver") {
                    showWinetricksSheet.toggle()
                }
                .accessibilityIdentifier("bottle.openWinetricks")
                Divider()
                Button("button.duplicateBottle", systemImage: "plus.square.on.square") {
                    showDuplicate = true
                }
                .disabled(bottle.inFlight)
            } label: {
                Label("button.more", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help(Text("button.more"))
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                runFromPanel()
            } label: {
                if programLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("button.run", systemImage: "play.fill")
                }
            }
            .help(Text("button.run"))
            .accessibilityIdentifier("bottle.runProgram")
            .disabled(programLoading)
        }
    }

    private func runFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType.exe,
            UTType(exportedAs: "com.microsoft.msi-installer"),
            UTType(exportedAs: "com.microsoft.bat"),
            UTType(exportedAs: "com.microsoft.msix-package"),
            UTType(exportedAs: "com.microsoft.appx-package"),
            UTType(exportedAs: "com.microsoft.windows-internet-shortcut")
        ]
        panel.directoryURL = bottle.url.appending(path: "drive_c")
        panel.begin { result in
            guard result == .OK, let url = panel.urls.first else { return }
            programLoading = true
            Task(priority: .userInitiated) {
                await run(url)
                await MainActor.run { programLoading = false }
                await onLaunch()
            }
        }
    }

    @MainActor
    private func run(_ url: URL) async {
        do {
            // Settings must be persisted before Wine.runProgram() reads them;
            // this completes synchronously on the main actor.
            LauncherFixes.detectAndApply(from: url, for: bottle)
            // After detection: in Automatic mode the policy depends on the launcher.
            let clipboard = bottle.performClipboardCheck()
            if case let .autoCleared(contentType, sizeBytes) = clipboard {
                toast = .clipboardCleared(contentType: contentType, sizeBytes: sizeBytes)
            }
            Telemetry.capture(.firstProgramLaunchAttempted)
            if Wine.isBatchFile(url) {
                try await Wine.runBatchFile(url: url, bottle: bottle)
            } else {
                try await Wine.runProgram(at: url, bottle: bottle)
            }
            withAnimation {
                toast = ToastData(
                    message: String(localized: "status.launched \(url.lastPathComponent)"),
                    style: .success
                )
            }
        } catch {
            let errDesc = error.localizedDescription
            withAnimation {
                toast = ToastData(
                    message: String(localized: "status.launchFailed \(errDesc)"),
                    style: .error,
                    autoDismiss: false
                )
            }
        }
    }
}
