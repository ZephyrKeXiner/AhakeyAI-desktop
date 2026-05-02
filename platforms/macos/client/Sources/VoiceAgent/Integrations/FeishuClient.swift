import Foundation

// MARK: - Contact model

/// 预指定的飞书联系人，用于 subagent 按名字查找收信人。
public struct FeishuContact: Sendable, Equatable, Codable {
    public enum IDType: String, Sendable, Equatable, Codable {
        case openID = "open_id"
        case userID = "user_id"
        case chatID = "chat_id"
        case email = "email"
    }

    public let name: String
    public let id: String
    public let idType: IDType
    public let aliases: [String]

    public init(name: String, id: String, idType: IDType, aliases: [String] = []) {
        self.name = name
        self.id = id
        self.idType = idType
        self.aliases = aliases
    }

    enum CodingKeys: String, CodingKey {
        case name, id, aliases
        case idType = "id_type"
    }
}

public extension FeishuContact {
    /// 解析顺序:Application Support 下的本地文件 → AHAKEY_FEISHU_CONTACTS_JSON 环境变量。
    /// JSON 示例：[{"name":"智能助手","id":"xxx@example.com","id_type":"email","aliases":["助手"]}]
    static func configuredContacts(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [FeishuContact] {
        let stored = FeishuContactStore.load()
        if !stored.isEmpty {
            return stored
        }
        guard
            let json = VoiceAgentRuntimeConfig.feishuContactsJSON(environment: environment),
            let data = json.data(using: .utf8)
        else {
            return []
        }
        return (try? JSONDecoder().decode([FeishuContact].self, from: data)) ?? []
    }
}

/// 把飞书联系人持久化到 ~/Library/Application Support/AhakeyConfig/feishu-contacts.json。
public enum FeishuContactStore {
    public static let directoryName = "AhakeyConfig"
    public static let fileName = "feishu-contacts.json"

    public static var fileURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func load() -> [FeishuContact] {
        guard
            let url = fileURL,
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let contacts = try? JSONDecoder().decode([FeishuContact].self, from: data)
        else { return [] }
        return contacts
    }

    @discardableResult
    public static func save(_ contacts: [FeishuContact]) -> Bool {
        guard let url = fileURL else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(contacts)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Feishu API client

/// 飞书 Open Platform REST API 封装。
/// 支持 user_access_token（用户身份）和 tenant_access_token（机器人身份）两种模式。
/// 优先使用 user_access_token 发消息，这样其他机器人（如 Aily）能响应。
public actor FeishuClient {
    private let appID: String
    private let appSecret: String
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var refreshTokenValue: String?
    private var cachedUserToken: String?
    private var userTokenExpiresAt: Date = .distantPast

    private var cachedToken: String?
    private var tokenExpiresAt: Date = .distantPast

    public init(
        appID: String,
        appSecret: String,
        refreshToken: String? = nil,
        baseURL: URL = VoiceAgentRuntimeConfig.feishuBaseURL
    ) {
        self.appID = appID
        self.appSecret = appSecret
        self.refreshTokenValue = refreshToken
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - Token management

    /// 获取用于发消息的 token。优先 user_access_token，降级到 tenant_access_token。
    public func accessToken() async throws -> String {
        if refreshTokenValue != nil {
            return try await userAccessToken()
        }
        return try await tenantAccessToken()
    }

    /// 获取有效的 user_access_token，过期用 refresh_token 续期。
    private func userAccessToken() async throws -> String {
        if let token = cachedUserToken, Date() < userTokenExpiresAt {
            return token
        }
        return try await refreshUserToken()
    }

    private func refreshUserToken() async throws -> String {
        guard let refreshToken = refreshTokenValue else {
            throw FeishuError.missingCredentials
        }

        let url = baseURL.appendingPathComponent("authen/v2/oauth/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": appID,
            "client_secret": appSecret,
            "refresh_token": refreshToken,
        ]
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let result = try decoder.decode(FeishuOAuthTokenResponse.self, from: data)
        guard result.code == 0, let token = result.accessToken else {
            throw FeishuError.authFailed(result.errorDescription ?? "Failed to refresh user token")
        }

        cachedUserToken = token
        userTokenExpiresAt = Date().addingTimeInterval(TimeInterval(result.expiresIn ?? 7200) - 300)

        // 更新 refresh_token（飞书可能会返回新的）
        if let newRefreshToken = result.refreshToken, !newRefreshToken.isEmpty {
            refreshTokenValue = newRefreshToken
            VoiceAgentKeychain.saveToKeychain(
                service: VoiceAgentRuntimeConfig.keychainService,
                account: VoiceAgentRuntimeConfig.keychainFeishuRefreshTokenAccount,
                value: newRefreshToken
            )
        }

        return token
    }

    /// 获取有效的 tenant_access_token，过期自动刷新。
    public func tenantAccessToken() async throws -> String {
        if let token = cachedToken, Date() < tokenExpiresAt {
            return token
        }
        return try await refreshTenantToken()
    }

    private func refreshTenantToken() async throws -> String {
        let url = baseURL.appendingPathComponent("auth/v3/tenant_access_token/internal")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "app_id": appID,
            "app_secret": appSecret,
        ]
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let result = try decoder.decode(FeishuTokenResponse.self, from: data)
        guard result.code == 0, let token = result.tenantAccessToken else {
            throw FeishuError.authFailed(result.msg ?? "Unknown error (code \(result.code))")
        }

        cachedToken = token
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(result.expire ?? 7200) - 300)
        return token
    }

    // MARK: - Send message

    /// 发送消息到指定接收者。
    /// - Parameters:
    ///   - receiveID: 接收者 ID（open_id / user_id / chat_id / email）
    ///   - receiveIDType: ID 类型
    ///   - msgType: 消息类型（text / interactive / post 等）
    ///   - content: JSON 格式的消息内容字符串
    /// - Returns: message_id
    @discardableResult
    public func sendMessage(
        receiveID: String,
        receiveIDType: String = "open_id",
        msgType: String = "text",
        content: String
    ) async throws -> String {
        let token = try await accessToken()
        var urlComponents = URLComponents(
            url: baseURL.appendingPathComponent("im/v1/messages"),
            resolvingAgainstBaseURL: false
        )!
        urlComponents.queryItems = [URLQueryItem(name: "receive_id_type", value: receiveIDType)]

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: String] = [
            "receive_id": receiveID,
            "msg_type": msgType,
            "content": content,
        ]
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let result = try decoder.decode(FeishuMessageResponse.self, from: data)
        guard result.code == 0 else {
            throw FeishuError.sendFailed(result.msg ?? "Unknown error (code \(result.code))")
        }
        return result.data?.messageID ?? ""
    }

    // MARK: - List messages

    /// 获取群聊/会话的历史消息。
    /// - Parameters:
    ///   - containerID: chat_id
    ///   - pageSize: 每页数量（默认 20，最大 50）
    ///   - pageToken: 分页 token
    /// - Returns: (messages, nextPageToken)
    public func listMessages(
        containerID: String,
        pageSize: Int = 20,
        pageToken: String? = nil
    ) async throws -> ([FeishuMessageItem], String?) {
        let token = try await tenantAccessToken()
        var urlComponents = URLComponents(
            url: baseURL.appendingPathComponent("im/v1/messages"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [
            URLQueryItem(name: "container_id_type", value: "chat"),
            URLQueryItem(name: "container_id", value: containerID),
            URLQueryItem(name: "page_size", value: String(min(pageSize, 50))),
        ]
        if let pageToken {
            queryItems.append(URLQueryItem(name: "page_token", value: pageToken))
        }
        urlComponents.queryItems = queryItems

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let result = try decoder.decode(FeishuListMessagesResponse.self, from: data)
        guard result.code == 0 else {
            throw FeishuError.apiFailed(result.msg ?? "Unknown error (code \(result.code))")
        }
        return (result.data?.items ?? [], result.data?.pageToken)
    }

    // MARK: - Contact lookup

    /// 按名字、邮箱、手机号或直接 ID 查找飞书联系人。
    public func searchContacts(query: String, limit: Int = 5) async throws -> [FeishuContact] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let direct = Self.directContact(from: trimmed) {
            return [direct]
        }

        if Self.looksLikeEmail(trimmed) {
            return [FeishuContact(name: trimmed, id: trimmed, idType: .email)]
        }

        if Self.looksLikeMobile(trimmed) {
            return try await lookupUsers(emails: [], mobiles: [trimmed], limit: limit)
        }

        return try await searchDirectoryUsers(query: trimmed, limit: limit)
    }

    // MARK: - Helpers

    private func lookupUsers(
        emails: [String],
        mobiles: [String],
        limit: Int
    ) async throws -> [FeishuContact] {
        guard !emails.isEmpty || !mobiles.isEmpty else { return [] }

        let token = try await tenantAccessToken()
        var urlComponents = URLComponents(
            url: baseURL.appendingPathComponent("contact/v3/users/batch_get_id"),
            resolvingAgainstBaseURL: false
        )!
        urlComponents.queryItems = [URLQueryItem(name: "user_id_type", value: FeishuContact.IDType.openID.rawValue)]

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var body: [String: [String]] = [:]
        if !emails.isEmpty { body["emails"] = emails }
        if !mobiles.isEmpty { body["mobiles"] = mobiles }
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let result = try decoder.decode(FeishuBatchGetIDResponse.self, from: data)
        guard result.code == 0 else {
            throw FeishuError.apiFailed(result.msg ?? "Unknown error (code \(result.code))")
        }

        return (result.data?.userList ?? [])
            .prefix(limit)
            .compactMap { item in
                guard let id = item.userID, !id.isEmpty else { return nil }
                let name = item.email ?? item.mobile ?? id
                return FeishuContact(name: name, id: id, idType: .openID)
            }
    }

    private func searchDirectoryUsers(query: String, limit: Int) async throws -> [FeishuContact] {
        let normalizedQuery = Self.normalized(query)
        guard !normalizedQuery.isEmpty else { return [] }

        var exactMatches: [FeishuContact] = []
        var fuzzyMatches: [FeishuContact] = []
        var pageToken: String?
        var pagesScanned = 0

        repeat {
            let (users, nextPageToken, hasMore) = try await listDepartmentUsers(pageToken: pageToken)
            pagesScanned += 1

            for user in users {
                let fields = user.searchableFields.map(Self.normalized)
                guard fields.contains(where: { !$0.isEmpty }) else { continue }
                let contact = user.contact
                if fields.contains(normalizedQuery) {
                    exactMatches.append(contact)
                } else if fields.contains(where: { $0.contains(normalizedQuery) || normalizedQuery.contains($0) }) {
                    fuzzyMatches.append(contact)
                }
            }

            pageToken = hasMore ? nextPageToken : nil
        } while pageToken != nil && pagesScanned < 20 && exactMatches.count < limit

        let matches = exactMatches.isEmpty ? fuzzyMatches : exactMatches
        return Array(matches.prefix(limit))
    }

    private func listDepartmentUsers(
        pageToken: String?
    ) async throws -> ([FeishuDirectoryUser], String?, Bool) {
        let token = try await tenantAccessToken()
        var urlComponents = URLComponents(
            url: baseURL.appendingPathComponent("contact/v3/users/find_by_department"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [
            URLQueryItem(name: "department_id", value: "0"),
            URLQueryItem(name: "department_id_type", value: "open_department_id"),
            URLQueryItem(name: "user_id_type", value: FeishuContact.IDType.openID.rawValue),
            URLQueryItem(name: "page_size", value: "50"),
        ]
        if let pageToken {
            queryItems.append(URLQueryItem(name: "page_token", value: pageToken))
        }
        urlComponents.queryItems = queryItems

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let result = try decoder.decode(FeishuDirectoryUsersResponse.self, from: data)
        guard result.code == 0 else {
            throw FeishuError.apiFailed(result.msg ?? "Unknown error (code \(result.code))")
        }
        return (result.data?.items ?? [], result.data?.pageToken, result.data?.hasMore ?? false)
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeishuError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FeishuError.httpError(httpResponse.statusCode, body)
        }
    }

    private static func directContact(from raw: String) -> FeishuContact? {
        if raw.hasPrefix("oc_") {
            return FeishuContact(name: raw, id: raw, idType: .chatID)
        }
        if raw.hasPrefix("ou_") {
            return FeishuContact(name: raw, id: raw, idType: .openID)
        }
        return nil
    }

    private static func looksLikeEmail(_ value: String) -> Bool {
        value.contains("@") && value.contains(".")
    }

    private static func looksLikeMobile(_ value: String) -> Bool {
        let digits = value.filter(\.isNumber)
        return digits.count >= 8 && digits.count == value.filter { $0.isNumber || $0 == "+" || $0 == "-" || $0 == " " }.count
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Convenience

public extension FeishuClient {
    /// 从 VoiceAgentRuntimeConfig 读取凭证创建客户端。
    /// 如果有 refresh_token 则使用用户身份发消息。
    static func configured() -> FeishuClient? {
        guard
            let appID = VoiceAgentRuntimeConfig.feishuAppID,
            let appSecret = VoiceAgentRuntimeConfig.feishuAppSecret
        else {
            return nil
        }
        let refreshToken = VoiceAgentRuntimeConfig.feishuRefreshToken
        return FeishuClient(appID: appID, appSecret: appSecret, refreshToken: refreshToken)
    }
}

// MARK: - Error

public enum FeishuError: Error, LocalizedError {
    case authFailed(String)
    case sendFailed(String)
    case apiFailed(String)
    case httpError(Int, String)
    case invalidResponse
    case missingCredentials
    case contactNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .authFailed(msg): "Feishu auth failed: \(msg)"
        case let .sendFailed(msg): "Feishu send failed: \(msg)"
        case let .apiFailed(msg): "Feishu API error: \(msg)"
        case let .httpError(code, body): "Feishu HTTP \(code): \(body)"
        case .invalidResponse: "Feishu returned an invalid response."
        case .missingCredentials: "Feishu App ID or App Secret not configured."
        case let .contactNotFound(name): "Contact '\(name)' not found in pre-configured list."
        }
    }
}

// MARK: - API response models

struct FeishuOAuthTokenResponse: Decodable {
    let code: Int
    let accessToken: String?
    let expiresIn: Int?
    let refreshToken: String?
    let refreshTokenExpiresIn: Int?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case code
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case errorDescription = "error_description"
    }
}

struct FeishuTokenResponse: Decodable {
    let code: Int
    let msg: String?
    let tenantAccessToken: String?
    let expire: Int?

    enum CodingKeys: String, CodingKey {
        case code, msg
        case tenantAccessToken = "tenant_access_token"
        case expire
    }
}

struct FeishuMessageResponse: Decodable {
    let code: Int
    let msg: String?
    let data: MessageData?

    struct MessageData: Decodable {
        let messageID: String?

        enum CodingKeys: String, CodingKey {
            case messageID = "message_id"
        }
    }
}

struct FeishuBatchGetIDResponse: Decodable {
    let code: Int
    let msg: String?
    let data: LookupData?

    struct LookupData: Decodable {
        let userList: [UserIDItem]?

        enum CodingKeys: String, CodingKey {
            case userList = "user_list"
        }
    }

    struct UserIDItem: Decodable {
        let userID: String?
        let email: String?
        let mobile: String?

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case email, mobile
        }
    }
}

struct FeishuDirectoryUser: Decodable, Sendable {
    let openID: String?
    let userID: String?
    let name: String?
    let enName: String?
    let nickname: String?
    let email: String?

    var searchableFields: [String] {
        [name, enName, nickname, email, openID, userID].compactMap { $0 }
    }

    var contact: FeishuContact {
        let id = openID ?? userID ?? email ?? name ?? ""
        return FeishuContact(
            name: name ?? nickname ?? email ?? id,
            id: id,
            idType: openID != nil ? .openID : .userID,
            aliases: [enName, nickname, email].compactMap { $0 }
        )
    }

    enum CodingKeys: String, CodingKey {
        case openID = "open_id"
        case userID = "user_id"
        case name
        case enName = "en_name"
        case nickname
        case email
    }
}

struct FeishuDirectoryUsersResponse: Decodable {
    let code: Int
    let msg: String?
    let data: ListData?

    struct ListData: Decodable {
        let items: [FeishuDirectoryUser]?
        let pageToken: String?
        let hasMore: Bool?

        enum CodingKeys: String, CodingKey {
            case items
            case pageToken = "page_token"
            case hasMore = "has_more"
        }
    }
}

public struct FeishuMessageItem: Decodable, Sendable {
    public let messageID: String?
    public let msgType: String?
    public let body: MessageBody?
    public let sender: Sender?
    public let createTime: String?

    public struct MessageBody: Decodable, Sendable {
        public let content: String?
    }

    public struct Sender: Decodable, Sendable {
        public let senderType: String?
        public let id: String?

        enum CodingKeys: String, CodingKey {
            case senderType = "sender_type"
            case id
        }
    }

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case msgType = "msg_type"
        case body, sender
        case createTime = "create_time"
    }
}

struct FeishuListMessagesResponse: Decodable {
    let code: Int
    let msg: String?
    let data: ListData?

    struct ListData: Decodable {
        let items: [FeishuMessageItem]?
        let pageToken: String?
        let hasMore: Bool?

        enum CodingKeys: String, CodingKey {
            case items
            case pageToken = "page_token"
            case hasMore = "has_more"
        }
    }
}
