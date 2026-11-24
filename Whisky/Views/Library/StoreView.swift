//
//  StoreView.swift
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

/// One shelf on the Store page.
private struct StoreShelf: Identifiable {
    let title: String
    let systemImage: String
    let items: [StoreListing]
    var id: String { title }
}

/// Browse the Steam Store: trending, most played, sales and search.
///
/// Buying happens in Steam. The buy button opens the game's page in the Steam
/// client inside a bottle, so checkout and payment stay in Steam's own window,
/// and the game is then ready to install where it will run.
struct StoreView: View {
    @State private var shelves: [StoreShelf] = []
    @State private var hero: [(StoreListing, URL)] = []
    @State private var results: [StoreListing] = []
    @State private var searching = false
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?
    @State private var selected: StoreListing?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shelves in the order they appear, whichever answers first.
    private static let order = ["Trending", "Most Played", "Top Sellers", "Specials", "New Releases", "Coming Soon"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                GlassSearchBar(text: $query, prompt: "Search the Steam Store")
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                if !query.isEmpty {
                    searchResults
                        .transition(.opacity)
                } else if let error, shelves.isEmpty, !loading {
                    ContentUnavailableView {
                        Label("Store Unavailable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    if !hero.isEmpty {
                        StoreHero(items: hero.map(\.0), heroArt: heroArt) { show($0) }
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                    ForEach(shelves) { shelf in
                        StoreShelfView(shelf: shelf) { show($0) }
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if loading {
                        ForEach(0..<(shelves.isEmpty ? 3 : 1), id: \.self) { _ in SkeletonShelf() }
                    }
                }
            }
            .padding(24)
            .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: shelves.map(\.id))
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: query.isEmpty)
        }
        // Covered by the game page: out of reach of the keyboard and VoiceOver too.
        .accessibilityHidden(selected != nil)
        .task { await load() }
        .task(id: query) {
            guard !query.isEmpty else { results = []; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = (try? await SteamStore.shared.search(query)) ?? []
            withAnimation(reduceMotion ? nil : .smooth) { results = found }
            searching = false
        }
        .overlay {
            if let listing = selected {
                GameDetailView(appId: listing.appId, fallbackName: listing.name) {
                    withAnimation(.smooth(duration: 0.35)) { selected = nil }
                }
                .id(listing.id)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Results", systemImage: "magnifyingglass").font(.title2.weight(.semibold))
                if searching { ProgressView().controlSize(.small) }
            }
            if results.isEmpty, !searching {
                ContentUnavailableView.search(text: query)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 18)], spacing: 22) {
                    ForEach(results) { listing in
                        Button { show(listing) } label: { StoreTile(listing: listing) }
                            .buttonStyle(PressableStyle())
                    }
                }
            }
        }
    }

    private var heroArt: [Int: URL] {
        Dictionary(hero.map { ($0.0.appId, $0.1) }) { first, _ in first }
    }

    private func show(_ listing: StoreListing) {
        withAnimation(.smooth(duration: 0.4)) { selected = listing }
    }

    /// Each shelf goes up as soon as it answers, so the page fills in rather
    /// than sitting on a spinner for the slowest source.
    private func load() async {
        loading = true
        error = nil
        let store = SteamStore.shared
        Task {
            // The newest popular games, as soon as they and their art are known.
            let fresh = (try? await store.popularNew(limit: 15)) ?? []
            let picked = await Self.heroPicks(from: fresh)
            withAnimation(.smooth(duration: 0.5)) { hero = picked }
        }
        await withTaskGroup(of: [StoreShelf].self) { group in
            group.addTask {
                guard let items = try? await store.trending(), !items.isEmpty else { return [] }
                return [StoreShelf(title: "Trending", systemImage: "flame", items: items)]
            }
            group.addTask {
                guard let items = try? await store.mostPlayed(), !items.isEmpty else { return [] }
                return [StoreShelf(title: "Most Played", systemImage: "person.3", items: items)]
            }
            group.addTask {
                ((try? await store.featured()) ?? []).map {
                    StoreShelf(title: $0.title, systemImage: Self.icon(for: $0.title), items: $0.items)
                }
            }
            for await arrived in group where !arrived.isEmpty {
                var merged = shelves.filter { old in !arrived.contains { $0.id == old.id } } + arrived
                merged.sort { (Self.order.firstIndex(of: $0.id) ?? 99) < (Self.order.firstIndex(of: $1.id) ?? 99) }
                shelves = merged
            }
        }
        if shelves.isEmpty { error = "Couldn't reach the Steam Store. Check your connection." }
        loading = false
    }

    /// Up to five games, in the order given, that have wide banner art,
    /// each carrying that art's address.
    private static func heroPicks(from candidates: [StoreListing]) async -> [(StoreListing, URL)] {
        var seen = Set<Int>()
        let unique = candidates.filter { seen.insert($0.appId).inserted }
        let art = await SteamStore.shared.artwork(appIds: unique.map(\.appId))
        return Array(unique.compactMap { listing in art[listing.appId]?.hero.map { (listing, $0) } }.prefix(5))
    }

    private static func icon(for title: String) -> String {
        switch title {
        case "Top Sellers": "chart.line.uptrend.xyaxis"
        case "Specials": "tag"
        case "New Releases": "sparkles"
        case "Coming Soon": "calendar"
        default: "square.grid.2x2"
        }
    }
}

/// A titled row of tiles that snaps to whole tiles, with arrows on hover.
private struct StoreShelfView: View {
    let shelf: StoreShelf
    let open: (StoreListing) -> Void
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(shelf.title, systemImage: shelf.systemImage)
                    .font(.title2.weight(.semibold))
                Spacer()
                HStack(spacing: 8) {
                    arrow("chevron.left", step: -3)
                    arrow("chevron.right", step: 3)
                }
                .opacity(hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 18) {
                    ForEach(shelf.items) { listing in
                        Button { open(listing) } label: { StoreTile(listing: listing) }
                            .buttonStyle(PressableStyle())
                            .frame(width: 260)
                            .id(listing.id)
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content.opacity(phase.isIdentity ? 1 : 0.6)
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
            let ids = shelf.items.map(\.id)
            let current = position.viewID(type: Int.self).flatMap { ids.firstIndex(of: $0) } ?? 0
            let next = max(0, min(ids.count - 1, current + step))
            withAnimation(.smooth) { position.scrollTo(id: ids[next], anchor: .leading) }
        } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .cardGlass(.circle, interactive: true)
    }
}

/// Grey shapes where a shelf is about to be, gently shimmering.
private struct SkeletonShelf: View {
    @State private var lit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 6).frame(width: 160, height: 22)
            HStack(spacing: 18) {
                ForEach(0..<5, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).aspectRatio(460 / 215, contentMode: .fit)
                        RoundedRectangle(cornerRadius: 4).frame(width: 140, height: 12)
                        RoundedRectangle(cornerRadius: 4).frame(width: 60, height: 10)
                    }
                    .frame(width: 260)
                }
            }
        }
        .foregroundStyle(.quaternary)
        .opacity(lit ? 1 : 0.5)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { lit = true }
        }
        .accessibilityHidden(true)
    }
}

/// Sinks a little under the pointer, the way the system's own cards do.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: configuration.isPressed)
    }
}

/// A game's header art, fading in when it arrives and falling back to the
/// store details' own address for games whose art lives under a hashed path.
struct StoreArt: View {
    let listing: StoreListing
    @State private var artURL: URL?

    var body: some View {
        let fade = Transaction(animation: .easeOut(duration: 0.3))
        AsyncImage(url: artURL ?? listing.headerURL, transaction: fade) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(460 / 215, contentMode: .fill).transition(.opacity)
            } else {
                Rectangle().fill(.quaternary).aspectRatio(460 / 215, contentMode: .fit)
                    .task(id: phase.error != nil) {
                        guard phase.error != nil, artURL == nil else { return }
                        artURL = try? await SteamStore.shared.metadata(appId: listing.appId).headerURL
                    }
            }
        }
    }
}

/// A store game: its header art, name and price.
struct StoreTile: View {
    let listing: StoreListing
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StoreArt(listing: listing)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.primary.opacity(hovering ? 0.2 : 0.06), lineWidth: 1)
                }
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.1), radius: hovering ? 14 : 4, y: hovering ? 8 : 2)
                .scaleEffect(hovering ? 1.03 : 1)

            Text(listing.name).font(.headline).lineLimit(1)
            PriceTag(price: listing.isFree ? "Free" : listing.price, discount: listing.discountPercent)
        }
        .animation(.spring(duration: 0.3, bounce: 0.2), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PriceTag: View {
    let price: String?
    let discount: Int

    var body: some View {
        HStack(spacing: 6) {
            if discount > 0 {
                Text("−\(discount)%")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.green.opacity(0.2), in: Capsule())
                    .foregroundStyle(.green)
            }
            if let price {
                Text(price).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
