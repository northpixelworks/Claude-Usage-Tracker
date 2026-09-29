//
//  ConsoleAuthWebView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-03-01.
//

import SwiftUI
import WebKit

// MARK: - Cookie Result

struct ConsoleCookieResult {
    let sessionKey: String
    let expiryDate: Date?
}

// MARK: - WKWebView Wrapper

struct ConsoleAuthWebView: NSViewRepresentable {
    let loginURL: URL
    let cookieDomain: String
    let onCookieFound: (ConsoleCookieResult) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.startObservingCookies(for: config.websiteDataStore)

        // Clear auth cookies to prevent auto-login with stale session.
        // Google cookies are preserved so SSO popup works.
        let cookieStore = config.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies where cookie.domain.contains("claude") || cookie.domain.contains("anthropic") {
                group.enter()
                cookieStore.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                webView.load(URLRequest(url: self.loginURL))
            }
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(cookieDomain: cookieDomain, onCookieFound: onCookieFound)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let cookieDomain: String
        let onCookieFound: (ConsoleCookieResult) -> Void
        private var foundCookie = false
        private var pollTimer: Timer?
        private weak var activeWebView: WKWebView?
        private var observedCookieStore: WKHTTPCookieStore?
        private var popupWindow: NSWindow?
        private var popupWebView: WKWebView?

        init(cookieDomain: String, onCookieFound: @escaping (ConsoleCookieResult) -> Void) {
            self.cookieDomain = cookieDomain
            self.onCookieFound = onCookieFound
        }

        deinit {
            pollTimer?.invalidate()
            observedCookieStore?.remove(self)
        }

        func startObservingCookies(for dataStore: WKWebsiteDataStore) {
            let cookieStore = dataStore.httpCookieStore
            observedCookieStore?.remove(self)
            observedCookieStore = cookieStore
            cookieStore.add(self)
        }

        // WKHTTPCookieStoreObserver — fires whenever any cookie changes
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !foundCookie else { return }
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.foundCookie else { return }
                for cookie in cookies {
                    if cookie.name == "sessionKey" && cookie.domain.contains(self.cookieDomain) {
                        self.completeAuthentication(with: cookie)
                        return
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !foundCookie else { return }
            activeWebView = webView
            checkForSessionCookie(in: webView)
            startPollingIfNeeded(webView: webView)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Create a real popup WKWebView using the provided configuration
            // (preserves window.opener linkage and shared cookies for Google SSO)
            startObservingCookies(for: configuration.websiteDataStore)

            let popup = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 500, height: 600),
                configuration: configuration
            )
            popup.navigationDelegate = self
            popup.uiDelegate = self

            let panel = NSPanel(
                contentRect: CGRect(x: 0, y: 0, width: 500, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.contentView = popup
            panel.title = "Sign In"
            panel.center()
            panel.makeKeyAndOrderFront(nil)

            self.popupWindow = panel
            self.popupWebView = popup

            return popup
        }

        // Handle window.close() from Google SSO popup after auth completes
        func webViewDidClose(_ webView: WKWebView) {
            if webView === popupWebView {
                popupWindow?.close()
                popupWindow = nil
                popupWebView = nil
            }
        }

        /// Polls cookies every 1s to catch SPA-based logins that don't trigger didFinish.
        /// WKHTTPCookieStoreObserver doesn't fire for network-set cookies on macOS 26+.
        private func startPollingIfNeeded(webView: WKWebView) {
            guard pollTimer == nil else { return }
            // .common mode so the timer keeps firing while the sheet is up.
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self, !self.foundCookie, let wv = self.activeWebView else {
                    self?.pollTimer?.invalidate()
                    self?.pollTimer = nil
                    return
                }
                self.checkForSessionCookie(in: wv)
                self.reloadIfLoggedInWithoutCookie(wv)
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }

        // The network process may not expose the fresh sessionKey to
        // getAllCookies until the next navigation. If the webview has left the
        // login page but the cookie still isn't visible, force a reload
        // (mirrors the manual page-reload workaround). Ported from upstream 7b5488c.
        private var pollsSinceLoginLeft = 0
        private var reloadAttempts = 0

        private func reloadIfLoggedInWithoutCookie(_ webView: WKWebView) {
            guard !foundCookie,
                  let url = webView.url,
                  url.host?.contains(cookieDomain) == true,
                  !url.path.contains("login") else {
                pollsSinceLoginLeft = 0
                return
            }
            pollsSinceLoginLeft += 1
            // Give the observer/poll 3s to see the cookie, then reload; retry up to 3 times.
            if pollsSinceLoginLeft >= 3 && reloadAttempts < 3 {
                pollsSinceLoginLeft = 0
                reloadAttempts += 1
                webView.reloadFromOrigin()
            }
        }

        private func checkForSessionCookie(in webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.foundCookie else { return }

                for cookie in cookies {
                    if cookie.name == "sessionKey" && cookie.domain.contains(self.cookieDomain) {
                        self.completeAuthentication(with: cookie)
                        return
                    }
                }
            }
        }

        private func completeAuthentication(with cookie: HTTPCookie) {
            guard !foundCookie else { return }

            foundCookie = true
            pollTimer?.invalidate()
            pollTimer = nil

            popupWindow?.close()
            popupWindow = nil
            popupWebView = nil

            let result = ConsoleCookieResult(
                sessionKey: cookie.value,
                expiryDate: cookie.expiresDate
            )

            DispatchQueue.main.async {
                self.onCookieFound(result)
            }
        }
    }
}

// MARK: - Auth Sheet

struct ConsoleAuthSheet: View {
    let title: String
    let loginURL: URL
    let cookieDomain: String
    let onSuccess: (ConsoleCookieResult) -> Void
    let onCancel: () -> Void

    @State private var isLoading = true
    @State private var hasError = false

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // WebView
            ConsoleAuthWebView(loginURL: loginURL, cookieDomain: cookieDomain) { result in
                onSuccess(result)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 680)
    }
}
