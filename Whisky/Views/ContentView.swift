//
//  ContentView.swift
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
import SemanticVersion
import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

struct ContentView: View {
    @EnvironmentObject var bottleVM: BottleVM
    @Binding var showSetup: Bool

    @State var selected: URL?
    @State var tab: AppTab = .library
    @AppStorage("librarySort") private var librarySort: LibrarySort = .recent
    @State var showBottleCreation: Bool = false
    @State var bottlesLoaded: Bool = false
    @State var showBottleSelection: Bool = false
    @State var newlyCreatedBottleURL: URL?
    @State var openedFileURL: URL?
    @State var triggerRefresh: Bool = false
    @State var refreshAnimation: Angle = .degrees(0)

    @State var toast: ToastData?
    @State var corruptRegistryBackupURL: URL?
    @State private var updatingRuntime: Bool = false
    /// Set while a full-page view (a game's store page) wants the window to itself.
    @State private var hidesTopBar = false

    var body: some View {
        page
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { FirstLaunchOverlay() }
        // The tabs are the window's title, so the text title stays empty.
        // Removing the title outright also took the toolbar's drag area with
        // it, and the window could no longer be moved.
        .navigationTitle("")
        // No toolbar strip: the tabs and buttons float over the content, which
        // runs up to the top of the window.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onPreferenceChange(HidesTopBarKey.self) { hide in
            withAnimation(.smooth(duration: 0.3)) { hidesTopBar = hide }
        }
        .toast($toast)
        .onReceive(NotificationCenter.default.publisher(for: .zombieProcessesCleaned)) { _ in
            withAnimation {
                toast = ToastData(message: String(localized: "cleanup.leftovers.toast"), style: .info)
            }
        }
        .alert(
            "bottle.creation.failed.title",
            isPresented: Binding(
                get: { bottleVM.bottleCreationAlert != nil },
                set: { if !$0 { bottleVM.bottleCreationAlert = nil } }
            ),
            presenting: bottleVM.bottleCreationAlert
        ) { alert in
            if alert.isRuntimeMissing {
                Button("bottle.creation.failed.runSetup") {
                    showSetup = true
                }
            }
            Button("bottle.creation.failed.copyDiagnostics") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(alert.diagnostics, forType: .string)
            }
            Button("open.logs") {
                WhiskyApp.openLogsFolder()
            }
            Button("button.ok", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .alert(
            "bottle.registry.corrupt.title",
            isPresented: Binding(
                get: { corruptRegistryBackupURL != nil },
                set: { if !$0 { corruptRegistryBackupURL = nil } }
            ),
            presenting: corruptRegistryBackupURL
        ) { _ in
            Button("button.ok", role: .cancel) {}
        } message: { url in
            Text(String(
                format: String(localized: "bottle.registry.corrupt.message"),
                url.prettyPath()
            ))
        }
        .alert(
            "bottle.orphaned.title",
            isPresented: Binding(
                get: { !bottleVM.orphanedBottles.isEmpty },
                set: { if !$0 { bottleVM.orphanedBottles = [] } }
            )
        ) {
            Button("bottle.orphaned.reimport") {
                bottleVM.reimportOrphanedBottles()
            }
            Button("button.cancel", role: .cancel) {}
        } message: {
            Text(String(
                format: String(localized: "bottle.orphaned.message"),
                bottleVM.orphanedBottles.map(\.name).joined(separator: ", ")
            ))
        }
        .toolbar {
          if !hidesTopBar {
            // In the toolbar's own glass platter, at the control's natural
            // size: a forced large size is what pushed the thumb past the
            // platter's right edge.
            ToolbarItem(placement: .principal) {
                TopTabBar(selection: $tab)
            }
            // The window's own actions, kept together at the trailing edge:
            // add, filter, refresh.
            ToolbarItemGroup(placement: .primaryAction) {
                Button("button.createBottle", systemImage: "plus") {
                    showBottleCreation.toggle()
                }
                .help(Text("button.createBottle"))
                .accessibilityIdentifier("toolbar.createBottle")

                Menu {
                    Picker("library.sort", selection: $librarySort) {
                        ForEach(LibrarySort.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("library.sort", systemImage: "line.3.horizontal.decrease")
                }
                .help(Text("library.sort"))
                .disabled(tab == .bottles)
                .accessibilityIdentifier("library.sort")

                Button {
                    bottleVM.loadBottles()
                    if let bottle = bottleVM.bottles.first(where: { $0.url == selected }) {
                        Task { await bottle.updateInstalledPrograms() }
                    }
                    triggerRefresh.toggle()
                    withAnimation(.default) {
                        refreshAnimation = .degrees(360)
                    } completion: {
                        refreshAnimation = .degrees(0)
                    }
                } label: {
                    Label("button.refresh", systemImage: "arrow.triangle.2.circlepath")
                        .rotationEffect(refreshAnimation)
                }
                .help(Text("button.refresh"))
            }
          }
        }
        .sheet(isPresented: $showBottleCreation) {
            BottleCreationView(newlyCreatedBottleURL: $newlyCreatedBottleURL)
        }
        .onChange(of: newlyCreatedBottleURL) { _, url in
            if let url { selected = url }
        }
        .sheet(isPresented: $showSetup) {
            SetupView(showSetup: $showSetup, firstTime: false, updatingRuntime: $updatingRuntime)
        }
        .onChange(of: showSetup) { _, isShowing in
            if !isShowing {
                updatingRuntime = false
            }
        }
        .sheet(item: $openedFileURL) { url in
            FileOpenView(
                fileURL: url,
                currentBottle: selected,
                bottles: bottleVM.bottles,
                toast: $toast
            )
        }
        .onChange(of: selected) { oldValue, newValue in
            // Opening a bottle from anywhere (the library's menu, search, a new
            // bottle) shows it where bottles live.
            if newValue != nil, tab != .bottles { tab = .bottles }
            // Check if previous bottle had running processes
            guard let oldURL = oldValue,
                  let oldBottle = bottleVM.bottles.first(where: { $0.url == oldURL })
            else { return }

            // Only for what Whisky launched there: a game keeps running under
            // the wineserver after its launch returns, so the registry count
            // alone misses it, and an orphan has its own stop button.
            Task {
                guard await Wine.runState(for: oldBottle).isRunning else { return }
                // The probe takes a moment; if the user came back to this
                // bottle meanwhile, they haven't left it, so don't stop it.
                guard selected != oldURL else { return }

                switch oldBottle.settings.closeWithProcessesPolicy {
                case .alwaysKeepRunning:
                    break
                case .alwaysStop:
                    Wine.killBottle(bottle: oldBottle)
                    ProcessRegistry.shared.clearRegistry(for: oldBottle.url)
                case .ask:
                    showProcessCloseAlert(for: oldBottle)
                }
            }
        }
        .handlesExternalEvents(preferring: [], allowing: ["*"])
        .onOpenURL { url in
            if QuickLaunch.handle(url) { return }
            openedFileURL = url
        }
        .dropDestination(for: URL.self) { urls, _ in
            // A Finder drop of anything the Run panel would accept opens the
            // same run-this-file flow, wherever on the window it lands.
            let runnable = ["exe", "msi", "bat", "cmd", "msix", "appx", "url"]
            guard let url = urls.first(where: { runnable.contains($0.pathExtension.lowercased()) })
            else { return false }
            openedFileURL = url
            return true
        }
        .task {
            bottleVM.loadBottles()
            bottlesLoaded = true

            // Surface a registry that couldn't be read and was moved aside at
            // startup, so the reset bottle list doesn't pass silently (#61).
            corruptRegistryBackupURL = bottleVM.bottlesList.corruptRegistryBackupURL

            // Offer re-import for bottle folders the registry doesn't know
            // about — pairs with the corrupt-registry backup above: after a
            // registry reset the scan offers everything back (issue #145).
            bottleVM.scanForOrphanedBottles()

            // Deliberately does not select a bottle. The library is the landing
            // screen, and restoring a prefix selection would put the plumbing in
            // front of the thing people opened the app to do.

            // Skip the first-launch setup sheet and update check under UI testing:
            // tests run without a runtime, so this would otherwise drop a modal
            // sheet over the main window and race every toolbar interaction.
            guard !WhiskyApp.isUITesting else { return }

            // Rosetta too: a major macOS update can remove it, and the x86_64 Wine
            // then fails every launch with "Bad CPU type in executable".
            if !WhiskyWineInstaller.isWhiskyWineInstalled() || !Rosetta2.isRosettaInstalled {
                showSetup = true
            }
            // Settings' "Automatically check for WhiskyWine updates" gates only
            // this launch-time check.
            guard WhiskyWineInstaller.automaticUpdateChecksEnabled() else { return }
            let task = Task.detached {
                await WhiskyWineInstaller.shouldUpdateWhiskyWine()
            }
            let updateInfo = await task.value
            if updateInfo.0 {
                let alert = NSAlert()
                alert.messageText = String(localized: "update.whiskywine.title")
                alert.informativeText = String(
                    format: String(localized: "update.whiskywine.description"),
                    String(WhiskyWineInstaller.whiskyWineVersion()
                        ?? SemanticVersion(0, 0, 0)),
                    String(updateInfo.1)
                )
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(localized: "update.whiskywine.update"))
                alert.addButton(withTitle: String(localized: "button.removeAlert.cancel"))

                let response = alert.runModal()

                if response == .alertFirstButtonReturn {
                    // Keep the current runtime installed: the installer swaps the
                    // new one in only after it has extracted, so a failed download
                    // or install leaves bottles working.
                    updatingRuntime = true
                    showSetup = true
                }
            }
        }
    }
}

/// Covers the window during a mod's one-time account setup, the first time
/// it is started in a bottle, so the minute it takes doesn't look like a hang.
private struct FirstLaunchOverlay: View {
    @ObservedObject private var firstLaunch = ModFirstLaunch.shared
    /// About how long the hidden sign-in takes.
    private let expected: TimeInterval = 75

    var body: some View {
        if let name = firstLaunch.modName {
            ZStack {
                Rectangle().fill(.black.opacity(0.35)).ignoresSafeArea()
                VStack(spacing: 16) {
                    if firstLaunch.needsPerson {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 34)).foregroundStyle(.tint)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    Text("Getting \(name) Ready").font(.title2.weight(.semibold))
                    Text(firstLaunch.detail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if !firstLaunch.needsPerson {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            ProgressView(value: fraction(at: context.date))
                                .frame(width: 260)
                        }
                    }
                }
                .padding(32)
                .frame(width: 380)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .transition(.opacity)
        }
    }

    /// Fills toward 95% over the expected time, then waits for the real end.
    private func fraction(at date: Date) -> Double {
        guard let start = firstLaunch.startedAt else { return 0 }
        return min(0.95, date.timeIntervalSince(start) / expected)
    }
}
