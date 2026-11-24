//
//  StoreHero.swift
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

/// The big banner at the top, Apple TV style: full-bleed key art drifting
/// slowly, the game's own logo, a line about it, and a strip of the other
/// featured games whose progress bar shows when the next one comes up.
struct StoreHero: View {
    let items: [StoreListing]
    /// Each game's wide banner art, by App ID.
    let heroArt: [Int: URL]
    let open: (StoreListing) -> Void
    @State private var index = 0
    @State private var hovering = false
    @State private var progress: CGFloat = 0
    @State private var details: [Int: GameMetadata] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let interval: Double = 7

    private var item: StoreListing { items[min(index, items.count - 1)] }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            KeyArt(appId: item.appId, heroURL: heroArt[item.appId], headerURL: item.headerURL, drift: true)
                .id(item.id)
                .transition(.opacity)

            // Darkens the left and bottom, where the words sit, and leaves the
            // art itself clear on the right.
            LinearGradient(
                colors: [.black.opacity(0.85), .black.opacity(0.4), .clear],
                startPoint: .leading, endPoint: .init(x: 0.75, y: 0.5)
            )
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)

            HStack(alignment: .bottom, spacing: 24) {
                info
                    .id("info-\(item.id)")
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: -24)),
                        removal: .opacity
                    ))
                Spacer(minLength: 0)
                thumbnails
            }
            .padding(32)
        }
        .frame(height: 440)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { open(item) }
        .onHover { hovering = $0 }
        .task(id: "\(index)-\(hovering)") { await advance() }
        .task { await loadDetails() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Featured: \(item.name)")
        .accessibilityAddTraits(.isButton)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(details[item.appId]?.genres.first.map { "NEW & POPULAR · \($0.uppercased())" } ?? "NEW & POPULAR")
                .font(.caption.weight(.bold))
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.75))
            GameLogo(appId: item.appId, name: item.name, maxHeight: 110)
            if let blurb = details[item.appId]?.shortDescription, !blurb.isEmpty {
                Text(blurb)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: 460, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button { open(item) } label: {
                    Text(item.isFree ? "Play Free" : "View Game")
                        .font(.headline)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(PressableStyle())
                PriceTag(price: item.isFree ? nil : item.price, discount: item.discountPercent)
                    .colorScheme(.dark)
            }
        }
    }

    private var thumbnails: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, listing in
                let active = offset == index
                Button {
                    withAnimation(.smooth(duration: 0.8)) { index = offset }
                } label: {
                    // A fixed frame with the art laid over it: the art fills,
                    // and a filling image would otherwise size the button.
                    Color.clear
                        .frame(width: active ? 128 : 96, height: active ? 60 : 45)
                        .overlay { StoreArt(listing: listing).scaledToFill() }
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(alignment: .bottom) {
                            if active {
                                GeometryReader { geo in
                                    Capsule().fill(.white)
                                        .frame(width: geo.size.width * progress, height: 3)
                                }
                                .frame(height: 3)
                                .padding(6)
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(active ? 0.9 : 0.2), lineWidth: active ? 2 : 1)
                        }
                        .opacity(active ? 1 : 0.6)
                }
                .buttonStyle(PressableStyle())
                .help(listing.name)
            }
        }
        .animation(.smooth(duration: 0.4), value: index)
    }

    /// Fills the active thumbnail's bar, then moves on. Paused under the pointer.
    private func advance() async {
        progress = 0
        guard !hovering, !reduceMotion, items.count > 1 else { return }
        withAnimation(.linear(duration: Self.interval)) { progress = 1 }
        try? await Task.sleep(for: .seconds(Self.interval))
        guard !Task.isCancelled else { return }
        withAnimation(.smooth(duration: 0.8)) { index = (index + 1) % items.count }
    }

    private func loadDetails() async {
        for listing in items where details[listing.appId] == nil {
            if let meta = try? await SteamStore.shared.metadata(appId: listing.appId) {
                withAnimation(.easeOut(duration: 0.3)) { details[listing.appId] = meta }
            }
        }
    }
}
