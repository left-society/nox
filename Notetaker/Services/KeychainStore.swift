import Foundation
import Security

/// Minimal Keychain Services wrapper for OAuth token storage.
/// Tokens are scoped to the `app.trynox.oauth` service identifier so
/// they don't collide with anything else nox might want to keep in
/// the user's keychain later.
///
/// **Why not UserDefaults?** UserDefaults is plain-text on disk
/// (`~/Library/Preferences/app.trynox.plist`). A refresh token there
/// is one `defaults read` away from any process. The Keychain is
/// encrypted-at-rest and gated by macOS's per-process ACL, so a
/// rogue download or other app on the same machine can't read our
/// stored credentials.
///
/// **Why not SwiftKeychainWrapper / KeychainAccess libraries?**
/// Single-purpose internal use, ~80 LOC, no need for a dependency.
/// Apple's SecItem API is verbose but stable.
enum KeychainStore {

    /// Service identifier under which all nox OAuth tokens live.
    /// Picking it consistently means we can also wipe everything
    /// nox stored on a "Disconnect all" gesture (future feature).
    private static let service = "app.trynox.oauth"

    /// Save (or overwrite) a string value for `account`. Returns
    /// `true` on success. Failures (rare — usually disk full or
    /// keychain locked) are logged but not surfaced to callers; the
    /// next read will simply return nil and trigger a re-auth.
    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // SecItemUpdate is preferred when an entry already exists —
        // it preserves any access-control attributes the system added.
        // SecItemAdd creates a fresh entry. Try update first; if
        // nothing matched, fall through to add.
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary,
                                         updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess { return true }
            NSLog("nox: KeychainStore.save add failed status=\(addStatus) account=\(account)")
            return false
        }
        NSLog("nox: KeychainStore.save update failed status=\(updateStatus) account=\(account)")
        return false
    }

    /// Read the value for `account`. Returns nil if no entry exists
    /// (first launch, post-disconnect, or after a Keychain wipe).
    static func read(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the entry for `account`. No-op if it didn't exist.
    /// Used by the "Disconnect" UI affordance — clearing the refresh
    /// token forces a fresh OAuth flow on next sign-in.
    @discardableResult
    static func delete(for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
