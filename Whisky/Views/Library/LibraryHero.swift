//
//  LibraryHero.swift
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
import SwiftUI
import WhiskyKit

/// The top of the Library: the game played last, full width, one click from
/// playing again. Same language as the Store's banner, so the two pages read
/// as one app.
struct LibraryHero: View {
    let row: LibraryRow
    let state: LibraryEntryState
    let play: () -> Void
    var stop: (() -> Void)?
    var mods: (() -> Void)?
    var about: (() -> Void)?

    @State private var art: StoreArtwork?
    @State private var localArt: NSImage?

    private var item: LibraryEntry { row.item }

    private var steamAppID: Int? {
        if case let .steam(appID) = item.launch { return appID }
        return nil
    }

    /// The game's name without the " · Mod" suffix modded cards carry.
    private var baseName: String {
        guard let mod = item.mod?.modName else { return item.name }
        return item.name.replacingOccurrences(of: " · \(mod)", with: "")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            LinearGradient(
                colors: [.black.opacity(0.85), .black.opacity(0.4), .clear],
                startPoint: .leading, endPoint: .init(x: 0.75, y: 0.5)
            )
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 14) {
                caption
                title
                actions
            }
            .padding(32)
        }
        .frame(height: 400)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
        .task(id: item.id) { await loadArt() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Continue playing \(baseName)")
    }

    // MARK: Art

    @ViewBuilder
    private var backdrop: some View {
        if let steamAppID {
            KeyArt(appId: steamAppID, heroURL: art?.hero, drift: true)
                .id(art?.hero)
        } else if let localArt {
            // A non-Steam program: its own art, enlarged and softened into a
            // backdrop, with the crisp copy on the right.
            ZStack {
                Image(nsImage: localArt).resizable().scaledToFill().blur(radius: 50).opacity(0.8)
                Image(nsImage: localArt).resizable().scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 220)
                    .shadow(color: .black.opacity(0.5), radius: 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 64)
            }
            .background(.black)
            .clipped()
        } else {
            LinearGradient(colors: [.indigo, .black], startPoint: .topTrailing, endPoint: .bottomLeading)
        }
    }

    private func loadArt() async {
        if let steamAppID {
            art = await SteamStore.shared.artwork(appIds: [steamAppID])[steamAppID]
            return
        }
        let url = item.artworkURL ?? item.logoURL ?? item.iconURL
        guard let url else { return }
        localArt = await Task.detached { NSImage(contentsOf: url) }.value
    }

    // MARK: Text

    private var caption: some View {
        HStack(spacing: 8) {
            Text("CONTINUE PLAYING")
                .font(.caption.weight(.bold))
                .kerning(1.2)
            if let played = row.lastPlayed {
                Text("·")
                Text(played.formatted(.relative(presentation: .named)).uppercased())
                    .font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(.white.opacity(0.75))
    }

    @ViewBuilder
    private var title: some View {
        if let steamAppID {
            GameLogo(appId: steamAppID, name: baseName, maxHeight: 110)
        } else {
            Text(baseName)
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.5), radius: 8)
        }
        HStack(spacing: 8) {
            if let mod = item.mod?.modName {
                chip(mod, systemImage: "puzzlepiece.extension.fill", tint: .green)
            }
            if let bottle = row.bottleName {
                chip(bottle, systemImage: "shippingbox.fill", tint: .white)
            }
            if item.source == .steam {
                chip("Steam", systemImage: "gamecontroller.fill", tint: .white)
            }
        }
    }

    private func chip(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .cardGlass(.capsule)
            .colorScheme(.dark)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                state == .running ? stop?() : play()
            } label: {
                HStack(spacing: 8) {
                    switch state {
                    case .launching:
                        ProgressView().controlSize(.small).tint(.black)
                        Text("Starting…")
                    case .running:
                        Image(systemName: "stop.fill")
                        Text("Stop")
                    case .idle:
                        Image(systemName: "play.fill")
                        Text("Play")
                    }
                }
                .font(.headline)
                .padding(.horizontal, 22).padding(.vertical, 11)
                .background(.white, in: Capsule())
                .foregroundStyle(.black)
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .disabled(state == .launching)
            .keyboardShortcut(.defaultAction)
            .animation(.smooth, value: state)

            if state == .running {
                Label("Running", systemImage: "circle.fill")
                    .font(.caption.weight(.semibold))
                    .imageScale(.small)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .cardGlass(.capsule)
                    .transition(.opacity.combined(with: .scale))
            }
            if let mods {
                roundButton("puzzlepiece.extension", help: "Mods", action: mods)
            }
            if let about {
                roundButton("info", help: "About This Game", action: about)
            }
        }
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 42, height: 42)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .cardGlass(.circle, interactive: true)
        .colorScheme(.dark)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A titled row of library cards that snaps to whole cards, with arrows on
/// hover: the Store's shelf, for games you have.
struct LibraryShelf<Card: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let rows: [LibraryRow]
    @ViewBuilder let card: (LibraryRow) -> Card

    @State private var position = ScrollPosition(idType: String.self)
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: systemImage).font(.title2.weight(.semibold))
                Spacer()
                HStack(spacing: 8) {
                    arrow("chevron.left", step: -2)
                    arrow("chevron.right", step: 2)
                }
                .opacity(hovering && rows.count > 3 ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 18) {
                    ForEach(rows) { row in
                        card(row)
                            .id(row.id)
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content.opacity(phase.isIdentity ? 1 : 0.6).scaleEffect(phase.isIdentity ? 1 : 0.96)
                            }
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 8)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition($position)
        }
        .onHover { hovering = $0 }
    }

    private func arrow(_ symbol: String, step: Int) -> some View {
        Button {
            let ids = rows.map(\.id)
            let current = position.viewID(type: String.self).flatMap { ids.firstIndex(of: $0) } ?? 0
            let next = max(0, min(ids.count - 1, current + step))
            withAnimation(.smooth) { position.scrollTo(id: ids[next], anchor: .leading) }
        } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .cardGlass(.circle, interactive: true)
    }
}
