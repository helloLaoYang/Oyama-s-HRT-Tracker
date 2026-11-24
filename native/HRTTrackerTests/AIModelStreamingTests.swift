import XCTest
@testable import HRTTracker

final class AIModelStreamingTests: XCTestCase {
    func testResponsesStreamRequestUsesTypedPartsAndOptInTools() throws {
        let profile = try makeProfile(api: .responses, summary: true)
        let request = try streamRequest(profile, attachments: attachments, generateImage: true)
        XCTAssertEqual(request.url?.absoluteString, "https://localhost:19443/proxy/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream, application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        let body = try jsonBody(request)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["instructions"] as? String, "Fixture instructions")
        XCTAssertEqual(body["reasoning"] as? [String: String], ["effort": "high", "summary": "auto"])
        XCTAssertEqual(body["max_output_tokens"] as? Int, AIModelClient.compatibleOutputLimit(for: profile))
        XCTAssertGreaterThan(AIModelClient.compatibleOutputLimit(for: profile), AIModelClient.compatibleOutputLimit)
        XCTAssertNil(body["previous_response_id"])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "image_generation")
        XCTAssertEqual(tools.first?["partial_images"] as? Int, 1)
        XCTAssertEqual(tools.first?["output_format"] as? String, "png")
        XCTAssertNil(body["tool_choice"], "The model must be able to return text for an out-of-scope image request.")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let parts = try XCTUnwrap(input.first?["content"] as? [[String: String]])
        XCTAssertEqual(parts.map { $0["type"] }, ["input_text", "input_image", "input_file"])
        XCTAssertEqual(parts[1]["image_url"], "data:image/png;base64,\(imageHeader.base64EncodedString())")
        XCTAssertEqual(parts[2]["file_data"], "data:application/pdf;base64,\(pdfHeader.base64EncodedString())")
        XCTAssertEqual(parts[2]["filename"], "report.pdf")

        let connection = try AIModelClient.completionRequest(system: "", input: "", profile: profile, apiKey: nil)
        let connectionBody = try jsonBody(connection)
        XCTAssertEqual(connectionBody["stream"] as? Bool, false)
        XCTAssertEqual(connectionBody["max_output_tokens"] as? Int, AIModelClient.compatibleOutputLimit)
        XCTAssertNil(connectionBody["reasoning"])
        XCTAssertNil(connectionBody["tools"])
    }

    func testChatStreamRequestKeepsImageAndPDFInMessageContent() throws {
        let profile = try makeProfile(api: .chatCompletions)
        let request = try streamRequest(profile, attachments: attachments)
        XCTAssertEqual(request.url?.absoluteString, "https://localhost:19443/proxy/v1/chat/completions")
        let body = try jsonBody(request)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
        XCTAssertNil(body["reasoning"])
        XCTAssertNil(body["tools"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image_url", "file"])
        XCTAssertEqual(content[1]["image_url"] as? [String: String],
                       ["url": "data:image/png;base64,\(imageHeader.base64EncodedString())"])
        XCTAssertEqual(content[2]["file"] as? [String: String], [
            "filename": "report.pdf", "file_data": "data:application/pdf;base64,\(pdfHeader.base64EncodedString())"
        ])
        XCTAssertThrowsError(try streamRequest(profile, attachments: [], generateImage: true)) {
            XCTAssertEqual($0 as? AIModelClientError, .requestRejected)
        }
    }

    func testAttachmentValidationRejectsUnsupportedFormatsAndCombinedSize() throws {
        let profile = try makeProfile(api: .responses)
        var largeData = pdfHeader
        largeData.append(Data(repeating: 0, count: AIAssistantAttachment.maxTotalBytes - largeData.count))
        let oversized = AIAssistantAttachment(name: "report.pdf", mimeType: "application/pdf", data: largeData)
        let unsupported = AIAssistantAttachment(name: "archive.zip", mimeType: "application/zip", data: Data([1]))
        for invalid in [[unsupported], [oversized, attachments[0]]] {
            XCTAssertThrowsError(try streamRequest(profile, attachments: invalid)) {
                XCTAssertEqual($0 as? AIModelClientError, .invalidAttachments)
            }
        }
    }

    func testEventFramingHandlesCommentsMultilineDataAndCRLF() throws {
        let text = "\u{FEFF}: keepalive\r\nevent: message\r\ndata: first\r\ndata:  second\r\n\r\ndata: next\n\n"
        var parser = AISSEResponseParser()
        var events: [AISSEResponseParser.Frame] = []
        for byte in text.utf8 {
            if let event = try parser.consume(byte) { events.append(event) }
        }
        XCTAssertEqual(events, [.init(name: "message", data: Data("first\n second".utf8)),
                                .init(name: nil, data: Data("next".utf8))])
    }

    func testResponsesEmitsOnlyPublicSummaryAndDoesNotDuplicateFinalItems() throws {
        var decoder = AIProviderStreamDecoder(api: .responses, includeReasoningSummary: true, includeImages: true)
        let payloads = [
            #"{"type":"response.reasoning_text.delta","delta":"private"}"#,
            #"{"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":0,"delta":"Public summary"}"#,
            #"{"type":"response.output_text.delta","output_index":2,"content_index":0,"delta":"Hello"}"#,
            #"{"type":"response.image_generation_call.partial_image","output_index":1,"partial_image_b64":"AQ=="}"#,
            #"{"type":"response.output_item.done","output_index":1,"item":{"type":"image_generation_call","result":"Ag=="}}"#,
            #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"Public summary"}],"encrypted_content":"private"},{"type":"image_generation_call","result":"Ag=="},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}]}}"#,
        ]
        var updates: [AIStreamUpdate] = []
        for payload in payloads { updates += try decoder.consume(frame(payload)) }
        XCTAssertEqual(updates, [.reasoningSummary("Public summary"), .text("Hello"),
                                 .imagePreview(Data([1])), .image(Data([2]))])
        XCTAssertNoThrow(try decoder.validateCompletion())
    }

    func testImageModeAcceptsATextOnlyResponse() throws {
        var decoder = AIProviderStreamDecoder(api: .responses, includeImages: true)
        let text = "I can help illustrate HRTrace or HRT topics."
        let terminal = try completed(items: [["type": "message", "role": "assistant",
                                              "content": [["type": "output_text", "text": text]]]])
        XCTAssertEqual(try decoder.consume(terminal), [.text(text)])
        XCTAssertNoThrow(try decoder.validateCompletion())
    }

    func testJSONFallbackAndFailureDoNotMistakePartialOutputForCompletion() throws {
        var fallback = AIProviderStreamDecoder(api: .responses, includeImages: true)
        let json = #"{"status":"completed","output":[{"type":"image_generation_call","result":"Aw=="},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}]}"#
        XCTAssertEqual(try fallback.consumeJSON(Data(json.utf8)), [.image(Data([3])), .text("Done")])

        var failed = AIProviderStreamDecoder(api: .responses)
        XCTAssertThrowsError(try failed.consume(frame(#"{"type":"response.incomplete"}"#))) {
            XCTAssertEqual($0 as? AIModelClientError, .interruptedStream)
        }

        var chat = AIProviderStreamDecoder(api: .chatCompletions, includeReasoningSummary: true)
        let delta = #"{"choices":[{"index":0,"delta":{"content":"Hello","reasoning_content":"private"}}]}"#
        XCTAssertEqual(try chat.consume(frame(delta)), [.text("Hello")])
        XCTAssertThrowsError(try chat.validateCompletion()) {
            XCTAssertEqual($0 as? AIModelClientError, .interruptedStream)
        }
        XCTAssertEqual(try chat.consume(frame("[DONE]")), [])
        XCTAssertNoThrow(try chat.validateCompletion())
    }

    func testRecordChangeToolUsesStrictSchemaAndRequiresEligibleOptIn() throws {
        let profile = try makeProfile(api: .responses)
        let body = try jsonBody(streamRequest(profile, attachments: [], allowRecordChanges: true))
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNil(body["tool_choice"])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let tool = try XCTUnwrap(tools.first)
        XCTAssertEqual(tool["type"] as? String, "function")
        XCTAssertEqual(tool["name"] as? String, "propose_record_change")
        XCTAssertEqual(tool["strict"] as? Bool, true)
        let schema = try XCTUnwrap(tool["parameters"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let keys = Set(arguments.keys)
        XCTAssertEqual(Set(try XCTUnwrap(schema["required"] as? [String])), keys)
        let fields = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(Set(fields.keys), keys)
        XCTAssertEqual(fields["operation"]?["type"] as? String, "string")
        XCTAssertEqual(fields["operation"]?["enum"] as? [String], ["add_dose", "edit_dose", "add_lab", "edit_lab"])
        for field in keys.subtracting(["operation"]) {
            XCTAssertTrue((fields[field]?["type"] as? [String])?.contains("null") == true, field)
        }

        let defaultBody = try jsonBody(streamRequest(profile, attachments: []))
        XCTAssertNil(defaultBody["tools"])
        let chat = try makeProfile(api: .chatCompletions)
        XCTAssertNil(try jsonBody(streamRequest(chat, attachments: [], allowRecordChanges: true))["tools"])
        let image = try jsonBody(streamRequest(profile, attachments: [], generateImage: true, allowRecordChanges: true))
        XCTAssertEqual((image["tools"] as? [[String: Any]])?.first?["type"] as? String, "image_generation")
    }

    func testRecordChangeToolOnlyEmitsOnceAfterCompletedResponse() throws {
        var decoder = AIProviderStreamDecoder(api: .responses, allowRecordChanges: true)
        let item = try functionItem()
        let partial = frame(#"{"type":"response.function_call_arguments.delta","delta":"{\"operation\": "}"#)
        XCTAssertEqual(try decoder.consume(partial), [])
        let done = try jsonFrame(["type": "response.output_item.done", "output_index": 0, "item": item])
        XCTAssertEqual(try decoder.consume(done), [])
        XCTAssertThrowsError(try decoder.validateCompletion()) {
            XCTAssertEqual($0 as? AIModelClientError, .interruptedStream)
        }
        let terminal = try completed(items: [item])
        let updates = try decoder.consume(terminal)
        guard updates.count == 1, case .recordChange(let proposal) = updates[0] else {
            return XCTFail("Expected exactly one proposal after completion")
        }
        XCTAssertEqual(proposal.operation, .editDose)
        XCTAssertEqual(proposal.recordRef, "fact-2")
        XCTAssertEqual(proposal.occurredAt, "2026-11-23T22:40:00+08:00")
        XCTAssertNil(proposal.amount)
        XCTAssertEqual(try decoder.consume(terminal), [])
        XCTAssertNoThrow(try decoder.validateCompletion())

        var compatible = AIProviderStreamDecoder(api: .responses, allowRecordChanges: true)
        let response = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [item]])
        XCTAssertEqual(try compatible.consumeJSON(response), [.recordChange(proposal)])
        XCTAssertEqual(try compatible.consumeJSON(response), [])

        var buffered = AIProviderStreamDecoder(api: .responses, allowRecordChanges: true)
        XCTAssertEqual(try buffered.consume(done), [])
        XCTAssertEqual(try buffered.consume(completed(items: [])), [.recordChange(proposal)])

        var malformed = AIProviderStreamDecoder(api: .responses, allowRecordChanges: true)
        XCTAssertEqual(try malformed.consume(done), [])
        let invalidTerminal = try jsonFrame(["type": "response.completed", "response": ["output": "malformed"]])
        XCTAssertThrowsError(try malformed.consume(invalidTerminal)) {
            XCTAssertEqual($0 as? AIModelClientError, .invalidResponse)
        }
    }

    func testRecordChangeToolRejectsDisabledUnknownAndMalformedArguments() throws {
        var disabled = AIProviderStreamDecoder(api: .responses)
        XCTAssertThrowsError(try disabled.consume(completed(items: [functionItem()])))

        var missing = arguments
        missing.removeValue(forKey: "amount")
        var extra = arguments
        extra["sql"] = "invalid"
        var unknown = arguments
        unknown["operation"] = "delete_dose"
        var unregisteredTool = try functionItem()
        unregisteredTool["name"] = "execute_unknown"
        for item in [unregisteredTool, try functionItem(missing), try functionItem(extra), try functionItem(unknown)] {
            var decoder = AIProviderStreamDecoder(api: .responses, allowRecordChanges: true)
            XCTAssertThrowsError(try decoder.consume(completed(items: [item]))) {
                XCTAssertEqual($0 as? AIModelClientError, .invalidResponse)
            }
        }
    }

    func testRecordChangeToolRejectsDuplicateAndConflictingCalls() throws {
        let item = try functionItem()
        let done = try jsonFrame(["type": "response.output_item.done", "output_index": 0, "item": item])
        var repeated = AIProviderStreamDecoder(api: .responses, allowRecordChanges: true)
        XCTAssertEqual(try repeated.consume(done), [])
        XCTAssertThrowsError(try repeated.consume(done))

        var duplicate = AIProviderStreamDecoder(api: .responses, allowRecordChanges: true)
        XCTAssertThrowsError(try duplicate.consume(completed(items: [item, item])))

        var conflicting = AIProviderStreamDecoder(api: .responses, allowRecordChanges: true)
        XCTAssertEqual(try conflicting.consume(done), [])
        var altered = arguments
        altered["occurred_at"] = "2026-11-23T23:00:00+08:00"
        XCTAssertThrowsError(try conflicting.consume(completed(items: [functionItem(altered)])))

        var incomplete = AIProviderStreamDecoder(api: .responses, allowRecordChanges: true)
        XCTAssertEqual(try incomplete.consume(done), [])
        XCTAssertThrowsError(try incomplete.consume(frame(#"{"type":"response.incomplete"}"#))) {
            XCTAssertEqual($0 as? AIModelClientError, .interruptedStream)
        }
    }

    private var attachments: [AIAssistantAttachment] {
        [.init(name: "image.png", mimeType: "image/png", data: imageHeader),
         .init(name: "report.pdf", mimeType: "application/pdf", data: pdfHeader)]
    }

    private var imageHeader: Data { Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) }
    private var pdfHeader: Data { Data("%PDF-1.7\n".utf8) }

    private func makeProfile(api: AIProviderAPI, summary: Bool = false) throws -> AIProviderProfile {
        let base = try XCTUnwrap(AIModelClient.baseURL(from: "https://localhost:19443/proxy/v1/responses"))
        return AIProviderProfile(baseURL: base, model: "fixture-model", effort: .high, contextLimit: 128_000,
                                 api: api, requestsReasoningSummary: summary)
    }

    private func streamRequest(_ profile: AIProviderProfile, attachments: [AIAssistantAttachment],
                               generateImage: Bool = false, allowRecordChanges: Bool = false) throws -> URLRequest {
        try AIModelClient.compatibleRequest(system: "Fixture instructions", input: "Fixture prompt", profile: profile,
                                            apiKey: "fixture-key", attachments: attachments, generateImage: generateImage,
                                            stream: true, allowRecordChanges: allowRecordChanges)
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func frame(_ text: String) -> AISSEResponseParser.Frame { .init(name: nil, data: Data(text.utf8)) }

    private var arguments: [String: Any] {
        ["operation": "edit_dose", "record_ref": "fact-2", "target_at": NSNull(),
         "occurred_at": "2026-11-23T22:40:00+08:00", "drug": NSNull(), "route": NSNull(),
         "amount": NSNull(), "unit": NSNull(), "patch_count": NSNull(), "wear_days": NSNull(),
         "assay": NSNull(), "analyte": NSNull(), "gel_site": NSNull(), "hold_minutes": NSNull()]
    }

    private func functionItem(_ values: [String: Any]? = nil) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: values ?? arguments, options: .sortedKeys)
        return ["type": "function_call", "name": "propose_record_change", "call_id": "call_1",
                "status": "completed", "arguments": String(decoding: data, as: UTF8.self)]
    }

    private func completed(items: [[String: Any]]) throws -> AISSEResponseParser.Frame {
        try jsonFrame(["type": "response.completed", "response": ["status": "completed", "output": items]])
    }

    private func jsonFrame(_ object: [String: Any]) throws -> AISSEResponseParser.Frame {
        .init(name: nil, data: try JSONSerialization.data(withJSONObject: object))
    }
}
