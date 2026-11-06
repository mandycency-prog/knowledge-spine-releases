import Foundation

public struct APIConfiguration: Codable, Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public var contextWindow: Int
    public var maxOutputTokens: Int
    public var tokenLimitField: String
    public var jsonMode: Bool
    public var approvedEndpoint: String?
    public var thinkingMode: String? = nil
    public var approvedImageEndpoint: String? = nil

    public init(baseURL: String = "", model: String = "", contextWindow: Int = 32768,
                maxOutputTokens: Int = 4096, tokenLimitField: String = "max_tokens",
                jsonMode: Bool = true, approvedEndpoint: String? = nil, thinkingMode: String? = nil,
                approvedImageEndpoint: String? = nil) {
        self.baseURL = baseURL
        self.model = model
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.tokenLimitField = tokenLimitField
        self.jsonMode = jsonMode
        self.approvedEndpoint = approvedEndpoint
        self.thinkingMode = thinkingMode
        self.approvedImageEndpoint = approvedImageEndpoint
    }

    public var isApproved: Bool { !baseURL.isEmpty && approvedEndpoint == baseURL }
    public var isImageApproved: Bool { !baseURL.isEmpty && approvedImageEndpoint == baseURL }

    /// Identity includes the entire service base path, never only its host.
    public static func normalizedEndpoint(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
            throw EndpointError.invalid
        }
        parts.scheme = scheme
        parts.host = host
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        guard let normalized = parts.string else { throw EndpointError.invalid }
        return normalized
    }

    public enum EndpointError: LocalizedError {
        case invalid
        public var errorDescription: String? {
            "请填写有效的 HTTPS 服务地址，不含密钥、查询参数或片段；仅本机服务允许 HTTP。"
        }
    }
}
