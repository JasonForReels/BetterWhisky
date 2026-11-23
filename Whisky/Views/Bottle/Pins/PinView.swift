//
//  PinView.swift
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
import WhiskyKit

struct PinView: View {
    @ObservedObject var bottle: Bottle
    @ObservedObject var program: Program
    @State var pin: PinnedProgram
    @Binding var path: NavigationPath
    @Binding var toast: ToastData?

    @State private var image: Image?
    @State private var showRenameSheet = false
    @State private var name: String = ""
    @State private var opening: Bool = false

    var body: some View {
        // A row in the bottle's Pinned section, laid out like a Settings row:
        // icon, name, and the action at the trailing edge.
        HStack(spacing: 12) {
            Group {
                if let image {
                    image.resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if opening {
                ProgressView().controlSize(.small)
            } else {
                Button("button.run.short", systemImage: "play.fill") { runProgram() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(Text("button.run.short"))
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            ProgramMenuView(program: program, path: $path)

            Button("button.rename", systemImage: "pencil.line") {
                showRenameSheet.toggle()
            }
            .labelStyle(.titleAndIcon)
            Button("button.showInFinder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([program.url])
            }
            .labelStyle(.titleAndIcon)
        }
        // Double-click opens, as in a Finder list; a single click on a row
        // should never start a game by accident.
        .onTapGesture(count: 2) {
            runProgram()
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameView("rename.pin.title", name: name) { newName in
                name = newName
            }
        }
        .task {
            // A pin named after its executable ("steam") reads better under
            // the launcher's own name, as it does in the Library.
            let exeName = program.url.deletingPathExtension().lastPathComponent
            if pin.name == exeName, let launcher = LauncherType.detect(from: program.url) {
                name = launcher.displayName
            } else {
                name = pin.name
            }
            let icon = await IconCache.shared.iconOrFallback(for: program.url, peFile: program.peFile)
            self.image = Image(nsImage: icon)
        }
        .onChange(of: name) {
            if let index = bottle.settings.pins.firstIndex(where: {
                let exists = FileManager.default.fileExists(atPath: pin.url?.path(percentEncoded: false) ?? "")
                return $0.url == pin.url && exists
            }) {
                bottle.settings.pins[index].name = name
            }
        }
    }

    func runProgram() {
        opening = true

        // Capture modifier flags synchronously before entering async context
        let useTerminal = NSEvent.modifierFlags.contains(.shift)
        Telemetry.capture(.firstProgramLaunchAttempted)
        Task {
            let result = await program.launchWithUserMode(useTerminal: useTerminal) { contentType, sizeBytes in
                withAnimation {
                    toast = .clipboardCleared(contentType: contentType, sizeBytes: sizeBytes)
                }
            }
            opening = false
            withAnimation {
                toast = result.toastData
            }
        }
    }
}
