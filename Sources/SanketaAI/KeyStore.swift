import Foundation
import Security

/// Where a typed API key is kept, one per server host.
public protocol KeyStore: Sendable {
    func read(account: String) -> String?
    func write(_ key: String, account: String) throws
    func delete(account: String) throws
}

/// Generic passwords in the login keychain, through `SecItem*` only.
public struct KeychainStore: KeyStore {
    /// A Keychain call that failed. It holds the `OSStatus` only, never the key.
    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "Keychain error \(status)" }
    }

    public let service: String

    public init(service: String = "dev.sanketa.Sanketa") { self.service = service }

    func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    public func write(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Sanketa API key (\(account))"
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

/// Keys in memory, for tests.
public final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]

    public init() {}

    public func read(account: String) -> String? { lock.withLock { keys[account] } }
    public func write(_ key: String, account: String) throws { lock.withLock { keys[account] = key } }
    public func delete(account: String) throws { lock.withLock { keys[account] = nil } }
}
