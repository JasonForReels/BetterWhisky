//
//  ModsSectionView.swift
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

// swiftlint:disable file_length
import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

/// The Mods section on a program's page: presets, mods from any GitHub repo,
/// and a drop target for local `.zip` and `.dll` files.
struct ModsSectionView: View { // swiftlint:disable:this type_body_length
    @ObservedObject var program: Program
    @Binding var isExpanded: Bool

    @State private var installed: [InstalledMod] = []
    @State private var latestVersions: [String: GitHubRelease] = [:]
    @State private var busy: String?
    @State private var repoInput = ""
    @State private var pendingPlan: PendingPlan?
    @State private var message: String?
    @State private var dropTargeted = false
    @State private var activeMod: URL?
    @State private var showAddSheet = false
    @State private var showFilePicker = false
    @State private var launchRequest: LaunchRequest?
    @State private var profiles: [Profile] = []
    @State private var nameRequest: ProfileNameRequest?
    @State private var pendingCheck: PendingCheck?
    /// The profile Add from GitHub puts its mod into, when started from a profile's menu.
    @State private var addTarget: Profile?
    /// The profile shown below the profile picker.
    @State private var selectedProfileID: URL?
    /// Bumped to re-read companion apps after an install or a switch.
    @State private var companionsChanged = 0
    @Binding var modsChanged: Int

    /// A profile: its own copy of the game holding any mix of mods, each of
    /// which can be switched on or off. Like a profile on a streaming service,
    /// you pick one, and Play starts the game with that profile's mods.
    struct Profile: Identifiable {
        var id: URL { folder }
        let folder: URL
        let name: String
        let mods: [InstalledMod]
    }

    /// Naming a profile: a new empty one, a copy of one, or a rename.
    enum ProfileNameKind { case create, duplicate, rename }

    struct ProfileNameRequest: Identifiable {
        let id = UUID()
        let kind: ProfileNameKind
        let profile: Profile?
        var name: String
    }

    /// A mod unpacked and checked against a profile's mods, waiting for the go-ahead.
    struct PendingCheck: Identifiable {
        let id = UUID()
        let name: String
        let repo: String
        let version: String
        let rule: ModInstallRule
        let staged: StagedMod
        let report: ModCompatibilityReport
        let host: (name: String, folder: URL)
        var dependencies = ModDependencies()
    }

    struct PendingPlan: Identifiable {
        let id = UUID()
        let repo: String
        let release: GitHubRelease
        let plan: ModInstallPlan
    }

    private var gameFolder: URL { program.url.deletingLastPathComponent() }
    private var presets: [ModPreset] { ModPreset.presets(for: program.url) }

    var body: some View {
        Section(isExpanded: $isExpanded) {
            profilesBlock
            // Mods that don't use profiles (they go into the game itself).
            ForEach(presets.filter { !$0.install.frozenCopy }) { preset in
                presetRow(preset)
            }
            ForEach(installed.filter { mod in !presets.contains { $0.repo == mod.repo } }) { mod in
                otherModRow(mod)
            }
            ForEach(ModCompanion.companions(steamAppId: steamAppId)) { companion in
                companionRow(companion)
            }
            if busy != nil || message != nil {
                statusRow
            }
        } header: {
            Text("Mods")
        }
        .task(id: program.url) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: SteamSignIn.signInNeededNotification)) { note in
            guard (note.object as? URL) == program.bottle.url else { return }
            launchRequest = nil
            message = "Steam isn't signed in. Sign in in the Steam window that opened; "
                + "the game starts once you're signed in."
        }
        .sheet(isPresented: $showAddSheet) { addSheet }
        .sheet(item: $launchRequest) { request in
            LaunchProgressView(request: request) { launchRequest = nil }
        }
        .sheet(item: $pendingPlan) { pending in
            planSheet(pending)
        }
        .sheet(item: $nameRequest) { request in
            nameSheet(request)
        }
        .sheet(item: $pendingCheck, onDismiss: discardPendingCheck) { pending in
            compatibilitySheet(pending)
        }
    }

    // MARK: Profiles

    private var selectedProfile: Profile? {
        profiles.first { $0.folder == selectedProfileID }
            ?? profiles.first { isActive($0.folder) }
            ?? profiles.first
    }

    /// The preset Play uses to start a profile: the first of its mods that's a
    /// preset, or the game's own profile preset (the Steam launch) when none is.
    private func launchPreset(for profile: Profile) -> ModPreset? {
        profile.mods.lazy.compactMap { mod in presets.first { $0.repo == mod.repo } }.first
            ?? presets.first { $0.install.frozenCopy }
            ?? presets.first
    }

    /// The profile picker, then the picked profile's mods.
    private var profilesBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profiles.isEmpty ? "Make a profile to start modding" : "Profiles")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(profiles) { profileTile($0) }
                    newProfileTile
                }
                .padding(.vertical, 4)
            }
            if let profile = selectedProfile {
                profileDetail(profile)
            } else {
                Text("A profile is its own copy of the game with the mods you pick, like StellarRoles with "
                    + "LevelImposter, or Town of Us: Mira on its own. Make one, then add mods to it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    /// A profile's picture: the logo kept beside it, or the first of its mods
    /// with a logo in the app.
    private func profileImage(_ profile: Profile) -> NSImage? {
        let kept = profile.folder.deletingLastPathComponent().appending(path: ".betterwhisky-logo.png")
        if let image = NSImage(contentsOf: kept) { return image }
        return profile.mods.lazy.compactMap(modImage).first
    }

    private func modImage(_ mod: InstalledMod) -> NSImage? {
        NSImage(named: "ModLogo-" + mod.name.filter { $0.isLetter || $0.isNumber })
    }

    private func profileTile(_ profile: Profile) -> some View {
        let isSelected = profile.id == selectedProfile?.id
        let isOn = isActive(profile.folder)
        let count = profile.mods.count
        return Button {
            selectedProfileID = profile.folder
        } label: {
            VStack(spacing: 6) {
                ProfileAvatar(name: profile.name, image: profileImage(profile), size: 76)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                            .padding(-5)
                    }
                    .overlay(alignment: .bottom) {
                        if isOn {
                            Label("On", systemImage: "play.fill")
                                .font(.caption2.weight(.bold))
                                .labelStyle(.titleAndIcon)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .foregroundStyle(.white)
                                .background(.green, in: Capsule())
                                .offset(y: 9)
                        }
                    }
                    .scaleEffect(isSelected ? 1.04 : 1)
                    .shadow(color: .black.opacity(isSelected ? 0.3 : 0.12), radius: isSelected ? 8 : 3, y: 2)
                    .padding(.bottom, 4)
                Text(profile.name)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 96)
                Text(count == 0 ? "No mods" : "\(count) mod\(count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 6)
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.name) profile, \(count) mods\(isOn ? ", on" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("\(profile.name): \(profile.mods.map(\.name).joined(separator: ", ").nilIfEmpty ?? "no mods yet")")
    }

    private var newProfileTile: some View {
        Button {
            nameRequest = ProfileNameRequest(kind: .create, profile: nil, name: "")
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .frame(width: 76, height: 76)
                    .overlay { Image(systemName: "plus").font(.title).foregroundStyle(.secondary) }
                    .padding(.bottom, 4)
                Text("New Profile").font(.callout).foregroundStyle(.secondary).frame(width: 96)
            }
            .padding(.top, 6)
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
        .help("Make a new profile: a fresh copy of the game for its own set of mods")
    }

    /// The picked profile: Play or Turn On, then every mod in it with its switch.
    private func profileDetail(_ profile: Profile) -> some View {
        let isOn = isActive(profile.folder)
        let onCount = profile.mods.filter { ModInstaller.isEnabled($0, in: profile.folder) }.count
        let summary = profile.mods.isEmpty ? "No mods yet"
            : "\(onCount) of \(profile.mods.count) mod\(profile.mods.count == 1 ? "" : "s") on"
        return VStack(alignment: .leading, spacing: 10) {
            profileHeader(profile, isOn: isOn, summary: summary)
            Divider()
            Text("Mods in \(profile.name)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if profile.mods.isEmpty {
                Text("No mods yet. Add as many as you like: they all load together, and each has a switch.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(profile.mods) { modRow($0, in: profile) }
            }
            addModRow(profile)
        }
        .padding(12)
        .background(
            isOn ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.quinary),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(dropTargeted ? Color.accentColor : isOn ? Color.accentColor.opacity(0.6) : .clear,
                              style: StrokeStyle(lineWidth: 1, dash: dropTargeted ? [4] : []))
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        addTarget = profile
                        installDropped(url)
                    }
                }
            }
            return !providers.isEmpty
        }
    }

    private func profileHeader(_ profile: Profile, isOn: Bool, summary: String) -> some View {
        HStack(spacing: 14) {
            ProfileAvatar(name: profile.name, image: profileImage(profile), size: 48)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(profile.name).font(.title3.weight(.semibold))
                    statusBadge(isOn ? "On" : "Off", color: isOn ? .green : .secondary)
                }
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Profile \(profile.name), \(isOn ? "on" : "off"), \(summary)")
            Spacer(minLength: 12)
            if isOn {
                Button("Play", systemImage: "play.fill") {
                    if let preset = launchPreset(for: profile) { play(preset, modFolder: profile.folder) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy != nil || profile.mods.isEmpty)
                .help("Start the game with \(profile.name)'s mods")
            } else {
                Button("Turn On", systemImage: "power") { switchOn(profile.folder) }
                    .controlSize(.large)
                    .disabled(busy != nil)
                    .help("Make \(profile.name) the profile Play starts")
            }
            profileMenu(profile, isOn: isOn)
        }
    }

    /// Adding to the picked profile: a known mod, a GitHub repo, or a file or folder.
    private func addModRow(_ profile: Profile) -> some View {
        HStack(spacing: 8) {
            Menu("Add Mod", systemImage: "plus") {
                ForEach(addablePresets(for: profile)) { preset in
                    Button(preset.name) { addPreset(preset, to: profile) }
                }
                if !addablePresets(for: profile).isEmpty { Divider() }
                Button("From GitHub…", systemImage: "link") {
                    addTarget = profile
                    showAddSheet = true
                }
                Button("From a File or Folder…", systemImage: "doc.badge.plus") {
                    addTarget = profile
                    showFilePicker = true
                }
            }
            .fixedSize()
            .disabled(busy != nil)
            .help("Add a mod to \(profile.name)")
            Spacer()
            Label("or drop a .zip, .dll or folder here", systemImage: "arrow.down.doc")
                .font(.caption)
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
        }
        .padding(.top, 4)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.zip, .folder, UTType(filenameExtension: "dll") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                Task { @MainActor in
                    for url in urls { await installPicked(url) }
                    if pendingCheck == nil { addTarget = nil }
                }
            case .failure(let error):
                addTarget = nil
                message = error.localizedDescription
            }
        }
    }

    private func profileMenu(_ profile: Profile, isOn: Bool) -> some View {
        Menu {
            if isOn {
                Button("Turn Off (Play Without Mods)") { turnOffMods() }
                Divider()
            }
            Button("New Profile from This…") {
                nameRequest = ProfileNameRequest(kind: .duplicate, profile: profile, name: "\(profile.name) 2")
            }
            Button("Rename…") {
                nameRequest = ProfileNameRequest(kind: .rename, profile: profile, name: profile.name)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([profile.folder])
            }
            Divider()
            Button("Move Profile to Trash", role: .destructive) { removeProfile(profile) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(busy != nil)
        .accessibilityLabel("More for \(profile.name)")
        .help("Turn off, copy, rename, show in Finder or remove")
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    /// A mod in a profile, with a switch that parks its plugins outside
    /// BepInEx/plugins rather than deleting them, and its update when there is one.
    private func modRow(_ mod: InstalledMod, in profile: Profile) -> some View {
        let enabled = Binding(
            get: { ModInstaller.isEnabled(mod, in: profile.folder) },
            set: { isOn in
                do {
                    try ModInstaller.setEnabled(isOn, mod, in: profile.folder)
                    message = nil
                } catch {
                    message = error.localizedDescription
                }
                Task { await refresh() }
            }
        )
        let preset = presets.first { $0.repo == mod.repo }
        let update = preset.flatMap { latestVersions[$0.repo] }
            .flatMap { $0.tagName == mod.version ? nil : $0.tagName }
        return HStack(spacing: 12) {
            modRowIcon(mod)
            modLabel(mod, update: update, isOn: enabled.wrappedValue)
            Spacer(minLength: 12)
            if let update, let preset {
                Button("Update") { addPreset(preset, to: profile) }
                    .disabled(busy != nil)
                    .help("Update \(mod.name) to \(update) in \(profile.name)")
            }
            if ModInstaller.canToggle(mod) {
                Toggle("\(mod.name) on", isOn: enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(enabled.wrappedValue ? "Turn off for \(profile.name)" : "Turn on for \(profile.name)")
                    .disabled(busy != nil)
            }
            Menu {
                // Just this mod: the profile and its other mods stay.
                Button("Remove from \(profile.name)", role: .destructive) { removeAddOn(mod, from: profile) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More for \(mod.name)")
        }
        .padding(.vertical, 2)
    }

    private func modRowIcon(_ mod: InstalledMod) -> some View {
        Group {
            if let image = modImage(mod) {
                Image(nsImage: image).resizable().scaledToFit().padding(3)
            } else {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
            }
        }
        .frame(width: 30, height: 30)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func modLabel(_ mod: InstalledMod, update: String?, isOn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(mod.name)
                if let update { statusBadge("Update: \(update)", color: .orange) }
            }
            Text(mod.version == "local" ? "From a file" : "Version \(mod.version)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .opacity(isOn ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mod.name), \(isOn ? "on" : "off")"
            + (update.map { ", update \($0) available" } ?? ""))
    }

    private func removeProfile(_ profile: Profile) {
        do {
            if isActive(profile.folder) { turnOffMods() }
            try ModProfiles.remove(profile.folder)
            if selectedProfileID == profile.folder { selectedProfileID = nil }
            message = "Moved \(profile.name) to the Trash."
        } catch {
            message = error.localizedDescription
        }
        Task { await refresh() }
    }

    private func nameSheet(_ request: ProfileNameRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(nameSheetTitle(request)).font(.headline)
            if request.kind != .rename {
                Text(request.kind == .create
                    ? "A new profile is a fresh copy of the game. Add any mods to it, and they all load together."
                    : "The new profile starts with the same mods. Change them without touching "
                        + "\(request.profile?.name ?? "the original"), and pick which profile to play with Turn On.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Name", text: Binding(
                get: { nameRequest?.name ?? request.name },
                set: { nameRequest?.name = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit { applyName(nameRequest ?? request) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { nameRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button(request.kind == .rename ? "Rename" : "Create") { applyName(nameRequest ?? request) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func nameSheetTitle(_ request: ProfileNameRequest) -> String {
        switch request.kind {
        case .create: return "New profile"
        case .duplicate: return "New profile from \(request.profile?.name ?? "this one")"
        case .rename: return "Rename profile"
        }
    }

    private func applyName(_ request: ProfileNameRequest) {
        nameRequest = nil
        let wasOn = request.profile.map { isActive($0.folder) } ?? false
        Task {
            busy = request.kind == .rename ? nil : "Making \(request.name)…"
            defer { busy = nil }
            do {
                switch request.kind {
                case .create:
                    // A clone of the game shares storage with it on APFS, so it's quick.
                    let game = gameFolder
                    let copy = try await Task.detached { try ModProfiles.create(request.name, game: game) }.value
                    selectedProfileID = copy
                    message = "Made \(request.name). Add mods to it with Add Mod."
                case .duplicate:
                    guard let copy = request.profile?.folder else { return }
                    let made = try await Task.detached { try ModProfiles.duplicate(copy, as: request.name) }.value
                    selectedProfileID = made
                    message = "Made \(request.name). Turn it on to play with it."
                case .rename:
                    guard let profile = request.profile else { return }
                    let moved = try ModProfiles.rename(profile.folder, to: request.name)
                    selectedProfileID = moved
                    if wasOn { switchOn(moved) }
                    message = nil
                }
            } catch {
                message = error.localizedDescription
            }
            await refresh()
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func presetRow(_ preset: ModPreset) -> some View {
        let release = latestVersions[preset.repo]
        let current = installedPreset(preset)
        let isOn = current.map { isActive($0.folder) } ?? false
        let update = release.flatMap { release in
            current.flatMap { $0.mod.version == release.tagName ? nil : release.tagName }
        }
        HStack(spacing: 12) {
            modIcon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(preset.name)
                    if isOn {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("On").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Group {
                    if let current {
                        Text(update.map { "Version \(current.mod.version) · \($0) available" }
                            ?? "Version \(current.mod.version)")
                    } else if let release {
                        Text("Latest \(release.tagName)")
                    } else {
                        Text(verbatim: preset.repo)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if current == nil, let release, release.isStale {
                    Label("Last release is over six months old", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("It may not work with the current version of the game.")
                }
            }
            Spacer(minLength: 12)
            presetActions(preset, current: current, isOn: isOn, update: update)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func presetActions(
        _ preset: ModPreset, current: (mod: InstalledMod, folder: URL)?, isOn: Bool, update: String?
    ) -> some View {
        if let current {
            if isOn {
                Button("Play") { play(preset, modFolder: current.folder) }
                    .disabled(busy != nil)
            } else if preset.install.ownFolder || preset.install.frozenCopy {
                Button("Turn On") { switchOn(current.folder) }
                    .disabled(busy != nil)
            }
            Menu {
                if let update {
                    Button("Update to \(update)") { installPreset(preset) }
                }
                if isOn {
                    Button("Turn Off") { turnOffMods() }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([current.folder])
                }
                Divider()
                Button("Remove", role: .destructive) { remove(current.mod, in: current.folder) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy != nil)
        } else {
            Button("Install") { installPreset(preset) }
                .disabled(busy != nil)
        }
    }

    private func otherModRow(_ mod: InstalledMod, in folder: URL? = nil, addOnTo host: String? = nil) -> some View {
        HStack(spacing: 12) {
            modIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(mod.name)
                Text(host.map { "Version \(mod.version) · add-on for \($0)" } ?? "Version \(mod.version)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Menu {
                Button("Remove", role: .destructive) { remove(mod, in: folder) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    private var modIcon: some View {
        Image(systemName: "puzzlepiece.extension")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let busy {
                ProgressView().controlSize(.small)
                Text(busy)
            } else if let message {
                Image(systemName: "info.circle")
                Text(message).textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Dismiss", systemImage: "xmark") { self.message = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a mod from GitHub").font(.headline)
            Text("BetterWhisky reads the latest release and its install steps, and shows you the plan first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Repository", text: $repoInput, prompt: Text(verbatim: "owner/repo or a GitHub link"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(planFromGitHub)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showAddSheet = false
                    addTarget = nil
                }
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: planFromGitHub)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ModPreset.repoSlug(from: repoInput) == nil || busy != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func planSheet(_ pending: PendingPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install \(pending.repo)?").font(.headline)
            Text("Release \(pending.release.tagName), file \(pending.plan.asset.name)")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(describe(pending.plan.rule)).bold()
                ForEach(pending.plan.reasons, id: \.self) { reason in
                    Text(verbatim: "“\(reason)”").font(.callout).foregroundStyle(.secondary)
                }
            }
            let deps = pending.plan.dependencies
            if !deps.isEmpty {
                Text("Also installs: " + (deps.repos + deps.runtimeVerbs).joined(separator: ", "))
                    .font(.callout)
            }
            if !pending.plan.confident {
                Text("The README didn't say clearly how to install this, so this is a guess.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    pendingPlan = nil
                    addTarget = nil
                }
                Button("Install") {
                    pendingPlan = nil
                    install(
                        asset: pending.plan.asset, release: pending.release,
                        name: pending.repo.components(separatedBy: "/").last ?? pending.repo,
                        repo: pending.repo, rule: pending.plan.rule, dependencies: pending.plan.dependencies
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func describe(_ rule: ModInstallRule) -> String {
        let place = rule.subpath.isEmpty ? "the game folder" : rule.subpath
        let action = rule.mode == .extract ? "Unzip into \(place)" : "Copy the file into \(place)"
        if let host = extensionHost { return "\(action) of \(host.name)'s copy of the game" }
        return rule.copyGame ? "\(action) of a new copy of the game" : action
    }

    /// The installed mod that add-ons go into: one with its own copy of the
    /// game and a BepInEx loader (Town of Us), preferring the one that's on.
    /// Its BepInEx only loads plugins from its own folder, never the plain game's.
    private var extensionHost: (name: String, folder: URL)? {
        if let addTarget { return (addTarget.name, addTarget.folder) }
        if let profile = selectedProfile { return (profile.name, profile.folder) }
        var hosts = profiles.filter { ModInstaller.hasBepInEx($0.folder) }
            .map { (name: $0.name, folder: $0.folder) }
        hosts += presets.compactMap { preset -> (name: String, folder: URL)? in
            guard preset.install.ownFolder, let current = installedPreset(preset), current.folder != gameFolder,
                  ModInstaller.hasBepInEx(current.folder) else { return nil }
            return (preset.name, current.folder)
        }
        return hosts.first { isActive($0.folder) } ?? hosts.first
    }

    /// Where an add-on's files go: the host's folder, with the game's own
    /// executable name so the installer treats it as the game folder.
    private func addOnTarget(_ rule: ModInstallRule, fileName: String) -> (rule: ModInstallRule, executable: URL)? {
        guard let host = extensionHost else { return nil }
        var rule = rule
        rule.copyGame = false
        rule.ownFolder = false
        rule.frozenCopy = false
        if fileName.lowercased().hasSuffix(".dll") { rule.subpath = "BepInEx/plugins" }
        return (rule, host.folder.appending(path: program.url.lastPathComponent))
    }

    // MARK: Companion apps

    /// An app that runs next to the game (BetterCrewLink), with a switch to
    /// start it whenever the game starts, whichever profile is on.
    private func companionRow(_ companion: ModCompanion) -> some View {
        _ = companionsChanged
        let exe = companion.installedExecutable(bottleURL: program.bottle.url)
        let starts = Binding(
            get: { companion.startsWithGame(bottleURL: program.bottle.url) },
            set: { isOn in
                companion.setStartsWithGame(isOn, bottleURL: program.bottle.url)
                companionsChanged += 1
            }
        )
        return HStack(spacing: 12) {
            companionIcon(companion)
            VStack(alignment: .leading, spacing: 2) {
                Text(companion.name)
                Text(exe == nil ? companion.summary
                     : starts.wrappedValue ? "Starts with the game" : "Installed · starts on its own")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let exe {
                Toggle("Start with the game", isOn: starts)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Start \(companion.name) whenever you press Play")
                Menu {
                    Button("Check with Mods") { showCompanionCheck(companion) }
                    Button("Open \(companion.name)") { start(companion, at: exe) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exe]) }
                    Divider()
                    Button("Remove", role: .destructive) { removeCompanion(companion) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Button("Install") { installCompanion(companion) }
            }
        }
        .disabled(busy != nil)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func companionIcon(_ companion: ModCompanion) -> some View {
        if let asset = companion.logoAsset, NSImage(named: asset) != nil {
            Image(asset)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
        } else {
            modIcon
        }
    }

    /// The profile that's on, or the first one: what a companion runs alongside.
    private var activeProfile: Profile? {
        profiles.first { isActive($0.folder) } ?? profiles.first
    }

    private func showCompanionCheck(_ companion: ModCompanion) {
        let profile = activeProfile
        let report = companion.compatibility(
            profileFolder: profile?.folder, gameFolder: gameFolder,
            mods: profile.map { ModInstaller.installedMods(in: $0.folder) } ?? []
        )
        let against = profile.map { " with \($0.name)" } ?? ""
        message = (["\(companion.name)\(against):"] + report.findings.map(\.message)).joined(separator: " ")
    }

    /// Unpacks the app out of its Windows installer into this bottle, getting
    /// 7-Zip first when it isn't here yet: the installer can't run under Wine.
    private func installCompanion(_ companion: ModCompanion) {
        Task {
            busy = "Checking \(companion.name)…"
            defer { busy = nil }
            do {
                let version = try await companion.install(bottleURL: program.bottle.url) { step in
                    await MainActor.run { busy = step }
                }
                companionsChanged += 1
                showCompanionCheck(companion)
                message = "Installed \(companion.name) \(version). It's opening now so you can set it up, "
                    + "and from now on it starts with the game. " + (message ?? "")
                // Opened once now: settling its settings first is part of installing it.
                if let exe = companion.installedExecutable(bottleURL: program.bottle.url) {
                    start(companion, at: exe)
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func removeCompanion(_ companion: ModCompanion) {
        do {
            try companion.uninstall(bottleURL: program.bottle.url)
            message = "Removed \(companion.name). Its settings are kept for next time."
        } catch {
            message = "Couldn't remove \(companion.name): \(error.localizedDescription)"
        }
        companionsChanged += 1
    }

    /// Starts the companions that are switched on, next to the game.
    private func startCompanions() {
        for companion in ModCompanion.companions(steamAppId: steamAppId)
        where companion.startsWithGame(bottleURL: program.bottle.url) {
            if let exe = companion.installedExecutable(bottleURL: program.bottle.url) {
                start(companion, at: exe)
            }
        }
    }

    private func start(_ companion: ModCompanion, at exe: URL) {
        Task {
            do {
                try await Wine.runProgram(at: exe, args: companion.launchArguments, bottle: program.bottle)
            } catch {
                message = "Couldn't start \(companion.name): \(error.localizedDescription)"
            }
        }
    }

    // MARK: More than one mod in a profile

    /// Presets that could join a profile: ones not in it yet. A known
    /// conflict still shows, so the check can say why it can't go in.
    private func addablePresets(for profile: Profile) -> [ModPreset] {
        let present = Set(ModInstaller.installedMods(in: profile.folder).map { $0.repo.lowercased() })
        return presets.filter { !present.contains($0.repo.lowercased()) }
    }

    /// Fetches a preset's latest release into a profile that already has a
    /// mod, checking it against that mod (and any others) before anything is written.
    private func addPreset(_ preset: ModPreset, to profile: Profile) {
        Task {
            busy = "Checking \(preset.name) against \(profile.name)…"
            defer { busy = nil }
            do {
                async let readme = GitHubReleases.readme(repo: preset.repo)
                let release = try await GitHubReleases.latestRelease(repo: preset.repo)
                let readmeText = try? await readme
                let plan = ModReadmePlanner.plan(readme: readmeText, release: release, repo: preset.repo)
                guard let asset = release.assets.first(where: { preset.matchesAsset(named: $0.name) })
                    ?? plan?.asset else {
                    message = "\(preset.name) \(release.tagName) has no file to install."
                    return
                }
                // Into this profile's copy as it is: no copy of its own.
                var rule = preset.install
                rule.frozenCopy = false
                rule.ownFolder = false
                rule.copyGame = false
                let text = [release.body, readmeText].compactMap { $0 }.joined(separator: "\n")
                let staged = try await ModInstaller.stage(asset: asset, rule: rule, into: profile.folder)
                await checkThenInstall(
                    staged, name: preset.name, repo: preset.repo, version: release.tagName, rule: rule,
                    host: (profile.name, profile.folder),
                    required: ModGameVersion.required(in: text, modVersion: release.tagName),
                    dependencies: plan?.dependencies ?? ModDependencies()
                )
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Checks a staged mod against the host's mods. Shows what it found
    /// when there's anything to decide; otherwise installs straight away.
    private func checkThenInstall( // swiftlint:disable:this function_parameter_count
        _ staged: StagedMod, name: String, repo: String, version: String, rule: ModInstallRule,
        host: (name: String, folder: URL), required: String?, dependencies: ModDependencies = ModDependencies()
    ) async {
        let report = ModCompatibility.check(
            name: name, repo: repo, staged: staged, profile: host.folder, requiredGameVersion: required
        )
        let pending = PendingCheck(
            name: name, repo: repo, version: version, rule: rule, staged: staged, report: report,
            host: host, dependencies: dependencies
        )
        if report.worst == .info {
            await installChecked(pending)
        } else {
            pendingCheck = pending
        }
    }

    private func installChecked(_ pending: PendingCheck) async {
        defer {
            ModInstaller.discard(pending.staged)
            addTarget = nil
        }
        busy = "Installing \(pending.name) into \(pending.host.name)…"
        defer { busy = nil }
        do {
            let result = try ModInstaller.installStaged(
                pending.staged, version: pending.version, name: pending.name, repo: pending.repo,
                rule: pending.rule, gameExecutable: pending.host.folder.appending(path: program.url.lastPathComponent),
                gameFolder: pending.host.folder, skipping: pending.report.skipped
            )
            let notes = await installDependencies(
                pending.dependencies, into: result, seen: [pending.repo.lowercased()]
            )
            let checked = pending.report.findings.map(\.message)
            message = (["Added \(pending.name) to \(pending.host.name). It loads with the others the next time "
                + "you press Play."] + checked + notes).joined(separator: " ")
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }

    private func discardPendingCheck() {
        // Dismissed without installing: the sheet's Install clears this first.
        if let pending = pendingCheck {
            ModInstaller.discard(pending.staged)
            pendingCheck = nil
            addTarget = nil
        }
    }

    private func compatibilitySheet(_ pending: PendingCheck) -> some View {
        let report = pending.report
        return VStack(alignment: .leading, spacing: 14) {
            Text(report.canInstall
                 ? "Add \(pending.name) to \(pending.host.name)?"
                 : "\(pending.name) can't go in with \(pending.host.name)")
                .font(.headline)
            Text("Checked against the mods already in this profile.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.findings.sorted { $0.severity > $1.severity }, id: \.self) { finding in
                    Label {
                        Text(finding.message).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        switch finding.severity {
                        case .blocker: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        case .info: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(report.canInstall ? "Cancel" : "OK", role: .cancel) {
                    discardPendingCheck()
                }
                .keyboardShortcut(.cancelAction)
                if report.canInstall {
                    Button("Add Anyway") {
                        let accepted = pending
                        pendingCheck = nil
                        Task { await installChecked(accepted) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Takes one mod out of a profile, putting back any files it replaced.
    private func removeAddOn(_ mod: InstalledMod, from profile: Profile) {
        do {
            try ModInstaller.uninstall(mod, from: profile.folder)
            message = "Removed \(mod.name) from \(profile.name)."
        } catch {
            message = error.localizedDescription
        }
        Task { await refresh() }
    }

    // MARK: Actions

    /// A preset may live in a copy of the game folder rather than this one.
    private func installedPreset(_ preset: ModPreset) -> (mod: InstalledMod, folder: URL)? {
        var folders = [gameFolder]
        if preset.install.frozenCopy {
            folders.insert(ModInstaller.modFolder(for: preset.name, game: gameFolder).appending(path: "game"), at: 0)
        } else if preset.install.ownFolder || preset.install.frozenCopy {
            folders.insert(ModInstaller.modFolder(for: preset.name, game: gameFolder), at: 0)
        } else if preset.install.copyGame, let copy = try? copyFolder(for: preset.name) {
            folders.insert(copy, at: 0)
        }
        for folder in folders {
            if let mod = ModInstaller.installedMods(in: folder).first(where: { $0.repo == preset.repo }) {
                return (mod, folder)
            }
        }
        return nil
    }

    /// The Steam app this game is, from its presets.
    private var steamAppId: Int? { presets.first { $0.steamAppId != nil }?.steamAppId }

    /// A mod's frozen copy of the game lives in `<Game> Mods/<Mod>/game`.
    private func isFrozenCopy(_ folder: URL) -> Bool {
        folder.lastPathComponent == "game" && folder != gameFolder
    }

    private func copyFolder(for modName: String) throws -> URL {
        gameFolder.deletingLastPathComponent()
            .appending(path: "\(gameFolder.lastPathComponent) - \(ModInstaller.safeName(modName))")
    }

    private func refresh() async {
        installed = ModInstaller.installedMods(in: gameFolder)
        profiles = ModInstaller.installedModFolders(forGame: gameFolder).compactMap { entry -> Profile? in
            guard isFrozenCopy(entry.folder) else { return nil }
            let mods = ModInstaller.installedMods(in: entry.folder)
            return Profile(
                folder: entry.folder,
                name: ModProfiles.displayName(of: entry.folder, modName: mods.first?.name ?? entry.name),
                mods: mods
            )
        }
        if let appId = steamAppId,
           let selected = SteamModLauncher.selected(appId: appId, bottleURL: program.bottle.url) {
            activeMod = selected.deletingLastPathComponent()
        } else {
            activeMod = ModLoaderRedirect.activeModFolder(gameFolder: gameFolder, bottleURL: program.bottle.url)
        }
        modsChanged += 1
        for preset in presets where latestVersions[preset.repo] == nil {
            latestVersions[preset.repo] = try? await GitHubReleases.latestRelease(repo: preset.repo)
        }
    }

    /// Gets the latest release, then reads that release's notes and the README
    /// for install steps. The preset only fills in what they don't say: which
    /// file to take, and whether to install into a copy of the game.
    private func installPreset(_ preset: ModPreset, into profile: Profile? = nil) {
        // A profile is updated in its own folder; a first install makes the mod's.
        let folderName = profile?.folder.deletingLastPathComponent().lastPathComponent
        Task {
            busy = "Checking \(preset.name)…"
            defer { busy = nil }
            do {
                async let readme = GitHubReleases.readme(repo: preset.repo)
                let release = try await GitHubReleases.latestRelease(repo: preset.repo)
                latestVersions[preset.repo] = release
                let readmeText = try? await readme
                let plan = ModReadmePlanner.plan(readme: readmeText, release: release, repo: preset.repo)
                guard let asset = release.assets.first(where: { preset.matchesAsset(named: $0.name) })
                    ?? plan?.asset else {
                    message = "\(preset.name) \(release.tagName) has no file to install."
                    return
                }
                var rule = preset.install
                if let plan, plan.confident, plan.asset == asset {
                    rule = plan.rule
                    rule.copyGame = rule.copyGame || preset.install.copyGame
                    rule.ownFolder = preset.install.ownFolder
                    rule.frozenCopy = preset.install.frozenCopy
                }
                if preset.install.frozenCopy,
                   !prepareFrozenCopy(for: preset, release: release, readme: readmeText, folderName: folderName) {
                    return
                }
                install(
                    asset: asset, release: release, name: preset.name, repo: preset.repo,
                    rule: rule, dependencies: plan?.dependencies ?? ModDependencies(), profile: folderName
                )
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Decides whether this release can go in, by the game version it needs:
    /// a fresh copy of the current game, the frozen copy as it is, or not at all.
    private func prepareFrozenCopy(
        for preset: ModPreset, release: GitHubRelease, readme: String?, folderName: String? = nil
    ) -> Bool {
        let text = [release.body, readme].compactMap { $0 }.joined(separator: "\n")
        let required = ModGameVersion.required(in: text, modVersion: release.tagName)
        let game = ModGameVersion.installed(gameFolder: gameFolder)
        let copy = ModInstaller.modFolder(for: folderName ?? preset.name, game: gameFolder).appending(path: "game")
        let hasCopy = FileManager.default.fileExists(atPath: copy.path(percentEncoded: false))
        switch ModGameVersion.decide(
            required: required, game: game, copy: hasCopy ? ModInstaller.frozenVersion(copy) : nil, hasCopy: hasCopy
        ) {
        case .blocked(let required, let game):
            message = "\(preset.name) \(release.tagName) needs Among Us \(required), and this is \(game). "
                + "Wait for a mod update that supports \(game)."
            return false
        case .keep(let required):
            message = "\(preset.name) \(release.tagName) is for Among Us \(required). Keeping the version you have."
            return false
        case .install(let freshCopy):
            if freshCopy, hasCopy {
                if let appId = steamAppId, SteamModLauncher.selected(appId: appId, bottleURL: program.bottle.url)?
                    .path.hasPrefix(copy.path) == true {
                    try? SteamModLauncher.select(nil, appId: appId, bottleURL: program.bottle.url)
                }
                try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            }
            return true
        }
    }

    private func planFromGitHub() {
        guard let repo = ModPreset.repoSlug(from: repoInput) else { return }
        Task {
            busy = "Reading \(repo) on GitHub…"
            defer { busy = nil }
            do {
                async let readme = GitHubReleases.readme(repo: repo)
                let release = try await GitHubReleases.latestRelease(repo: repo)
                guard let plan = ModReadmePlanner.plan(readme: try await readme, release: release, repo: repo) else {
                    message = "\(repo) \(release.tagName) has no .zip or .dll to install."
                    return
                }
                showAddSheet = false
                pendingPlan = PendingPlan(repo: repo, release: release, plan: plan)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func install(
        asset: GitHubRelease.Asset, release: GitHubRelease, name: String, repo: String,
        rule: ModInstallRule, dependencies: ModDependencies = ModDependencies(), profile: String? = nil
    ) {
        Task {
            busy = "Installing \(name) \(release.tagName)…"
            defer { busy = nil }
            do {
                // A mod that isn't a preset is an add-on for the installed modded copy, if there is one.
                let isPreset = presets.contains { $0.repo == repo }
                if !isPreset || !profiles.isEmpty, let host = extensionHost,
                   let addOn = addOnTarget(rule, fileName: asset.name) {
                    busy = "Checking \(name) against \(host.name)'s mods…"
                    let staged = try await ModInstaller.stage(asset: asset, rule: addOn.rule, into: host.folder)
                    await checkThenInstall(
                        staged, name: name, repo: repo, version: release.tagName, rule: addOn.rule,
                        host: host, required: nil, dependencies: dependencies
                    )
                    return
                }
                let addOn: (rule: ModInstallRule, executable: URL)? = nil
                let result = try await ModInstaller.install(
                    asset: asset, version: release.tagName, name: name, repo: repo,
                    rule: addOn?.rule ?? rule, gameExecutable: addOn?.executable ?? program.url,
                    profile: isPreset ? profile : nil
                )
                let notes = await installDependencies(dependencies, into: result, seen: [repo.lowercased()])
                if isFrozenCopy(result.gameFolder), let preset = presets.first(where: { $0.repo == repo }) {
                    await preset.downloadLogo(into: result.gameFolder.deletingLastPathComponent())
                }
                finished(result, notes: notes)
                await connectAccount(forMod: name)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// The last setup step for mods that need the game's account (Town of
    /// Us): the plain game's one-time sign-in, so Play opens the mod
    /// straight away later. Play does it too if this is skipped.
    private func connectAccount(forMod name: String) async {
        guard let preset = ModPreset.named(name), preset.accountSave != nil,
              let appId = preset.steamAppId else { return }
        busy = "Connecting your game account…"
        defer { busy = nil }
        let ready = await ModAccountPrimer.prepare(
            appId: appId, gameFolder: gameFolder, modName: name, bottle: program.bottle
        )
        if !ready {
            message = (message.map { $0 + " " } ?? "")
                + "Your game account isn't connected yet; it will be the first time you press Play."
        }
    }

    /// A file chosen with Add from File…: read it while the picker's access lasts.
    private func installPicked(_ file: URL) async {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        await installLocalFile(file)
    }

    private func installDropped(_ file: URL) {
        Task { await installLocalFile(file) }
    }

    private func installLocalFile(_ file: URL) async {
        busy = "Installing \(file.lastPathComponent)…"
        defer { busy = nil }
        do {
            if let host = extensionHost, let addOn = addOnTarget(
                ModInstallRule(mode: file.pathExtension.lowercased() == "dll" ? .copyFile : .extract, subpath: ""),
                fileName: file.lastPathComponent
            ) {
                let name = file.deletingPathExtension().lastPathComponent
                let staged = try await ModInstaller.stageLocal(file: file, rule: addOn.rule, into: host.folder)
                // Files the profile already has belong to its other mods: keep them.
                let kept = staged.keepingExisting(in: host.folder, except: "local/\(name)")
                await checkThenInstall(
                    staged, name: name, repo: "local/\(name)", version: "local", rule: addOn.rule,
                    host: host, required: nil
                )
                if !kept.isEmpty {
                    let note = "Kept \(kept.count) file\(kept.count == 1 ? "" : "s") \(host.name)'s other mods "
                        + "already had instead of replacing \(kept.count == 1 ? "it" : "them")."
                    message = [message, note].compactMap { $0 }.joined(separator: " ")
                }
            } else {
                finished(try await ModInstaller.installLocal(file: file, gameExecutable: program.url))
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func finished(_ result: ModInstallResult, notes: [String] = []) {
        useModLoader(in: result)
        if !presets.contains(where: { $0.repo == result.mod.repo }), let host = extensionHost,
           host.folder.standardizedFileURL.path == result.gameFolder.standardizedFileURL.path {
            message = ([
                "Added \(result.mod.name) to \(host.name). It loads the next time you press Play."
            ] + notes).joined(separator: " ")
            Task { await refresh() }
            return
        }
        if isFrozenCopy(result.gameFolder) {
            switchOn(result.gameFolder)
            let version = ModInstaller.frozenVersion(result.gameFolder).map { " for Among Us \($0)" } ?? ""
            message = "Installed \(result.mod.name)\(version). It's in the Library as its own game. "
                + "The first start takes a few minutes."
        } else if result.executable == program.url, result.gameFolder != gameFolder {
            // A mod in its own folder: switch the game's loader over to it.
            do {
                try ModLoaderRedirect.activate(
                    modFolder: result.gameFolder, gameFolder: gameFolder, bottleURL: program.bottle.url
                )
                message = "Installed \(result.mod.name). Press Play to start it through Steam. "
                    + "The first launch can take a few minutes."
            } catch {
                message = "Installed \(result.mod.name), but couldn't switch it on: \(error.localizedDescription)"
            }
        } else if result.gameFolder != gameFolder {
            // The mod went into a copy of the game: pin the copy so it has its own launch button.
            let bottle = program.bottle
            if !bottle.settings.pins.contains(where: { $0.url == result.executable }) {
                bottle.settings.pins.append(PinnedProgram(
                    name: "\(program.name.replacingOccurrences(of: ".exe", with: "")) (\(result.mod.name))",
                    url: result.executable
                ))
            }
            message = "Installed \(result.mod.name) into “\(result.gameFolder.lastPathComponent)”. "
                + "It's pinned in the bottle. The first launch can take a few minutes."
        } else {
            message = "Installed \(result.mod.name) (\(result.mod.files.count) files)."
        }
        if !notes.isEmpty, let current = message {
            message = ([current] + notes).joined(separator: "\n")
        }
        Task { await refresh() }
    }

    /// Switches the loader to `modFolder` (or off, for nil) and starts the
    /// game the way its preset says: through Steam for Steam games, whose
    /// sign-in only works when Steam launches them.
    private func play(_ preset: ModPreset, modFolder: URL?) {
        if let appId = preset.steamAppId, modFolder.map(isFrozenCopy) ?? true, preset.install.frozenCopy {
            Task {
                do {
                    busy = modFolder == nil ? nil : "Getting Steam ready…"
                    defer { busy = nil }
                    let steamWasRunning = await SteamModLauncher.isSteamRunning()
                    let started = Date()
                    if let modFolder {
                        // Any mod with its own account copy starts signed in, not as a new player.
                        ModAccountPrimer.seedDiscoveredSaves(bottleURL: program.bottle.url)
                        SteamModLauncher.ensureLoaderOverride(gameExecutable: program.url, bottle: program.bottle)
                        try await SteamModLauncher.prepare(appId: appId, bottle: program.bottle)
                        try SteamModLauncher.select(
                            ModInstaller.mainExecutable(in: modFolder, preferring: program.name),
                            appId: appId, bottleURL: program.bottle.url
                        )
                    } else {
                        try SteamModLauncher.select(nil, appId: appId, bottleURL: program.bottle.url)
                    }
                    try SteamLauncher.launch(appId: appId, bottle: program.bottle)
                    startCompanions()
                    message = nil
                    launchRequest = makeLaunchRequest(
                        preset, appId: appId, modFolder: modFolder, steamWasRunning: steamWasRunning, started: started
                    )
                } catch {
                    message = error.localizedDescription
                }
                await refresh()
            }
            return
        }
        do {
            if let modFolder {
                try ModLoaderRedirect.activate(
                    modFolder: modFolder, gameFolder: gameFolder, bottleURL: program.bottle.url
                )
            } else {
                try ModLoaderRedirect.deactivate(gameFolder: gameFolder)
            }
            if preset.launch == .steam, let appId = preset.steamAppId {
                try SteamLauncher.launch(appId: appId, bottle: program.bottle)
                startCompanions()
                message = "Starting \(modFolder == nil ? program.name : preset.name) through Steam…"
            } else {
                program.run()
            }
        } catch {
            message = error.localizedDescription
        }
        Task { await refresh() }
    }

    private func makeLaunchRequest(
        _ preset: ModPreset, appId: Int, modFolder: URL?, steamWasRunning: Bool, started: Date
    ) -> LaunchRequest {
        let root = SteamLibrary.detectInstall(bottleURL: program.bottle.url)
        return LaunchRequest(
            title: program.name.replacingOccurrences(of: ".exe", with: ""),
            modName: modFolder == nil ? nil : preset.name,
            artworkURL: root.flatMap { SteamLibrarySource.artworkURL(appID: appId, steamRoot: $0) },
            monitor: ModLaunchMonitor(
                bottleURL: program.bottle.url, appId: appId,
                gameFolder: modFolder ?? gameFolder, modded: modFolder != nil, startedAt: started
            ),
            steamWasRunning: steamWasRunning,
            firstStart: modFolder.map { folder in
                let interop = folder.appending(path: "BepInEx/interop").path(percentEncoded: false)
                return ((try? FileManager.default.contentsOfDirectory(atPath: interop)) ?? []).isEmpty
            } ?? false
        )
    }

    private func isActive(_ folder: URL) -> Bool {
        if isFrozenCopy(folder) {
            return activeMod?.standardizedFileURL.path == folder.standardizedFileURL.path
        }
        return activeMod != nil
            && ModLoaderRedirect.pointsAt(folder, gameFolder: gameFolder, bottleURL: program.bottle.url)
    }

    private func switchOn(_ folder: URL) {
        if isFrozenCopy(folder), let appId = steamAppId {
            do {
                try SteamModLauncher.select(
                    ModInstaller.mainExecutable(in: folder, preferring: program.name),
                    appId: appId, bottleURL: program.bottle.url
                )
            } catch {
                message = error.localizedDescription
            }
            Task { await refresh() }
            return
        }
        do {
            try ModLoaderRedirect.activate(modFolder: folder, gameFolder: gameFolder, bottleURL: program.bottle.url)
            message = nil
        } catch {
            message = error.localizedDescription
        }
        Task { await refresh() }
    }

    private func turnOffMods() {
        do {
            if let appId = steamAppId {
                try SteamModLauncher.select(nil, appId: appId, bottleURL: program.bottle.url)
            }
            try ModLoaderRedirect.deactivate(gameFolder: gameFolder)
            message = nil
        } catch {
            message = error.localizedDescription
        }
        Task { await refresh() }
    }

    /// Installs what a mod needs: other mods from their latest releases (into
    /// the same game folder, following their own install steps) and Windows
    /// runtimes through winetricks. Returns a line per dependency for the user.
    private func installDependencies(
        _ deps: ModDependencies, into result: ModInstallResult, seen: Set<String>, depth: Int = 0
    ) async -> [String] {
        var notes: [String] = []
        var seen = seen
        if deps.needsBepInEx, !ModInstaller.hasBepInEx(result.gameFolder) {
            notes.append("This mod needs BepInEx, which isn't in its download. Use a build that includes it.")
        }
        for repo in deps.repos where depth < 3 && !seen.contains(repo.lowercased()) {
            seen.insert(repo.lowercased())
            let name = repo.components(separatedBy: "/").last ?? repo
            let present = ModInstaller.installedMods(in: result.gameFolder)
            if present.contains(where: { $0.repo.lowercased() == repo.lowercased() })
                || ModInstaller.bundles(plugin: name, in: result.gameFolder) {
                continue
            }
            busy = "Installing dependency \(repo)…"
            do {
                async let readme = GitHubReleases.readme(repo: repo)
                let release = try await GitHubReleases.latestRelease(repo: repo)
                guard let plan = ModReadmePlanner.plan(readme: try? await readme, release: release, repo: repo) else {
                    notes.append("Dependency \(repo) has nothing to install.")
                    continue
                }
                var rule = plan.rule
                rule.copyGame = false
                if plan.asset.name.lowercased().hasSuffix(".dll"), ModInstaller.hasBepInEx(result.gameFolder) {
                    rule.subpath = "BepInEx/plugins"
                }
                // Into the mod's folder, next to the loader it plugs into.
                _ = try await ModInstaller.install(
                    asset: plan.asset, version: release.tagName, name: name, repo: repo,
                    rule: rule, gameExecutable: result.gameFolder.appending(path: result.executable.lastPathComponent)
                )
                notes.append("Installed dependency \(name) \(release.tagName).")
                notes += await installDependencies(plan.dependencies, into: result, seen: seen, depth: depth + 1)
            } catch {
                notes.append("Dependency \(repo) failed: \(error.localizedDescription)")
            }
        }
        notes += await installRuntimes(deps.runtimeVerbs)
        return notes
    }

    /// Windows runtimes through winetricks, skipping a VC++ runtime that's already there.
    private func installRuntimes(_ verbs: [String]) async -> [String] {
        var notes: [String] = []
        for verb in verbs {
            if verb.hasPrefix("vcrun"), VCRedistDetector.isInstalled(prefixURL: program.bottle.url) { continue }
            busy = "Installing \(verb)…"
            var outcome = "\(verb) didn't finish."
            for await event in Winetricks.installVerb(verb, for: program.bottle) {
                switch event {
                case .completed(let code): outcome = code == 0 ? "Installed \(verb)." : "\(verb) failed (exit \(code))."
                case .failed(let reason): outcome = "\(verb) failed: \(reason)"
                default: break
                }
            }
            notes.append(outcome)
        }
        return notes
    }

    /// BepInEx and similar loaders ship their own winhttp.dll, which Wine
    /// ignores in favour of its built-in one unless the game is told otherwise.
    private func useModLoader(in result: ModInstallResult) {
        let loader = result.gameFolder.appending(path: "winhttp.dll")
        guard FileManager.default.fileExists(atPath: loader.path(percentEncoded: false)) else { return }
        if isFrozenCopy(result.gameFolder) {
            SteamModLauncher.ensureLoaderOverride(gameExecutable: program.url, bottle: program.bottle)
            return
        }
        let target = result.executable == program.url
            ? program : Program(url: result.executable, bottle: program.bottle)
        var overrides = target.settings.overrides ?? ProgramOverrides()
        var dlls = (overrides.dllOverrides ?? []).filter { $0.dllName.lowercased() != "winhttp" }
        dlls.append(DLLOverrideEntry(dllName: "winhttp", mode: .nativeThenBuiltin))
        overrides.dllOverrides = dlls
        target.settings.overrides = overrides
    }

    private func remove(_ mod: InstalledMod, in folder: URL? = nil) {
        do {
            let folder = folder ?? gameFolder
            if isFrozenCopy(folder) {
                if let appId = steamAppId, activeMod?.standardizedFileURL.path == folder.standardizedFileURL.path {
                    try SteamModLauncher.select(nil, appId: appId, bottleURL: program.bottle.url)
                }
                let modFolder = folder.deletingLastPathComponent()
                try FileManager.default.removeItem(at: modFolder)
                let modsRoot = modFolder.deletingLastPathComponent()
                if (try? FileManager.default.contentsOfDirectory(atPath: modsRoot.path(percentEncoded: false)))?
                    .filter({ !$0.hasPrefix(".") }).isEmpty == true {
                    try? FileManager.default.removeItem(at: modsRoot)
                }
                message = "Removed \(ModProfiles.displayName(of: folder, modName: mod.name))."
                Task { await refresh() }
                return
            }
            try ModInstaller.uninstall(mod, from: folder)
            if folder != gameFolder, folder.deletingLastPathComponent().lastPathComponent.hasSuffix(" Mods") {
                if ModLoaderRedirect.pointsAt(folder, gameFolder: gameFolder, bottleURL: program.bottle.url) {
                    try ModLoaderRedirect.remove(gameFolder: gameFolder)
                }
                try? FileManager.default.removeItem(at: folder)
                let modsRoot = folder.deletingLastPathComponent()
                if (try? FileManager.default.contentsOfDirectory(atPath: modsRoot.path(percentEncoded: false)))?
                    .filter({ !$0.hasPrefix(".") }).isEmpty == true {
                    try? FileManager.default.removeItem(at: modsRoot)
                }
            }
            message = "Removed \(mod.name)."
        } catch {
            message = error.localizedDescription
        }
        Task { await refresh() }
    }
}

/// A profile's picture: its mod's logo on a dark tile, or its initials on a
/// colour picked from its name, so each profile keeps the same look.
private struct ProfileAvatar: View {
    let name: String
    var image: NSImage?
    let size: CGFloat

    private static let colors: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .blue, .indigo, .purple, .pink]

    private var color: Color {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.colors[abs(sum) % Self.colors.count]
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == ":" })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size / 4, style: .continuous)
        Group {
            if let image {
                shape.fill(LinearGradient(colors: [color.opacity(0.55), .black.opacity(0.85)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(nsImage: image).resizable().scaledToFit().padding(size * 0.08)
                    }
            } else {
                shape.fill(color.gradient)
                    .overlay {
                        Text(initials.isEmpty ? "?" : initials)
                            .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    }
            }
        }
        .frame(width: size, height: size)
        .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
