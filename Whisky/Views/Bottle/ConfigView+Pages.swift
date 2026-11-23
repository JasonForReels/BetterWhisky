//
//  ConfigView+Pages.swift
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

import os
import SwiftUI
import WhiskyKit

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "ConfigView")

// MARK: - Pages

/// The categories of a bottle's configuration, each a page of its own, the
/// way System Settings splits its panes instead of one long scrolling form.
enum ConfigPage: String, CaseIterable, Identifiable, Hashable {
    case general, graphics, audio, input, launchers, performance, components, diagnostics

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "config.page.general"
        case .graphics: "config.page.graphics"
        case .audio: "config.page.audio"
        case .input: "config.page.input"
        case .launchers: "config.page.launchers"
        case .performance: "config.page.performance"
        case .components: "config.page.components"
        case .diagnostics: "config.page.diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .graphics: "display"
        case .audio: "speaker.wave.2.fill"
        case .input: "gamecontroller.fill"
        case .launchers: "arrow.up.forward.app.fill"
        case .performance: "gauge.with.dots.needle.67percent"
        case .components: "shippingbox.fill"
        case .diagnostics: "stethoscope"
        }
    }

    /// The tile colour, as System Settings colours each pane's icon.
    var tint: Color {
        switch self {
        case .general: .gray
        case .graphics: .blue
        case .audio: .pink
        case .input: .orange
        case .launchers: .indigo
        case .performance: .green
        case .components: .brown
        case .diagnostics: .red
        }
    }
}

/// A row in the category list: a coloured icon tile and the page's name.
struct ConfigPageLabel: View {
    let page: ConfigPage

    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            Image(systemName: page.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(page.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

extension ConfigView {
    @ViewBuilder
    func pageContent(_ page: ConfigPage) -> some View {
        switch page {
        case .general:
            WineConfigSection(
                bottle: bottle,
                isExpanded: .constant(true),
                buildVersion: $buildVersion,
                retinaModeState: $retinaModeState,
                dpiConfig: dpiBinding,
                winVersionLoadingState: $winVersionLoadingState,
                buildVersionLoadingState: $buildVersionLoadingState,
                retinaModeLoadingState: $retinaModeLoadingState,
                dpiConfigLoadingState: $dpiConfigLoadingState,
                dpiSheetPresented: $dpiSheetPresented,
                onRetryBuildVersion: loadBuildName,
                onRetryRetinaMode: loadRetinaMode,
                onRetryDpi: loadDpi
            )
            DiscordConfigSection(bottle: bottle)
        case .graphics:
            GraphicsConfigSection(bottle: bottle)
            ResolutionConfigSection(bottle: bottle)
        case .audio:
            AudioConfigSection(bottle: bottle)
        case .input:
            InputConfigSection(bottle: bottle, isExpanded: .constant(true))
        case .launchers:
            LauncherConfigSection(
                bottle: bottle,
                isExpanded: .constant(true),
                onViewDiagnostics: { loadLatestDiagnosisAndView(onUnavailable: showStabilityReport) }
            )
        case .performance:
            PerformanceConfigSection(bottle: bottle, isExpanded: .constant(true))
            CleanupConfigSection(bottle: bottle, isExpanded: .constant(true))
        case .components:
            DLLOverrideConfigSection(bottle: bottle, isExpanded: .constant(true))
            DependencyConfigSection(bottle: bottle)
        case .diagnostics:
            diagnosticsContent
        }
    }

    @ViewBuilder
    var diagnosticsContent: some View {
        gameConfigRevertSection
        gameConfigEnvironmentSection
            Section("Diagnostics") {
                Text("Analyze Wine crash output for troubleshooting guidance")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if hasActiveSession {
                    TroubleshootingEntryBanner(bannerType: .resumeSession) {
                        showTroubleshootingWizard = true
                    }
                }

                Button(String(localized: "troubleshooting.entry.startGuided")) {
                    showTroubleshootingWizard = true
                }

                Button("Export Diagnostic Report\u{2026}") {
                    loadLatestDiagnosisAndExport(onUnavailable: showStabilityReport)
                }
                .disabled(bottle.mostRecentlyDiagnosedProgram == nil)

                Button("View Latest Diagnosis") {
                    loadLatestDiagnosisAndView(onUnavailable: showStabilityReport)
                }
                .disabled(bottle.mostRecentlyDiagnosedProgram == nil)

                TroubleshootingHistoryView(
                    bottleURL: bottle.url,
                    programURL: nil
                )
            }
            Section("Stability") {
                Button("Generate Stability Diagnostics") {
                    showStabilityReport()
                }
                .help("Generates a bounded, privacy-safe report for issue triage.")

                Button {
                    Task {
                        isRepairingPrefix = true
                        defer {
                            bottle.clearWineUsernameCache()
                            isRepairingPrefix = false
                        }
                        do {
                            try await Wine.repairPrefix(bottle: bottle)
                            // Validate immediately after repair to confirm directories were created
                            let result = WinePrefixValidation.validatePrefix(for: bottle)
                            if result.isValid {
                                prefixRepairResult = .success
                            } else {
                                prefixRepairResult = .failure(
                                    String(localized: "config.repairPrefix.validationFailed")
                                )
                            }
                        } catch {
                            prefixRepairResult = .failure(error.localizedDescription)
                        }
                    }
                } label: {
                    HStack {
                        Text("config.repairPrefix")
                        if isRepairingPrefix {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.leading, 4)
                        }
                    }
                }
                .disabled(isRepairingPrefix)
                .help("config.repairPrefix.help")
            }
    }

    /// One of Wine's own Windows tools, opened in this bottle.
    func toolButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () async throws -> Void
    ) -> some View {
        Button {
            Task(priority: .userInitiated) {
                do {
                    try await action()
                } catch {
                    logger.error("Failed to open Wine tool: \(error.localizedDescription)")
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
    }
}

/// The sheets and alerts the Launchers and Diagnostics pages can raise. They
/// live on the pushed page, not the category list, so they present from the
/// view that is on screen.
struct ConfigPresentations: ViewModifier {
    let view: ConfigView

    func body(content: Content) -> some View {
        view.presentations(content)
    }
}
