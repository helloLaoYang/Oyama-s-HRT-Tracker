import Foundation

enum AIAssistantReplyGuard {
    typealias Update = @MainActor @Sendable (String) throws -> Void

    @MainActor
    static func completedReply(
        using generate: (Update) async throws -> String,
        onUpdate: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let response: String
        do {
            response = try await generate { snapshot in
                try Task.checkCancellation()
                onUpdate(try streamText(snapshot))
            }
        } catch StreamStop.roleBoundary(let prefix) {
            response = prefix
        }
        try Task.checkCancellation()
        guard let answer = finalText(response) else { throw AIOfflineModel.Failure.emptyResponse }
        return answer
    }

    enum StreamStop: Error {
        case roleBoundary(prefix: String)
    }

    private static let roles = [
        "user", "assistant", "system",
        "用户", "用戶", "使用者", "助手", "助理",
        "benutzer", "assistent", "utilisateur",
        "ユーザー", "アシスタント",
    ]
    private static let markers = ["<|im_start|>", "<|im_end|>", "<|endoftext|>"]

    static func streamText(_ response: String) throws -> String {
        guard let boundary = roleBoundary(in: response, includingPartialLastLine: true) else { return response }
        let prefix = String(response[..<boundary.start])
        if boundary.isComplete { throw StreamStop.roleBoundary(prefix: prefix) }
        return prefix
    }

    static func finalText(_ response: String) -> String? {
        let response = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = response[..<(roleBoundary(in: response)?.start ?? response.endIndex)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func roleBoundary(in response: String, includingPartialLastLine: Bool = false)
        -> (start: String.Index, isComplete: Bool)? {
        var fence: (character: Character, length: Int)?
        var start = response.startIndex
        while start < response.endIndex {
            let end = response[start...].firstIndex(where: \.isNewline) ?? response.endIndex
            let line = response[start..<end].drop(while: \.isWhitespace)
            if let opening = line.first, opening == "`" || opening == "~" {
                let length = line.prefix(while: { $0 == opening }).count
                if length >= 3 {
                    if let current = fence {
                        if opening == current.character, length >= current.length,
                           line.dropFirst(length).allSatisfy(\.isWhitespace) {
                            fence = nil
                        }
                    } else {
                        fence = (opening, length)
                    }
                }
            }
            if fence == nil, !line.isEmpty {
                let value = line.lowercased()
                let isLastLine = end == response.endIndex
                let partial = includingPartialLastLine && isLastLine
                if markers.contains(where: { value.hasPrefix($0) }) {
                    return (start, true)
                }
                if isLastLine, partial || value.hasPrefix("<|"), markers.contains(where: { $0.hasPrefix(value) }) {
                    return (start, false)
                }
                for role in roles {
                    if value.hasPrefix(role) {
                        let suffix = value.dropFirst(role.count).drop(while: \.isWhitespace)
                        if suffix.first == ":" || suffix.first == "：" { return (start, true) }
                        if partial, suffix.isEmpty { return (start, false) }
                    } else if partial && role.hasPrefix(value) {
                        return (start, false)
                    }
                }
            }
            if end == response.endIndex { break }
            start = response.index(after: end)
        }
        return nil
    }
}
