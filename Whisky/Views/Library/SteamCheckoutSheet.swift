//
//  SteamCheckoutSheet.swift
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
import WebKit
import WhiskyKit

/// Steam's own store page in a native sheet, so buying never needs the
/// Wine Steam window. Sign-in, payment and the receipt all happen on
/// store.steampowered.com; Whisky only watches the URL to notice the
/// receipt page, and never reads what is typed into the page.
struct SteamCheckoutSheet: View {
    let appId: Int
    let name: String
    /// Called when the sheet closes; `true` if Steam showed a receipt.
    let onFinish: (_ purchased: Bool) -> Void

    @State private var purchased = false
    @State private var loading = true
    @State private var host = "store.steampowered.com"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                Text(host).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                if purchased {
                    Label("Purchased", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button(purchased ? "Install" : "Done") { onFinish(purchased) }
                    .keyboardShortcut(purchased ? .defaultAction : .cancelAction)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            SteamWebView(
                url: SteamStore.storePageURL(appId: appId), appId: appId,
                loading: $loading, host: $host, purchased: $purchased
            )
        }
        .frame(minWidth: 960, idealWidth: 1100, minHeight: 680, idealHeight: 820)
    }
}

private struct SteamWebView: NSViewRepresentable {
    let url: URL
    let appId: Int
    @Binding var loading: Bool
    @Binding var host: String
    @Binding var purchased: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: Self.addToCartScript(appId: appId),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        // Persistent store, so the Steam sign-in is kept between purchases.
        config.websiteDataStore = .default()
        // Steam opens its sign-in and cart prompts with window.open; without
        // this WebKit drops them silently and Add to Cart does nothing.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        let url = url
        // Signed out, Steam's cart does nothing, so sign in first; Steam's
        // login page then returns to the game page.
        config.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let signedIn = cookies.contains {
                $0.name == "steamLoginSecure" && $0.domain.hasSuffix("steampowered.com")
            }
            view.load(URLRequest(url: signedIn ? url : Self.signInURL(returningTo: url)))
        }
        return view
    }

    /// Steam's store sign-in page, sent back to `url` afterwards.
    /// Presses the game page's own "Add to Cart" for the base game (the
    /// first purchase box that has one, not a demo or a bundle further down); Steam then shows the
    /// cart. Steam draws that box with script after the page loads, so this
    /// waits for the button for up to 20 seconds. It runs once per app per
    /// sheet session, so going back to the page doesn't add it again.
    static func addToCartScript(appId: Int) -> String {
        """
        (() => {
          if (!location.pathname.startsWith('/app/\(appId)')) return;
          const key = 'betterwhisky_cart_\(appId)';
          if (sessionStorage.getItem(key)) return;
          const inBox = (box) => {
            for (const el of box.querySelectorAll('a, button, span, div')) {
              if (el.children.length === 0 && el.textContent.trim().toLowerCase() === 'add to cart') {
                return el.closest('a, button, [role="button"]') || el;
              }
            }
            return null;
          };
          // Boxes in page order; demos and free starter packs come first on
          // some pages and have no Add to Cart, so they are skipped.
          const find = () => {
            const boxes = document.querySelectorAll('.game_area_purchase_game:not(.demo_above_purchase)');
            for (const box of boxes) { const btn = inBox(box); if (btn) return btn; }
            return null;
          };
          let tries = 0;
          const timer = setInterval(() => {
            const btn = find();
            if (btn || ++tries > 66) clearInterval(timer);
            if (btn) { sessionStorage.setItem(key, '1'); btn.click(); }
          }, 300);
        })();
        """
    }

    static func signInURL(returningTo url: URL) -> URL {
        // swiftlint:disable:next force_unwrapping
        var parts = URLComponents(string: "https://store.steampowered.com/login/")!
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        parts.queryItems = [URLQueryItem(name: "redir", value: path)]
        return parts.url ?? url
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let parent: SteamWebView
        init(_ parent: SteamWebView) { self.parent = parent }

        /// Hosts Steam's store, sign-in and checkout use. Anything else
        /// (a game's own site, a payment provider's 3-D Secure page that
        /// opens as a new window) goes to the default browser.
        private static let steamHosts = [
            "steampowered.com", "steamcommunity.com", "steamstatic.com",
            "akamaihd.net", "steamcontent.com"
        ]

        private static func isSteam(_ url: URL?) -> Bool {
            guard let host = url?.host?.lowercased() else { return false }
            return steamHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }

        @MainActor
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if url.scheme == "steam" { return decisionHandler(.cancel) }  // no Wine client
            // Top-level links off Steam open in the browser; subframes
            // (payment widgets, captchas) stay so checkout keeps working.
            if action.targetFrame?.isMainFrame ?? true, !Self.isSteam(url), url.scheme?.hasPrefix("http") == true {
                if action.targetFrame == nil || action.navigationType == .linkActivated {
                    NSWorkspace.shared.open(url)
                    return decisionHandler(.cancel)
                }
            }
            if action.targetFrame == nil {  // target=_blank on Steam: keep it here
                webView.load(action.request)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        /// Pop-ups (Steam's sign-in, cart, payment windows) open in this same
        /// view instead of a new window; anything off Steam goes to the browser.
        @MainActor
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = action.request.url {
                if Self.isSteam(url) { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
            }
            return nil
        }

        @MainActor
        func webView(
            _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            alert.runModal()
            completionHandler()
        }

        @MainActor
        func webView(
            _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            let url = webView.url
            parent.host = url?.host ?? parent.host
            // Steam's checkout ends on /checkout/... with a receipt.
            let path = url?.path.lowercased() ?? ""
            if path.contains("/checkout") && (path.contains("receipt") || path.contains("finalize")) {
                parent.purchased = true
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
        }
    }
}
