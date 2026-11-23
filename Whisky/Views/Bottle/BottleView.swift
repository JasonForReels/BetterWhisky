//
//  BottleView.swift
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

enum BottleStage {
    case config
    case programs
    case processes
    case gameConfigs
}

struct BottleView: View {
    @ObservedObject var bottle: Bottle
    @State private var path = NavigationPath()
    @State private var programLoading: Bool = false
    @State private var showWinetricksSheet: Bool = false
    @State private var showDuplicate: Bool = false
    @State private var toast: ToastData?
    /// Launches the ``ProcessRegistry`` tracks for this bottle, for the Processes badge.
    @State private var trackedProcessCount: Int = 0

    var body: some View {
        NavigationStack(path: $path) {
            // One grouped form, the shape of a System Settings pane: what you
            // run from this bottle first, then where you go to change it.
            Form {
                Section {
                    header
                }
                Section("bottle.section.pinned") {
                    ForEach(bottle.pinnedPrograms, id: \.id) { pinnedProgram in
                        PinView(
                            bottle: bottle,
                            program: pinnedProgram.program,
                            pin: pinnedProgram.pin,
                            path: $path,
                            toast: $toast
                        )
                    }
                    PinAddView(bottle: bottle)
                }
                Section {
                    NavigationLink(value: BottleStage.programs) {
                        Label("tab.programs", systemImage: "square.stack")
                    }
                    .accessibilityIdentifier("nav.installedPrograms")
                    NavigationLink(value: BottleStage.processes) {
                        Label("tab.processes", systemImage: "waveform.path.ecg")
                    }
                    .badge(trackedProcessCount)
                    .accessibilityIdentifier("nav.runningProcesses")
                    NavigationLink(value: BottleStage.gameConfigs) {
                        Label("tab.gameConfigs", systemImage: "gamecontroller")
                    }
                    .accessibilityIdentifier("nav.gameConfigurations")
                }
                Section {
                    NavigationLink(value: BottleStage.config) {
                        Label("tab.config", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("nav.bottleConfiguration")
                }
            }
            .formStyle(.grouped)
            .task {
                await updateStartMenu()
            }
            .task(id: bottle.url) {
                trackedProcessCount = ProcessRegistry.shared.getProcessCount(for: bottle)
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessRegistry.didChangeNotification)) { note in
                guard note.userInfo?[ProcessRegistry.bottleURLKey] as? URL == bottle.url else { return }
                trackedProcessCount = ProcessRegistry.shared.getProcessCount(for: bottle)
            }
            .disabled(!bottle.isAvailable)
            .navigationTitle(bottle.settings.name)
            .accessibilityIdentifier("bottleDetail")
            .toast($toast)
            .toolbar {
                BottleToolbar(
                    bottle: bottle,
                    showWinetricksSheet: $showWinetricksSheet,
                    showDuplicate: $showDuplicate,
                    programLoading: $programLoading,
                    toast: $toast,
                    onLaunch: updateStartMenu
                )
            }
            .sheet(isPresented: $showWinetricksSheet) {
                WinetricksView(bottle: bottle)
            }
            .sheet(isPresented: $showDuplicate) {
                RenameView(
                    "duplicate.bottle.title",
                    name: BottleOperations.nextDuplicateName(
                        baseName: bottle.settings.name,
                        existingNames: BottleVM.shared.bottles.map(\.settings.name)
                    ),
                    confirmTitle: "duplicate.bottle.confirm"
                ) { newName in
                    Task {
                        do {
                            _ = try await bottle.duplicate(newName: newName)
                            await MainActor.run {
                                withAnimation {
                                    toast = ToastData(
                                        message: String(
                                            format: String(localized: "status.duplicateSuccess %@"),
                                            newName
                                        ),
                                        style: .success
                                    )
                                }
                            }
                        } catch {
                            await MainActor.run {
                                withAnimation {
                                    toast = ToastData(
                                        message: String(
                                            format: String(localized: "status.duplicateFailed %@"),
                                            error.localizedDescription
                                        ),
                                        style: .error
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .onChange(of: bottle.settings) { oldValue, newValue in
                guard oldValue != newValue else { return }
                // Trigger a reload
                BottleVM.shared.bottles = BottleVM.shared.bottles
            }
            .navigationDestination(for: BottleStage.self) { stage in
                switch stage {
                case .config:
                    ConfigView(bottle: bottle)
                case .programs:
                    ProgramsView(
                        bottle: bottle, path: $path
                    )
                case .processes:
                    RunningProcessesView(bottle: bottle)
                case .gameConfigs:
                    GameConfigurationView(bottle: bottle)
                }
            }
            .navigationDestination(for: Program.self) { program in
                ProgramView(program: program) {
                    // Open the bottle's configuration on top of the program,
                    // so Back returns to it.
                    path.append(BottleStage.config)
                }
            }
        }
    }
}

extension BottleView {
    /// The top of the pane, like a System Settings header: what this bottle
    /// is, in the three facts that decide whether a game will run in it.
    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(bottle.settings.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(facts)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// "Windows 10 · Wine 10.0.0 · D3DMetal". The backend is the one a launch
    /// would actually use, so "Recommended" resolves to its real name.
    private var facts: String {
        let backend = bottle.settings.graphicsBackend == .recommended
            ? GraphicsBackendResolver.resolve().displayName
            : bottle.settings.graphicsBackend.displayName
        return [
            bottle.settings.windowsVersion.pretty(),
            "Wine \(bottle.settings.wineVersion)",
            backend
        ].joined(separator: " · ")
    }

    /// Rescans the bottle and pins the programs of shortcuts that installers
    /// added since the last check (see ``StartMenuShortcutSync``).
    private func updateStartMenu() async {
        await bottle.updateInstalledPrograms()
        if StartMenuShortcutSync.sync(bottle: bottle, wineUsername: bottle.wineUsername) {
            // Pins outside Program Files only show up once the list is rebuilt.
            await bottle.updateInstalledPrograms()
        }
    }
}
