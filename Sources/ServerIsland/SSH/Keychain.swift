import Foundation
import Security

/// "记住密码"只存进系统钥匙串（登录钥匙串里的通用密码，服务名 ServerIsland，账户是服务器的 UUID）。
/// 配置文件、日志里都不会出现密码。
enum Keychain {
    static let service = "ServerIsland"

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func password(for id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 只查有没有，不读内容（不会触发钥匙串授权弹窗）。
    static func has(_ id: UUID) -> Bool {
        var q = query(id)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    @discardableResult
    static func save(_ password: String, for id: UUID, label: String) -> Bool {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var add = query(id)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "ServerIsland – " + label
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
