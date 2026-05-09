import Foundation
import AuthenticationServices
import AppKit
import Combine

/// Google Calendar integration that bypasses macOS Calendar.app
/// entirely — the user signs in once with their Google account via
/// `ASWebAuthenticationSession` and from then on we read events
/// directly off Calendar API v3.
///
/// **Why this exists alongside `CalendarMonitorService`:** the
/// EventKit path requires the user to add their Google account in
/// `System Settings → Internet Accounts` first. That's the
/// "complicated" flow the user complained about. With this service,
/// the in-panel CTA is just **"Sign in with Google"** — one tap, web
/// auth window, done.
///
/// ─── Privacy posture (audited 2026-05-09) ─────────────────────
///
/// **Nothing user-private leaves the device.** All Google API
/// requests go directly from nox to `*.googleapis.com` over TLS —
/// there is no nox-side server, no analytics endpoint, no third-
/// party SDK between the user's Mac and Google.
///
/// **Tokens** never reach disk in plaintext:
///   • Refresh token → Keychain (encrypted, ACL-gated).
///   • Access token → in-memory only; lost on quit, swapped via
///     refresh on next launch.
///   • Email → Keychain (used for "Connected as user@…" UI text).
///   • PKCE verifier → @State on the service instance for the
///     duration of the auth flow, wiped on completion.
///
/// **Logs** never contain tokens, codes, verifiers, event titles,
/// attendees, or the user's email. The two `NSLog` sites in this
/// file emit only HTTP status codes and Swift error type names —
/// no raw response bodies, no associated values that could carry a
/// payload. (The `tokenExchangeFailed` enum case used to carry the
/// raw body; that was redacted in the privacy audit.)
///
/// **Calendar event content** stays in memory + the SwiftUI view
/// hierarchy. We don't persist event titles to disk, don't index
/// them for search, don't send them anywhere. On quit they're
/// gone; next launch re-fetches from Google fresh.
///
/// **Disconnect** (`signOut()`) wipes the local refresh token AND
/// fires Google's `/revoke` endpoint so the token is dead at the
/// source — not just locally orphaned.
///
/// **State machine:**
/// ```
/// signedOut ──signIn──▶ authorizing ──code──▶ exchangingTokens
///                                                │
///   ◀──userCancelled──┘                          ▼
///                                          signedIn(email)
///                                                │
///                                            poll/refresh
///                                                ▼
///                                       todayEvents published
/// ```
///
/// **Token lifecycle:** Google access tokens expire after 1 hour.
/// We persist the refresh token in Keychain and exchange it for a
/// fresh access token on demand (when an API call returns 401, or
/// preemptively if we know we're past the expiry timestamp). Access
/// tokens themselves are kept in memory only — losing them on
/// quit just costs us one refresh round-trip on next launch.
///
/// All access is `@MainActor` — the service is observed by SwiftUI,
/// so confining it to main avoids `@Published` cross-actor warnings.
@MainActor
final class GoogleCalendarService: NSObject, ObservableObject {
    static let shared = GoogleCalendarService()

    /// User-facing connection state. Drives the `CalendarTodayPane`
    /// branch (signed-in → events list, signedOut → "Sign in with
    /// Google" CTA, error → recovery CTA).
    enum ConnectionState: Equatable {
        case signedOut
        case authorizing
        case signedIn(email: String?)
        case error(message: String)
    }
    @Published private(set) var connectionState: ConnectionState = .signedOut

    /// Today's events (matching `CalendarMonitorService.TodayEvent`
    /// shape so `CalendarTodayPane` can render either source via
    /// the same row helpers without branching).
    @Published private(set) var todayEvents: [CalendarMonitorService.TodayEvent] = []

    // MARK: - Token storage keys
    //
    // Refresh token is the long-lived credential — Keychain. Access
    // token is short-lived — memory only. Email is a UI nicety,
    // also in Keychain so we can show "Connected as user@gmail.com"
    // immediately on cold launch without an extra API call.
    private static let kRefreshToken = "google.calendar.refresh"
    private static let kEmail = "google.calendar.email"
    private var accessToken: String?
    private var accessTokenExpiry: Date?

    /// Pending PKCE pair while the auth window is open. Wiped on
    /// completion (success or cancel) so a stale verifier can't be
    /// reused by a future flow.
    private var pendingPKCE: PKCE.CodeChallenge?
    private var pendingState: String?

    /// ASWebAuthenticationSession reference held strongly while the
    /// flow is active. Without this, ARC may release the session
    /// mid-flow and the auth window vanishes silently — a
    /// well-known footgun in Apple's API.
    private var authSession: ASWebAuthenticationSession?

    /// 60s polling timer once signed in. Same cadence as
    /// `CalendarMonitorService` so the UI's "this is fresh" feel is
    /// consistent across sources.
    private var pollTimer: Timer?

    private override init() {
        super.init()
        // Cold-launch hydration: if we have a refresh token in the
        // Keychain from a previous session, surface "signed in"
        // immediately and kick a refresh in the background. The user
        // sees their events with no extra clicks.
        if KeychainStore.read(for: Self.kRefreshToken) != nil {
            let email = KeychainStore.read(for: Self.kEmail)
            connectionState = .signedIn(email: email)
            Task { await refresh() }
        }
    }

    // MARK: - Public API

    /// Kick off the OAuth web-auth flow. Idempotent if a session is
    /// already in flight (no-op rather than opening a second window).
    func signIn() {
        guard connectionState != .authorizing else { return }
        connectionState = .authorizing

        let pkce = PKCE.generate()
        let state = PKCE.generateState()
        pendingPKCE = pkce
        pendingState = state

        // Build authorize URL. Apple-sanctioned PKCE flow — no
        // client secret, just code_challenge + S256 method.
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthCredentials.googleClientID),
            URLQueryItem(name: "redirect_uri", value: OAuthCredentials.googleRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope",
                         value: "\(OAuthCredentials.googleScope) openid email"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Force "select account" so users with multiple Google
            // accounts can pick which one to connect (otherwise
            // Google silently picks the most recent and the user is
            // stuck with the wrong account).
            URLQueryItem(name: "prompt", value: "select_account"),
            URLQueryItem(name: "access_type", value: "offline"),
        ]
        guard let url = components.url else {
            connectionState = .error(message: "Couldn't build auth URL")
            return
        }

        // Callback scheme is the part of the redirect URI before
        // the colon — i.e. the reversed Client ID. ASWebAuth needs
        // the scheme alone, not the full URI.
        let callbackScheme = "com.googleusercontent.apps.652743757546-uiuj8lvv81o50uc5cgm29r31cnqgppq1"

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, error in
            Task { @MainActor [weak self] in
                self?.handleAuthCallback(url: callbackURL, error: error)
            }
        }
        session.presentationContextProvider = self
        // .ephemeral session = doesn't share cookies with Safari,
        // so the user is forced to type their email every time
        // (annoying). We want shared cookies so a logged-in Google
        // session in Safari = one-tap sign-in here.
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        if !session.start() {
            connectionState = .error(message: "Couldn't start sign-in")
            authSession = nil
        }
    }

    /// Disconnect: clear local tokens + revoke remotely. Returns the
    /// service to `.signedOut` so the panel re-shows the Sign in CTA.
    func signOut() {
        if let token = KeychainStore.read(for: Self.kRefreshToken) {
            // Best-effort revoke — fire-and-forget. If the network
            // is down or the token is already invalid, we still
            // remove it locally so the UI reflects the disconnect.
            Task.detached(priority: .background) {
                var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
                req.httpMethod = "POST"
                req.httpBody = "token=\(token)".data(using: .utf8)
                req.setValue("application/x-www-form-urlencoded",
                             forHTTPHeaderField: "Content-Type")
                _ = try? await URLSession.shared.data(for: req)
            }
        }
        KeychainStore.delete(for: Self.kRefreshToken)
        KeychainStore.delete(for: Self.kEmail)
        accessToken = nil
        accessTokenExpiry = nil
        connectionState = .signedOut
        todayEvents = []
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Re-fetch today's events. Called on the polling tick, on
    /// successful sign-in, and on any UI affordance that wants
    /// "show me what changed."
    func refresh() async {
        guard case .signedIn = connectionState else { return }
        do {
            let token = try await freshAccessToken()
            let events = try await fetchTodayEvents(token: token)
            self.todayEvents = events
        } catch {
            // PRIVACY: log only the error TYPE, never the value.
            // Errors here can carry network response data (URLError
            // userInfo) or our own GoogleAPIError associated values;
            // either could leak request metadata to Console.app.
            NSLog("nox: GoogleCalendarService refresh failed (type=\(type(of: error)))")
            // Don't flip into error state on transient failures —
            // the next poll will retry. Only flip if we couldn't
            // refresh the token (= the refresh token itself is dead).
            if case GoogleAPIError.refreshFailed = error {
                connectionState = .error(message: "Sign-in expired — please reconnect.")
            }
        }
    }

    // MARK: - OAuth callback

    private func handleAuthCallback(url: URL?, error: Error?) {
        defer {
            pendingPKCE = nil
            pendingState = nil
            authSession = nil
        }
        if let error = error {
            // User cancelled the auth window? Typically surfaces
            // as `ASWebAuthenticationSessionError.canceledLogin`.
            // We treat cancellation as a quiet return-to-signedOut,
            // not an error to surface — the user clearly knew what
            // they were doing.
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                connectionState = .signedOut
                return
            }
            // PRIVACY: avoid interpolating `error.localizedDescription`
            // into the user-facing message. ASWebAuth's localized
            // strings are usually generic ("operation couldn't be
            // completed"), but the principle of "never display an
            // error's payload" rules out the small risk that a future
            // ASWebAuth update returns detail that includes URL
            // fragments or auth-specific context.
            connectionState = .error(message: "Sign-in failed — please try again.")
            return
        }
        guard let url = url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        else {
            connectionState = .error(message: "Sign-in returned no code")
            return
        }
        // CSRF check — the state we sent must come back unchanged.
        // Mismatch suggests an attacker tried to inject their own
        // code; never proceed.
        guard returnedState == pendingState else {
            connectionState = .error(message: "Sign-in state mismatch")
            return
        }
        guard let verifier = pendingPKCE?.verifier else {
            connectionState = .error(message: "Sign-in lost PKCE state")
            return
        }
        Task { await self.exchangeCodeForTokens(code: code, verifier: verifier) }
    }

    private func exchangeCodeForTokens(code: String, verifier: String) async {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: OAuthCredentials.googleClientID),
            URLQueryItem(name: "redirect_uri", value: OAuthCredentials.googleRedirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            connectionState = .error(message: "Couldn't build token request")
            return
        }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                // PRIVACY: deliberately discard the response body.
                // Google never returns tokens in an error body, but
                // some error variants (e.g. invalid_grant for a
                // long-expired code) echo enough of the request
                // back to be considered sensitive. Status code is
                // sufficient for diagnostics.
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw GoogleAPIError.tokenExchangeFailed(statusCode: status)
            }
            let parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
            self.accessToken = parsed.access_token
            self.accessTokenExpiry = Date().addingTimeInterval(
                TimeInterval(parsed.expires_in - 60)  // -60s safety margin
            )
            if let refresh = parsed.refresh_token {
                KeychainStore.save(refresh, for: Self.kRefreshToken)
            }
            // Pull email from id_token (JWT) for "Signed in as" UI.
            // We only need the payload (middle segment, base64url).
            // No verification needed — Google just signed it minutes
            // ago and we'll trust it for display purposes only.
            let email = parsed.id_token.flatMap(extractEmailClaim)
            if let email = email {
                KeychainStore.save(email, for: Self.kEmail)
            }
            self.connectionState = .signedIn(email: email)
            self.startPolling()
            await refresh()
        } catch {
            // PRIVACY: same redaction as `refresh()` — log the error
            // TYPE only, never the value (which can carry response
            // data, request URL, headers, or auth code echoes).
            NSLog("nox: GoogleCalendarService token exchange failed (type=\(type(of: error)))")
            self.connectionState = .error(message: "Sign-in failed during token exchange")
        }
    }

    /// Get a non-expired access token. If the in-memory token is
    /// still good, return it; otherwise swap the refresh token for
    /// a fresh one. Throws if the refresh token itself is dead
    /// (user revoked, account closed, etc.) — the caller flips us
    /// into `.error` and surfaces a "reconnect" CTA.
    private func freshAccessToken() async throws -> String {
        if let token = accessToken,
           let expiry = accessTokenExpiry,
           expiry > Date() {
            return token
        }
        guard let refresh = KeychainStore.read(for: Self.kRefreshToken) else {
            throw GoogleAPIError.notAuthenticated
        }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "client_id", value: OAuthCredentials.googleClientID),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            throw GoogleAPIError.refreshFailed
        }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            // 401 / 400 typically mean the refresh token is dead.
            throw GoogleAPIError.refreshFailed
        }
        let parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
        self.accessToken = parsed.access_token
        self.accessTokenExpiry = Date().addingTimeInterval(
            TimeInterval(parsed.expires_in - 60)
        )
        return parsed.access_token
    }

    // MARK: - Calendar API

    private func fetchTodayEvents(token: String) async throws -> [CalendarMonitorService.TodayEvent] {
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timeMin = isoFormatter.string(from: startOfDay)
        let timeMax = isoFormatter.string(from: endOfDay)

        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: timeMin),
            URLQueryItem(name: "timeMax", value: timeMax),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "20"),
        ]
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw GoogleAPIError.eventsFetchFailed
        }
        let decoded = try JSONDecoder().decode(EventsListResponse.self, from: data)
        return decoded.items.compactMap { $0.toTodayEvent() }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }
}

// MARK: - ASWebAuth presentation context

extension GoogleCalendarService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Best-available window. ASWebAuth uses this only as a parent
        // for the auth window; if the panel is the only thing on
        // screen, that's fine — the auth window is a system-level
        // overlay either way.
        DispatchQueue.main.sync {
            NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }
}

// MARK: - JSON shapes

private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
    let id_token: String?
}

private struct EventsListResponse: Decodable {
    let items: [GCalEvent]
}

private struct GCalEvent: Decodable {
    let id: String?
    let summary: String?
    let start: TimeMarker?
    let end: TimeMarker?

    struct TimeMarker: Decodable {
        let dateTime: String?
        let date: String?
    }

    /// Map Google's event shape into the shared `TodayEvent` shape
    /// the calendar pane already knows how to render. Falls back to
    /// nil if the event is structurally weird (no start, no end,
    /// nothing parseable) — caller's compactMap drops it.
    func toTodayEvent() -> CalendarMonitorService.TodayEvent? {
        let title = summary ?? "Untitled"
        let isAllDay = (start?.date != nil && start?.dateTime == nil)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let startDate: Date?
        let endDate: Date?
        if isAllDay {
            // All-day events use `date` (YYYY-MM-DD) without time.
            // Parse as midnight in the user's calendar.
            let cal = Calendar.current
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd"
            dateFmt.calendar = cal
            dateFmt.timeZone = TimeZone.current
            startDate = start?.date.flatMap { dateFmt.date(from: $0) }
            endDate = end?.date.flatMap { dateFmt.date(from: $0) }
        } else {
            startDate = start?.dateTime.flatMap { formatter.date(from: $0) }
            endDate = end?.dateTime.flatMap { formatter.date(from: $0) }
        }
        guard let s = startDate, let e = endDate else { return nil }
        // We don't have a per-calendar color from this minimal
        // events.list response. Future enhancement: hit calendarList
        // separately for colorIds. For V1 a neutral gray-ish dot is
        // fine — distinguishes the row but doesn't pretend to know
        // the user's color preferences.
        return CalendarMonitorService.TodayEvent(
            id: id ?? "\(s.timeIntervalSince1970)-\(title)",
            title: title,
            startDate: s,
            endDate: e,
            isAllDay: isAllDay,
            calendarColorRGB: (red: 0.55, green: 0.45, blue: 0.85, alpha: 1.0)
        )
    }
}

// MARK: - Errors

enum GoogleAPIError: Error {
    case notAuthenticated
    /// Token exchange got a non-2xx HTTP response. We carry only the
    /// status code, NOT the response body — see the privacy posture
    /// doc-comment on `GoogleCalendarService`. The body could
    /// theoretically echo the auth code or other request data, and
    /// `NSLog("\(error)")` would otherwise leak that to Console.app.
    case tokenExchangeFailed(statusCode: Int)
    case refreshFailed
    case eventsFetchFailed
}

/// Decode the email claim from a Google id_token JWT. JWT format:
/// `<header>.<payload>.<signature>` — payload is base64url JSON.
/// We don't verify the signature because (a) we just got the token
/// over TLS direct from Google's token endpoint and (b) we're only
/// using it for display, not authorization.
private func extractEmailClaim(_ idToken: String) -> String? {
    let parts = idToken.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1])
    // Re-pad to multiples of 4 (base64url drops trailing `=`).
    let padding = 4 - (payload.count % 4)
    if padding < 4 { payload += String(repeating: "=", count: padding) }
    payload = payload
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    guard let data = Data(base64Encoded: payload),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json["email"] as? String
}
