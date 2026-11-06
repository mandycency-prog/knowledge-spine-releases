import Foundation
import Security
import KnowledgeSpineCore

/// Only this App's endpoint-specific credentials are queried. No secret enters
/// AppSettings, manifests, analytics or log messages.
enum APICredentials {
    private static var service: String {
        Bundle.main.object(forInfoDictionaryKey: "KnowledgeSpineDistributionPreview") as? Bool == true
            ? "com.local.knowledgespine.preview.analysis-api" : "com.local.knowledgespine.analysis-api"
    }

    static func contains(endpoint: String) throws -> Bool {
        let query = try identity(endpoint)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw CredentialError.status(status) }
        return true
    }

    static func load(endpoint: String) throws -> String? {
        var query = try identity(endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.status(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw CredentialError.invalidData
        }
        return key
    }

    static func save(_ key: String, endpoint: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw CredentialError.empty }
        let query = try identity(endpoint)
        let updates: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialError.status(added) }
        } else if status != errSecSuccess { throw CredentialError.status(status) }
    }

    static func delete(endpoint: String) throws {
        let status = SecItemDelete(try identity(endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.status(status) }
    }

    private static func identity(_ endpoint: String) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: try APIConfiguration.normalizedEndpoint(endpoint)]
    }

    private enum CredentialError: LocalizedError {
        case status(OSStatus), invalidData, empty
        var errorDescription: String? {
            switch self {
            case .status(let code): "无法访问此服务的钥匙串凭据（错误码 \(code)）。"
            case .invalidData: "已保存的密钥格式无法读取，请重新保存。"
            case .empty: "请输入非空且不含换行的 API 密钥。"
            }
        }
    }
}
