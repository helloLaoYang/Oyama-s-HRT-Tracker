import Foundation
import SwiftUI

@MainActor
struct FeedbackView: View {
    @State private var title = ""
    @State private var message = ""
    @State private var isSubmitting = false
    @State private var failure: FeedbackSubmissionError?
    @State private var receipt: FeedbackReceipt?

    private var feedback: FeedbackSubmission {
        FeedbackSubmission(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: message.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var body: some View {
        Form {
            if let receipt {
                Section {
                    Label(FeedbackText.localized("Feedback published"), systemImage: "checkmark.circle")
                        .accessibilityIdentifier("feedback.success")
                    Link(FeedbackText.localized("View issue #\(receipt.number) on GitHub"), destination: receipt.url)
                        .accessibilityIdentifier("feedback.issue")
                }
            } else if let endpoint = FeedbackClient.endpoint {
                Section {
                    Text(FeedbackText.localized("A bot will publish your feedback in a public issue on GitHub. You do not need a GitHub account. Please omit personal information, medication records, and lab results."))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("feedback.publicNotice")
                }
                Section {
                    TextField(FeedbackText.localized("Title"), text: $title)
                        .accessibilityIdentifier("feedback.title")
                    TextField(FeedbackText.localized("Describe your feedback"), text: $message, axis: .vertical)
                        .lineLimit(5...10)
                        .accessibilityIdentifier("feedback.body")
                } footer: {
                    if feedback.title.unicodeScalars.count > FeedbackSubmission.titleLimit {
                        Text(FeedbackText.localized("Keep the title within 120 characters."))
                    } else if feedback.body.unicodeScalars.count > FeedbackSubmission.bodyLimit {
                        Text(FeedbackText.localized("Keep the description within 4,000 characters."))
                    }
                }
                .disabled(isSubmitting)
                Section {
                    Button {
                        submit(feedback, to: endpoint)
                    } label: {
                        if isSubmitting {
                            ProgressView(FeedbackText.localized("Sending feedback…"))
                        } else {
                            Text(FeedbackText.localized("Send feedback"))
                        }
                    }
                    .disabled(isSubmitting || !feedback.isValid)
                    .accessibilityIdentifier("feedback.submit")
                } footer: {
                    if let failure {
                        Text(failure.message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("feedback.error")
                    }
                }
            } else {
                Section {
                    Text(FeedbackSubmissionError.unavailable.message)
                        .accessibilityIdentifier("feedback.unavailable")
                }
            }
        }
        .navigationTitle(FeedbackText.localized("Feedback"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
    }

    private func submit(_ feedback: FeedbackSubmission, to endpoint: URL) {
        guard !isSubmitting, feedback.isValid else { return }
        isSubmitting = true
        failure = nil
        Task {
            defer { isSubmitting = false }
            do {
                receipt = try await FeedbackClient.submit(feedback, to: endpoint)
                title = ""
                message = ""
            } catch let error as FeedbackSubmissionError {
                failure = error
            } catch {
                failure = .failed
            }
        }
    }
}

enum FeedbackText {
    static func localized(_ key: String.LocalizationValue) -> String {
        label(key, table: "Feedback")
    }
}

private struct FeedbackSubmission: Encodable {
    static let titleLimit = 120
    static let bodyLimit = 4_000

    let title: String
    let body: String

    var isValid: Bool {
        !title.isEmpty && title.unicodeScalars.count <= Self.titleLimit
            && !body.isEmpty && body.unicodeScalars.count <= Self.bodyLimit
    }
}

private struct FeedbackReceipt: Decodable {
    let number: Int
    let url: URL
}

private enum FeedbackSubmissionError: Error {
    case invalid, rateLimited, unavailable, failed

    var message: String {
        switch self {
        case .invalid: FeedbackText.localized("Check your title and description, then try again.")
        case .rateLimited: FeedbackText.localized("Too many submissions. Wait and try again.")
        case .unavailable: FeedbackText.localized("Feedback is currently unavailable.")
        case .failed: FeedbackText.localized("Could not send your feedback. Please try again.")
        }
    }
}

private enum FeedbackClient {
    static let endpoint: URL? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "HRTFeedbackEndpointURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }()

    private static let session = URLSession(configuration: .ephemeral)

    static func submit(_ feedback: FeedbackSubmission, to endpoint: URL) async throws -> FeedbackReceipt {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        request.httpBody = try JSONEncoder().encode(feedback)

        let (data, response) = try await session.data(for: request, delegate: FeedbackRedirectHandler())
        switch (response as? HTTPURLResponse)?.statusCode {
        case 201:
            let receipt = try JSONDecoder().decode(FeedbackReceipt.self, from: data)
            guard receipt.number > 0,
                  receipt.url.absoluteString == "https://github.com/helloLaoYang/Oyama-s-HRT-Tracker/issues/\(receipt.number)"
            else { throw FeedbackSubmissionError.failed }
            return receipt
        case 400, 413: throw FeedbackSubmissionError.invalid
        case 429: throw FeedbackSubmissionError.rateLimited
        case 502, 503: throw FeedbackSubmissionError.unavailable
        default: throw FeedbackSubmissionError.failed
        }
    }
}

private final class FeedbackRedirectHandler: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
