import Foundation

/// OAuth credentials for the Google Calendar + Notion integrations
/// shipped with nox. These IDs identify nox itself to Google's and
/// Notion's OAuth servers; the **end user** authenticates with their
/// own account through ASWebAuthenticationSession.
///
/// **Why these are bundled here, not stored in Keychain:**
///   • Client IDs are *public* identifiers — any user could see them
///     by inspecting the OAuth redirect URL. They're not secrets.
///   • Notion's Client Secret is technically sensitive but Notion's
///     public-integration docs explicitly support bundling it in
///     desktop apps. The risk surface is "someone extracts the secret
///     from the binary and impersonates nox to authorize against
///     OTHER Notion users." Those users would still have to manually
///     authorize — there's no scenario where bundling the secret
///     leaks any user's data.
///   • Google's iOS client uses PKCE — no client secret, the binary
///     extraction risk above doesn't apply at all.
///
/// **Setup history:** registered 2026-05-09 via the Chrome MCP setup
/// run. Google Cloud project: `nox-495722`. Notion integration ID:
/// `35ad872b-594c-81f0-9076-0037f9118fda`. To rotate either, follow
/// the same flow in `console.cloud.google.com` /
/// `notion.so/my-integrations` and update these constants.
enum OAuthCredentials {

    // MARK: - Google Calendar

    /// Google Cloud OAuth 2.0 Client ID. Type "iOS" so we get PKCE
    /// without needing a client secret. Bundle ID associated with
    /// this client must match nox's `CFBundleIdentifier`
    /// (`app.trynox`) — Google enforces this server-side at token
    /// exchange.
    static let googleClientID =
        "652743757546-uiuj8lvv81o50uc5cgm29r31cnqgppq1.apps.googleusercontent.com"

    /// Google's iOS OAuth clients use a redirect URI derived from
    /// the reversed Client ID. Format:
    /// `<reversed-client-id>:/oauth2redirect/google`.
    /// Apple's URL scheme registry in Info.plist must include the
    /// reversed Client ID portion (everything before the colon) so
    /// the system routes the redirect back to nox.
    static let googleRedirectURI =
        "com.googleusercontent.apps.652743757546-uiuj8lvv81o50uc5cgm29r31cnqgppq1:/oauth2redirect/google"

    /// Read-only Calendar scope — this is the ONLY scope nox
    /// requests. Read-only is non-sensitive on Google's verification
    /// scale, which is why our consent screen auto-approved without
    /// going through Google's OAuth review process.
    static let googleScope = "https://www.googleapis.com/auth/calendar.readonly"

    // MARK: - Notion

    /// Notion public integration Client ID. Returned by the Notion
    /// OAuth flow alongside the access token; not strictly secret
    /// but pairs with `notionClientSecret` for token exchange.
    static let notionClientID = "35ad872b-594c-81f0-9076-0037f9118fda"

    /// Notion public integration Client Secret. Used in the token-
    /// exchange request (`POST /v1/oauth/token` with HTTP Basic
    /// auth `clientID:clientSecret`). Notion's "show once" flow
    /// means we cannot recover this from the integration page — if
    /// it gets lost we'd need to rotate by creating a fresh
    /// integration.
    static let notionClientSecret = "secret_KKIm9YKc47Yofcgvq1dyrhAv9QQH13o02HbMLi5St2p"

    /// Loopback redirect URI registered with the Notion integration.
    /// nox spins up a temporary local HTTP server on this port to
    /// catch the OAuth callback. The port number is not load-bearing
    /// — if 8765 is occupied (rare) the OAuth flow surfaces a clear
    /// error and the user can retry; we don't bind ports until the
    /// flow actually starts.
    static let notionRedirectURI = "http://localhost:8765/oauth/notion"

    /// Notion's authorization URL. Includes a `response_type=code`
    /// that we always pass; the only thing that varies between
    /// invocations is the per-attempt `state` value (CSRF token).
    static let notionAuthorizeURL = "https://api.notion.com/v1/oauth/authorize"

    /// Notion's token-exchange endpoint.
    static let notionTokenURL = "https://api.notion.com/v1/oauth/token"
}
