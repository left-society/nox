import Foundation
import CryptoKit

/// PKCE (Proof Key for Code Exchange) helpers for OAuth 2.0 flows
/// where we don't have — and shouldn't have — a client secret.
///
/// **Flow:**
/// 1. Generate a random `verifier` (≥43, ≤128 chars from the
///    unreserved URL-safe alphabet).
/// 2. Compute `challenge = base64url(SHA256(verifier))`.
/// 3. Send `challenge` in the authorize URL as `code_challenge`,
///    plus `code_challenge_method=S256`.
/// 4. After the user authorizes and we get the code back, send the
///    original `verifier` along with the code in the token-exchange
///    POST. The OAuth server verifies that `SHA256(verifier)`
///    matches the `challenge` we sent earlier.
///
/// This binds the auth code to our specific session — even if a
/// network observer steals the code, they can't redeem it without
/// the verifier (which we never put on the wire).
///
/// nox uses PKCE for the **Google** OAuth flow (iOS-type client,
/// no secret). The Notion OAuth flow uses a client secret instead
/// because Notion's API requires it.
enum PKCE {

    /// One PKCE pair — verifier kept locally, challenge goes on
    /// the wire. Generated fresh per OAuth attempt; never reused.
    struct CodeChallenge {
        let verifier: String
        let challenge: String
    }

    /// Generate a fresh verifier + S256 challenge. Verifier length
    /// is fixed at 64 chars — comfortably above the 43-char minimum,
    /// well below the 128-char maximum, and fits in a single line
    /// of debug logs while still giving plenty of entropy.
    static func generate() -> CodeChallenge {
        let verifier = randomURLSafeString(length: 64)
        let hashed = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(hashed).base64URLEncodedString()
        return CodeChallenge(verifier: verifier, challenge: challenge)
    }

    /// CSRF state token. Spec doesn't require a specific format;
    /// any unguessable opaque string is fine. Same character set as
    /// the verifier so URL encoding is a no-op.
    static func generateState() -> String {
        randomURLSafeString(length: 32)
    }

    private static func randomURLSafeString(length: Int) -> String {
        // RFC 7636 unreserved set: [A-Z][a-z][0-9]-._~
        let alphabet = Array(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        if status != errSecSuccess {
            // SecRandom virtually never fails, but if it does we
            // fall back to arc4random — no worse than what the
            // OAuth state field had before this helper existed.
            NSLog("nox: PKCE SecRandomCopyBytes failed status=\(status)")
            for i in 0..<length {
                bytes[i] = UInt8.random(in: 0...255)
            }
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}

/// Base64url encoding (RFC 4648 §5) — same as standard base64 but
/// `+` → `-`, `/` → `_`, no padding `=`. OAuth + PKCE require this
/// variant; standard base64 has characters that need percent-
/// encoding inside URLs and cause subtle bugs at the wire level.
private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
