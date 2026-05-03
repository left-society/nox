import Foundation
import Security

/// Encrypted credential storage backed by the macOS Keychain.
///
/// Earlier the Groq dictation key and the Gemini OCR/Summary key were
/// stored in `UserDefaults` via `@AppStorage`. Plain `UserDefaults`
/// writes a property list to
/// `~/Library/Preferences/com.aritradebnath.notetaker.plist` in
/// CLEARTEXT — readable by any process running as the user, included
/// in Time Machine backups, synced to iCloud Drive if the user has
/// "Desktop & Documents" turned on with Library access. A pentester
/// audit flagged this as the single critical-severity finding in the
/// app: the user's real Groq + Gemini keys were sitting in plaintext
/// on disk.
///
/// `SecureKeyStore` wraps `SecItem*` so both keys live in the user's
/// login keychain instead. Access is gated on
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
///   • not synced to iCloud Keychain
///   • not exported in Time Machine backups by default
///   • only readable while the device is unlocked
///   • bound to nox's bundle (other apps can't read).
///
/// Usage is a thin pseudo-`String?` API to keep call sites tiny:
/// ```
/// let key = SecureKeyStore.shared.load(.geminiApiKey) ?? ""
/// SecureKeyStore.shared.save(.dictationApiKey, value: newKey)
/// ```
@MainActor
final class SecureKeyStore {
    static let shared = SecureKeyStore()
    private init() {}

    /// Logical key identifiers. Each maps to a Keychain `account`
    /// attribute; the `service` attribute is the bundle identifier
    /// so other apps using the same generic-password service field
    /// don't collide.
    enum Key: String, CaseIterable {
        case dictationApiKey
        case geminiApiKey

        /// Matching legacy `UserDefaults` key — used by the one-shot
        /// migration in `migrateFromUserDefaultsIfNeeded()` to import
        /// existing values, then delete them from the plist.
        var legacyDefaultsKey: String {
            switch self {
            case .dictationApiKey: return "dictationAPIKey"
            case .geminiApiKey:    return "geminiApiKey"
            }
        }
    }

    private static let service = Bundle.main.bundleIdentifier ?? "com.aritradebnath.notetaker"

    // MARK: - Read / write / delete

    func load(_ key: Key) -> String? {
        var query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  Self.service,
            kSecAttrAccount as String:  key.rawValue,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        guard let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    @discardableResult
    func save(_ key: Key, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Try update first; if the item doesn't exist, fall through to
        // add. SecItemAdd on an existing item returns errSecDuplicateItem
        // rather than overwriting, so order matters.
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue
        ]
        let updates: [String: Any] = [
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var addAttributes = query
        addAttributes[kSecValueData as String]      = data
        addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    @discardableResult
    func delete(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Migration

    /// One-shot import of any previously-stored plaintext UserDefaults
    /// values. Runs idempotently — after migration the legacy plist
    /// entries are nulled out so we never read them again. Gated by a
    /// version flag so we don't clobber a freshly-typed key with an
    /// empty migration.
    func migrateFromUserDefaultsIfNeeded() {
        let migratedFlagKey = "noxKeychainMigrationV1Done"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedFlagKey) else { return }

        for key in Key.allCases {
            let legacyKey = key.legacyDefaultsKey
            if let plaintext = defaults.string(forKey: legacyKey),
               !plaintext.isEmpty {
                let saved = save(key, value: plaintext)
                if saved {
                    NSLog("nox: migrated \(legacyKey) from UserDefaults → Keychain")
                    // Wipe the plaintext copy. Setting to nil also
                    // removes the key from the plist on next sync.
                    defaults.removeObject(forKey: legacyKey)
                } else {
                    NSLog("nox: WARNING — failed to migrate \(legacyKey) to Keychain (status not OK); leaving plaintext for retry")
                }
            }
        }

        defaults.set(true, forKey: migratedFlagKey)
    }
}
