import Foundation

// MARK: - Send Message Tool

/// 飞书发消息工具：支持按预指定联系人名字或直接用 ID 发送。
public struct FeishuSendMessageTool: VoiceAgentTool {
    public let name = "feishu_send_message"
    public let description = """
        Send a message via Feishu/Lark. \
        You can specify a contact by name, alias, email, mobile, or direct ID (use the 'contact' field), \
        or directly provide 'receive_id' + 'receive_id_type'. \
        The message content should be plain text.
        """

    public let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "contact": .object([
                "type": .string("string"),
                "description": .string("Contact name/alias/email/mobile/direct ID. The tool resolves local aliases first, then searches Feishu contacts."),
            ]),
            "receive_id": .object([
                "type": .string("string"),
                "description": .string("Direct Feishu ID (open_id, user_id, chat_id, or email). Use when 'contact' is not available."),
            ]),
            "receive_id_type": .object([
                "type": .string("string"),
                "enum": .array([.string("open_id"), .string("user_id"), .string("chat_id"), .string("email")]),
                "description": .string("Type of receive_id. Defaults to open_id."),
            ]),
            "message": .object([
                "type": .string("string"),
                "description": .string("The text message to send."),
            ]),
        ]),
        "required": .array([.string("message")]),
    ])

    private let client: FeishuClient
    private let contactBook: FeishuContactBook

    public init(client: FeishuClient, contacts: [FeishuContact] = []) {
        self.client = client
        self.contactBook = FeishuContactBook(contacts: contacts)
    }

    public func call(input: String, context: VoiceAgentToolContext) async throws -> String {
        let args = try parseJSON(input)

        let message = args["message"] ?? ""
        guard !message.isEmpty else {
            return "Error: message cannot be empty."
        }

        let receiveID: String
        let receiveIDType: String

        if let contactName = args["contact"] {
            let resolved = try await resolveContact(contactName)
            switch resolved {
            case let .single(contact):
                receiveID = contact.id
                receiveIDType = contact.idType.rawValue
            case let .multiple(matches):
                return "Error: multiple contacts matched '\(contactName)'. Specify one of:\n\(renderContacts(matches))"
            case .none:
                return "Error: contact '\(contactName)' not found in local aliases or Feishu contacts. Provide receive_id directly."
            }
        } else if let directID = args["receive_id"] {
            receiveID = directID
            receiveIDType = args["receive_id_type"] ?? "open_id"
        } else {
            return "Error: provide either 'contact' name or 'receive_id'."
        }

        let contentJSON = try makeTextContentJSON(message)

        let messageID = try await client.sendMessage(
            receiveID: receiveID,
            receiveIDType: receiveIDType,
            msgType: "text",
            content: contentJSON
        )
        return "Message sent successfully. message_id: \(messageID)"
    }

    private func resolveContact(_ query: String) async throws -> ContactResolution {
        let localMatches = contactBook.matches(query)
        if localMatches.count == 1 {
            return .single(localMatches[0])
        }
        if localMatches.count > 1 {
            return .multiple(localMatches)
        }

        let remoteMatches = try await client.searchContacts(query: query)
        if remoteMatches.count == 1 {
            return .single(remoteMatches[0])
        }
        if remoteMatches.count > 1 {
            return .multiple(remoteMatches)
        }
        return .none
    }
}

// MARK: - List Messages Tool

/// 读取飞书群聊历史消息。
public struct FeishuListMessagesTool: VoiceAgentTool {
    public let name = "feishu_list_messages"
    public let description = """
        List recent messages from a Feishu/Lark group chat. \
        Requires a chat_id. Returns the most recent messages.
        """

    public let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "chat_id": .object([
                "type": .string("string"),
                "description": .string("The Feishu chat ID to read messages from."),
            ]),
            "count": .object([
                "type": .string("integer"),
                "description": .string("Number of messages to fetch (default 10, max 50)."),
            ]),
        ]),
        "required": .array([.string("chat_id")]),
    ])

    private let client: FeishuClient

    public init(client: FeishuClient) {
        self.client = client
    }

    public func call(input: String, context: VoiceAgentToolContext) async throws -> String {
        let args = try parseJSON(input)

        guard let chatID = args["chat_id"], !chatID.isEmpty else {
            return "Error: chat_id is required."
        }

        let count = Int(args["count"] ?? "10") ?? 10
        let (messages, _) = try await client.listMessages(
            containerID: chatID,
            pageSize: min(count, 50)
        )

        if messages.isEmpty {
            return "No messages found in this chat."
        }

        var lines: [String] = ["Found \(messages.count) message(s):"]
        for msg in messages {
            let sender = msg.sender?.id ?? "unknown"
            let senderType = msg.sender?.senderType ?? "unknown"
            let content = msg.body?.content ?? "(no content)"
            let time = msg.createTime ?? ""
            lines.append("[\(time)] \(senderType):\(sender) — \(content)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Lookup Contact Tool

/// 查询预指定联系人信息。
public struct FeishuLookupContactTool: VoiceAgentTool {
    public let name = "feishu_lookup_contact"
    public let description = """
        Look up a Feishu contact by name/alias/email/mobile/direct ID. \
        Resolves local aliases first, then searches Feishu contacts. \
        Returns the ID and type so you can send a message.
        """

    public let parameters: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "description": .string("Contact name to look up (case-insensitive)."),
            ]),
        ]),
        "required": .array([.string("name")]),
    ])

    private let client: FeishuClient
    private let contactBook: FeishuContactBook

    public init(client: FeishuClient, contacts: [FeishuContact]) {
        self.client = client
        self.contactBook = FeishuContactBook(contacts: contacts)
    }

    public func call(input: String, context: VoiceAgentToolContext) async throws -> String {
        let args = try parseJSON(input)

        if let name = args["name"], !name.isEmpty {
            let localMatches = contactBook.matches(name)
            if localMatches.count == 1 {
                return "Found local contact: \(renderContact(localMatches[0]))"
            }
            if localMatches.count > 1 {
                return "Multiple local contacts matched '\(name)':\n\(renderContacts(localMatches))"
            }

            let remoteMatches = try await client.searchContacts(query: name)
            if remoteMatches.count == 1 {
                return "Found Feishu contact: \(renderContact(remoteMatches[0]))"
            }
            if remoteMatches.count > 1 {
                return "Multiple Feishu contacts matched '\(name)':\n\(renderContacts(remoteMatches))"
            }
        }

        // 列出所有联系人
        if contactBook.contacts.isEmpty {
            return "No local contacts configured. Provide a name/email/mobile and I will search Feishu contacts."
        }
        return "Available local contacts:\n\(renderContacts(contactBook.contacts))"
    }
}

// MARK: - JSON helpers

private enum ContactResolution {
    case none
    case single(FeishuContact)
    case multiple([FeishuContact])
}

private struct FeishuContactBook {
    let contacts: [FeishuContact]

    init(contacts: [FeishuContact]) {
        self.contacts = contacts
    }

    func matches(_ query: String) -> [FeishuContact] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let exact = contacts.filter { contact in
            lookupKeys(for: contact).contains(normalizedQuery)
        }
        if !exact.isEmpty {
            return exact
        }

        return contacts.filter { contact in
            lookupKeys(for: contact).contains { $0.contains(normalizedQuery) || normalizedQuery.contains($0) }
        }
    }

    private func lookupKeys(for contact: FeishuContact) -> [String] {
        ([contact.name, contact.id] + contact.aliases).map(normalize)
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private func renderContacts(_ contacts: [FeishuContact]) -> String {
    contacts
        .sorted { $0.name < $1.name }
        .map(renderContact)
        .joined(separator: "\n")
}

private func renderContact(_ contact: FeishuContact) -> String {
    let aliasText = contact.aliases.isEmpty ? "" : " aliases: \(contact.aliases.joined(separator: ", "))"
    return "\(contact.name) — \(contact.idType.rawValue): \(contact.id)\(aliasText)"
}

private func parseJSON(_ input: String) throws -> [String: String] {
    guard let data = input.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return [:]
    }
    var result: [String: String] = [:]
    for (key, value) in obj {
        if let s = value as? String {
            result[key] = s
        } else if let n = value as? NSNumber {
            result[key] = n.stringValue
        }
    }
    return result
}

private func makeTextContentJSON(_ text: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ["text": text], options: [])
    guard let json = String(data: data, encoding: .utf8) else {
        throw FeishuError.invalidResponse
    }
    return json
}
