//
//  GameDetailView.swift
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

/// A game's wide key art: Steam's 1920px library hero when it has one,
/// otherwise its header art over a blurred, enlarged copy of itself so the
/// frame is still filled edge to edge.
struct KeyArt: View {
    let appId: Int
    /// The game's real hero address, when known; the legacy fixed one otherwise.
    var heroURL: URL?
    var headerURL: URL?
    /// Slowly drifts in, the way Apple TV's banners do.
    var drift = false

    @State private var heroFailed = false
    @State private var zoomed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let fade = Transaction(animation: .easeOut(duration: 0.5))

    var body: some View {
        Color.black
            .overlay {
                if heroFailed {
                    fallback
                } else {
                    AsyncImage(url: heroURL ?? SteamStore.heroURL(appId: appId), transaction: Self.fade) { phase in
                        switch phase {
                        case let .success(image): image.resizable().scaledToFill().transition(.opacity)
                        case .failure: Color.clear.onAppear { heroFailed = true }
                        default: Color.clear
                        }
                    }
                }
            }
            .scaleEffect(zoomed ? 1.08 : 1)
            .clipped()
            .onAppear {
                guard drift, !reduceMotion else { return }
                withAnimation(.linear(duration: 14)) { zoomed = true }
            }
    }

    private var fallback: some View {
        AsyncImage(url: headerURL ?? SteamStore.headerURL(appId: appId)) { image in
            ZStack {
                image.resizable().scaledToFill().blur(radius: 40).opacity(0.7)
                image.resizable().scaledToFit().shadow(color: .black.opacity(0.5), radius: 24)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 48)
            }
        } placeholder: {
            Color.clear
        }
    }
}

/// The game's transparent logo, or its name set large when it has none.
struct GameLogo: View {
    let appId: Int
    let name: String
    var maxHeight: CGFloat = 120

    var body: some View {
        let fade = Transaction(animation: .easeOut(duration: 0.4))
        return AsyncImage(url: SteamStore.logoURL(appId: appId), transaction: fade) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
                    .frame(maxWidth: maxHeight * 3.2, maxHeight: maxHeight, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                    .transition(.opacity)
            } else if case .failure = phase {
                title
            } else {
                title.opacity(0)
            }
        }
        .accessibilityLabel(name)
    }

    private var title: some View {
        Text(name)
            .font(.system(size: maxHeight * 0.4, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.5), radius: 8)
    }
}

/// A game's store page, full window: key art, logo, buy, then the details.
/// Shown from the Store, and from a Steam game's menu in the Library.
struct GameDetailView: View {
    let appId: Int
    var fallbackName: String = ""
    let onBack: () -> Void

    @EnvironmentObject var bottleVM: BottleVM
    @State private var metadata: GameMetadata?
    @State private var players: Int?
    @State private var error: String?
    @State private var working = false
    @State private var message: String?
    @State private var zoomed: URL?
    @State private var art: StoreArtwork?
    @State private var checkingOut = false

    private var name: String { metadata?.name ?? fallbackName }

    /// Bottles that have the Steam client, where a purchase can happen.
    private var steamBottles: [Bottle] {
        bottleVM.bottles.filter { $0.isAvailable && SteamLibrary.detectInstall(bottleURL: $0.url) != nil }
    }

    private var installed: Bool {
        steamBottles.contains { bottle in SteamLibrary.enumerate(bottleURL: bottle.url).contains { $0.appId == appId } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                HStack(alignment: .top, spacing: 32) {
                    mainColumn
                    sideColumn.frame(width: 280)
                }
                .padding(32)
                .frame(maxWidth: 1200, alignment: .leading)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topTrailing) {
            Button(action: onBack) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .cardGlass(.circle, interactive: true)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
            .padding(.trailing, 20).padding(.top, 14)
        }
        // The page has the window to itself: the tabs and toolbar buttons go.
        .preference(key: HidesTopBarKey.self, value: true)
        .overlay { zoomOverlay }
        .task {
            art = await SteamStore.shared.artwork(appIds: [appId])[appId]
        }
        .task {
            do { metadata = try await SteamStore.shared.metadata(appId: appId) } catch {
                self.error = error.localizedDescription
            }
            players = await SteamStore.shared.currentPlayers(appId: appId)
        }
    }

    // MARK: Hero

    private var hero: some View {
        KeyArt(appId: appId, heroURL: art?.hero, headerURL: metadata?.headerURL, drift: true)
            .id(art?.hero)
            .frame(height: 520)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.35), location: 0),
                        .init(color: .clear, location: 0.3),
                        .init(color: .clear, location: 0.55),
                        .init(color: Color(nsColor: .windowBackgroundColor), location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 14) {
                    GameLogo(appId: appId, name: name, maxHeight: 130)
                    HStack(spacing: 14) {
                        buyButton.controlSize(.extraLarge)
                        if let players, players > 0 {
                            Label("\(players.formatted()) playing now", systemImage: "person.2.fill")
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .cardGlass(.capsule)
                        }
                    }
                    if let message {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 8)
            }
            .animation(.smooth, value: message)
    }

    // MARK: Columns

    @ViewBuilder
    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let metadata {
                if !metadata.genres.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(metadata.genres.prefix(4), id: \.self) { genre in
                            Text(genre).font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
                Text(metadata.shortDescription)
                    .font(.title3)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !metadata.screenshots.isEmpty { screenshots(metadata.screenshots) }
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let metadata {
                if metadata.discountPercent > 0, let initial = metadata.initialPrice {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        PriceTag(price: nil, discount: metadata.discountPercent)
                        Text(initial).strikethrough().foregroundStyle(.secondary)
                    }
                }
                Text(metadata.priceLabel).font(.title.weight(.bold))
                Divider()
                fact("Developer", metadata.developers.joined(separator: ", "))
                fact("Publisher", metadata.publishers.joined(separator: ", "))
                if let date = metadata.releaseDate { fact("Released", date) }
                if let score = metadata.metacritic {
                    HStack {
                        Text("Metacritic").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(score)").font(.headline)
                            .frame(width: 34, height: 26)
                            .background(scoreColor(score), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.black)
                    }
                }
                let platforms = [metadata.windows ? "Windows" : nil, metadata.mac ? "Mac" : nil].compactMap { $0 }
                fact("Platforms", platforms.joined(separator: ", "))
                Divider()
                Button("Open in Browser", systemImage: "safari") {
                    NSWorkspace.shared.open(SteamStore.storePageURL(appId: appId))
                }
                .buttonStyle(.link)
                if !installed, let bottle = steamBottles.first {
                    Button("Install (Already Owned)", systemImage: "arrow.down.circle") {
                        run(bottle) { bottle in
                            try await SteamInstallService.requestInstall(appId: appId, name: name, bottle: bottle)
                            message = "Steam is installing it in \(bottle.settings.name)."
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .font(.callout)
        .padding(20)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func scoreColor(_ score: Int) -> Color {
        score >= 75 ? .green : score >= 50 ? .yellow : .red
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing)
        }
    }

    private func screenshots(_ urls: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screenshots").font(.title2.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(urls, id: \.self) { url in
                    Button { withAnimation(.smooth(duration: 0.3)) { zoomed = url } } label: {
                        Color.clear
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .overlay {
                                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                                    Rectangle().fill(.quaternary)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .help("View full size")
                }
            }
        }
    }

    @ViewBuilder
    private var zoomOverlay: some View {
        if let zoomed {
            ZStack {
                Color.black.opacity(0.9)
                AsyncImage(url: zoomed) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .padding(40)
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.smooth(duration: 0.25)) { self.zoomed = nil } }
            .onKeyPress(.escape) {
                withAnimation(.smooth(duration: 0.25)) { self.zoomed = nil }
                return .handled
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    // MARK: Buying

    @ViewBuilder
    private var buyButton: some View {
        let label = installed ? "Installed" : "Buy · \(metadata?.priceLabel ?? "…")"
        Button { checkingOut = true } label: {
            Label(label, systemImage: installed ? "checkmark" : "cart.fill").padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(installed || working)
        .help("Buy on Steam's store page, right here in Whisky.")
        .sheet(isPresented: $checkingOut) {
            SteamCheckoutSheet(appId: appId, name: name) { purchased in
                checkingOut = false
                guard purchased else { return }
                if let bottle = steamBottles.first {
                    run(bottle) { bottle in
                        try await SteamInstallService.requestInstall(appId: appId, name: name, bottle: bottle)
                        message = "Purchased. Installing in \(bottle.settings.name)."
                    }
                } else {
                    message = "Purchased. Set up Steam in a bottle to install it."
                }
            }
        }
    }

    private func run(_ bottle: Bottle, _ action: @escaping (Bottle) async throws -> Void) {
        working = true
        Task {
            do { try await action(bottle) } catch { message = error.localizedDescription }
            working = false
        }
    }
}
