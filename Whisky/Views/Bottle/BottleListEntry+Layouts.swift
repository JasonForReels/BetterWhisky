//
//  BottleListEntry+Layouts.swift
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

/// The two shapes a bottle takes: a sidebar row and a Bottles-grid card.
extension BottleListEntry {
    var rowContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name)
                    // The sidebar truncates at its default width, and a bottle
                    // named for its contents loses exactly the part that
                    // identifies it.
                    .help(name)
                Spacer()
                if runningCount == 0, hasOrphanProcesses {
                    // A button, not a decoration: this is the strongest signal
                    // in the sidebar and it used to be a tooltip with nothing
                    // behind it.
                    Button {
                        stopBottle()
                    } label: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "bottle.orphan.tooltip"))
                    .accessibilityLabel(Text("bottle.orphan.stop"))
                }
            }
            if let phase = duplicationPhase {
                duplicationProgressRow(phase: phase)
            }
        }
        // The sidebar's own count, as Mail shows unread messages.
        .badge(runningCount)
    }

    /// The Bottles grid's card: the bottle, its setup, and whether anything is
    /// running in it.
    var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                Spacer()
                if runningCount > 0 {
                    Label("\(runningCount)", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .imageScale(.small)
                        .foregroundStyle(.green)
                        .help(Text("tab.processes"))
                }
                if runningCount == 0, hasOrphanProcesses {
                    // A button, not a decoration: this is the strongest signal
                    // in the sidebar and it used to be a tooltip with nothing
                    // behind it.
                    Button {
                        stopBottle()
                    } label: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "bottle.orphan.tooltip"))
                    .accessibilityLabel(Text("bottle.orphan.stop"))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                    .help(name)
                Text(bottle.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let phase = duplicationPhase {
                duplicationProgressRow(phase: phase)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { selected = bottle.url }
        // One element for the card, so its identifier is not handed down to
        // the count and the stop button inside it, which tests then clicked.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { selected = bottle.url }
        .accessibilityIdentifier("bottles.card")
    }
}
