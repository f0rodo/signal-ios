//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// The result of summarizing a slice of a conversation.
public struct ConversationSummary: Equatable {
    /// One sentence capturing the gist. Always present.
    public let headline: String
    /// A handful of short bullets covering what happened.
    public let bulletPoints: [String]
    /// Things that appear to need the user's response or action. Often empty.
    public let actionItems: [String]

    public init(
        headline: String,
        bulletPoints: [String],
        actionItems: [String],
    ) {
        self.headline = headline
        self.bulletPoints = bulletPoints
        self.actionItems = actionItems
    }
}

/// Why summarization is or isn't possible on this device right now.
///
/// Summarization runs entirely on-device, so all of these are local
/// conditions: none of them involve the network or Signal's servers.
public enum ConversationSummarizerAvailability: Equatable {
    case available
    /// The OS is too old to have an on-device model at all.
    case unsupportedOperatingSystem
    /// The hardware can't run the model.
    case deviceNotEligible
    /// The user hasn't turned on Apple Intelligence in Settings.
    case appleIntelligenceNotEnabled
    /// The model is still downloading, or the device is too low on resources.
    case modelNotReady
    case unknown

    public var isAvailable: Bool { self == .available }
}

public enum ConversationSummarizerError: Error {
    /// On-device summarization isn't possible right now.
    case unavailable(ConversationSummarizerAvailability)
    /// There were no unread text messages to summarize.
    case nothingToSummarize
    /// The transcript didn't fit in the model's context window even after
    /// truncation.
    case transcriptTooLong
    /// The model declined to summarize this content.
    case refusedByModel
    /// The conversation is in a language the on-device model doesn't support.
    case unsupportedLanguage
    /// Anything else the model layer threw.
    case generationFailed(any Error)
}

/// Produces a short summary of a conversation transcript.
///
/// Implementations must never send conversation content off the device.
public protocol ConversationSummarizer {
    /// Whether summarization can run right now, and if not, why not.
    ///
    /// Cheap enough to call from the main thread when deciding whether to show
    /// an entry point.
    var availability: ConversationSummarizerAvailability { get }

    /// Summarizes `transcript`, or throws a ``ConversationSummarizerError``.
    func summarize(_ transcript: ConversationTranscript) async throws -> ConversationSummary
}
