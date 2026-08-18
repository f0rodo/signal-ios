//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// A plain-text rendering of some slice of a conversation, suitable for
/// handing to an on-device summarization model.
///
/// This type deliberately holds no database objects and no message identifiers
/// beyond what is needed to render text. Once a transcript has been built it
/// can be passed across actor boundaries without a transaction.
public struct ConversationTranscript: Equatable {

    public struct Line: Equatable {
        /// The display name of whoever sent this message, already resolved.
        public let senderName: String
        /// Whether this message was sent by the local user.
        public let isLocalUser: Bool
        /// When the message was received, per the local clock.
        public let receivedAt: Date
        /// The message body. Never empty.
        public let text: String

        public init(
            senderName: String,
            isLocalUser: Bool,
            receivedAt: Date,
            text: String,
        ) {
            self.senderName = senderName
            self.isLocalUser = isLocalUser
            self.receivedAt = receivedAt
            self.text = text
        }
    }

    /// The name of the conversation, used to give the model context.
    public let conversationName: String
    /// Whether this is a group conversation. Group summaries mention who said
    /// what; 1:1 summaries generally shouldn't.
    public let isGroup: Bool
    /// Lines in chronological order, oldest first.
    public let lines: [Line]
    /// How many unread messages the thread has in total, which may exceed
    /// `lines.count` if the transcript was truncated to fit the budget.
    public let totalUnreadCount: Int
    /// Whether older messages were dropped to fit within the budget.
    public let isTruncated: Bool

    public init(
        conversationName: String,
        isGroup: Bool,
        lines: [Line],
        totalUnreadCount: Int,
        isTruncated: Bool,
    ) {
        self.conversationName = conversationName
        self.isGroup = isGroup
        self.lines = lines
        self.totalUnreadCount = totalUnreadCount
        self.isTruncated = isTruncated
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// Renders the transcript as the plain text handed to the model.
    ///
    /// Lines look like `Alice: hey, are we still on for tomorrow?`. Timestamps
    /// are omitted: they cost tokens, and the model does not need them to
    /// produce a useful catch-up summary.
    public func renderedForPrompt() -> String {
        return lines
            .map { line in
                let name = line.isLocalUser ? Self.localUserPromptName : line.senderName
                // Collapse newlines so one message stays on one line, which
                // keeps the speaker attribution unambiguous.
                let text = line.text
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                return "\(name): \(text)"
            }
            .joined(separator: "\n")
    }

    /// How the local user is referred to in the prompt. Not localized: this is
    /// model-facing text, and the model is instructed to reply in the
    /// conversation's own language regardless.
    static let localUserPromptName = "Me"
}
