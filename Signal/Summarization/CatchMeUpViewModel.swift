//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import SignalServiceKit

/// Drives the Catch Me Up sheet: kicks off on-device summarization and exposes
/// the result as something the view can render.
@MainActor
class CatchMeUpViewModel: ObservableObject {

    enum State {
        case loading
        case loaded(ConversationSummary)
        case failed(message: String, isRetryable: Bool)
    }

    @Published private(set) var state: State = .loading

    let conversationName: String

    private let thread: TSThread
    private let catchUpManager: ConversationCatchUpManager
    private var task: Task<Void, Never>?

    init(
        thread: TSThread,
        conversationName: String,
        catchUpManager: ConversationCatchUpManager,
    ) {
        self.thread = thread
        self.conversationName = conversationName
        self.catchUpManager = catchUpManager
    }

    /// Stops in-flight generation. Called when the sheet goes away, so a
    /// dismissed sheet doesn't keep the model busy.
    func cancel() {
        task?.cancel()
        task = nil
    }

    func start() {
        guard task == nil else { return }
        run()
    }

    func retry() {
        task?.cancel()
        task = nil
        state = .loading
        run()
    }

    private func run() {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.catchUpManager.catchUp(thread: self.thread)
                guard !Task.isCancelled else { return }
                self.state = .loaded(summary)
            } catch {
                guard !Task.isCancelled else { return }
                self.state = Self.failureState(for: error)
            }
        }
    }

    private static func failureState(for error: any Error) -> State {
        guard let error = error as? ConversationSummarizerError else {
            return .failed(message: Strings.genericError, isRetryable: true)
        }

        switch error {
        case .nothingToSummarize:
            return .failed(message: Strings.nothingToSummarize, isRetryable: false)
        case .transcriptTooLong:
            return .failed(message: Strings.tooManyMessages, isRetryable: false)
        case .refusedByModel:
            return .failed(message: Strings.refused, isRetryable: false)
        case .unsupportedLanguage:
            return .failed(message: Strings.unsupportedLanguage, isRetryable: false)
        case .unavailable(let availability):
            switch availability {
            case .available, .unknown:
                return .failed(message: Strings.genericError, isRetryable: true)
            case .unsupportedOperatingSystem:
                return .failed(message: Strings.unsupportedOS, isRetryable: false)
            case .deviceNotEligible:
                return .failed(message: Strings.deviceNotEligible, isRetryable: false)
            case .appleIntelligenceNotEnabled:
                return .failed(message: Strings.appleIntelligenceOff, isRetryable: false)
            case .modelNotReady:
                return .failed(message: Strings.modelNotReady, isRetryable: true)
            }
        case .generationFailed:
            return .failed(message: Strings.genericError, isRetryable: true)
        }
    }

    private enum Strings {
        static var genericError: String {
            OWSLocalizedString(
                "CATCH_ME_UP_ERROR_GENERIC",
                comment: "Shown when generating an on-device summary of unread messages failed for an unexpected reason.",
            )
        }
        static var nothingToSummarize: String {
            OWSLocalizedString(
                "CATCH_ME_UP_ERROR_NOTHING_TO_SUMMARIZE",
                comment: "Shown when there are no unread text messages to summarize.",
            )
        }
        static var tooManyMessages: String {
            OWSLocalizedString(
                "CATCH_ME_UP_ERROR_TOO_MANY_MESSAGES",
                comment: "Shown when there are too many unread messages to fit in the on-device model.",
            )
        }
        static var refused: String {
            OWSLocalizedString(
                "CATCH_ME_UP_ERROR_REFUSED",
                comment: "Shown when the on-device model declines to summarize the unread messages.",
            )
        }
        static var unsupportedLanguage: String {
            OWSLocalizedString(
                "CATCH_ME_UP_ERROR_UNSUPPORTED_LANGUAGE",
                comment: "Shown when the on-device model does not support the language the conversation is in.",
            )
        }
        static var unsupportedOS: String {
            OWSLocalizedString(
                "CATCH_ME_UP_ERROR_UNSUPPORTED_OS",
                comment: "Shown when the device's operating system is too old to summarize messages on-device.",
            )
        }
        static var deviceNotEligible: String {
            OWSLocalizedString(
                "CATCH_ME_UP_ERROR_DEVICE_NOT_ELIGIBLE",
                comment: "Shown when the device's hardware cannot summarize messages on-device.",
            )
        }
        static var appleIntelligenceOff: String {
            OWSLocalizedString(
                "CATCH_ME_UP_ERROR_APPLE_INTELLIGENCE_OFF",
                comment: "Shown when the user has not enabled Apple Intelligence, which is required to summarize messages on-device.",
            )
        }
        static var modelNotReady: String {
            OWSLocalizedString(
                "CATCH_ME_UP_ERROR_MODEL_NOT_READY",
                comment: "Shown when the on-device model is still downloading or otherwise not ready yet.",
            )
        }
    }
}
