//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Builds a ``ConversationTranscript`` from the messages in a thread.
///
/// The only slice we currently build is "everything the user hasn't read yet",
/// which is what powers Catch Me Up.
public struct ConversationTranscriptBuilder {

    /// Caps on how much conversation we will feed the model in one pass.
    ///
    /// The on-device model's context window is 4,096 tokens *in total*, shared
    /// between the instructions, the transcript and the generated response. So
    /// the transcript gets a fraction of that, and we truncate from the
    /// *oldest* end: if someone has 400 unread messages, the recent ones are
    /// the ones worth summarizing.
    ///
    /// The budget is in estimated tokens rather than characters on purpose.
    /// Characters are not a proxy for tokens across scripts — CJK text costs
    /// roughly one token per character, about 3x what the same character count
    /// costs in English — so a character budget silently overshoots the window
    /// for a large share of the world's conversations. See ``TokenEstimate``.
    public struct Budget {
        public let maxLines: Int
        /// Estimated tokens the whole transcript may occupy.
        public let maxTranscriptTokens: Int
        /// Messages longer than this are individually clipped, so that one
        /// pasted wall of text can't consume the whole budget.
        public let maxTokensPerLine: Int

        public init(
            maxLines: Int = 150,
            maxTranscriptTokens: Int = 2_200,
            maxTokensPerLine: Int = 250,
        ) {
            self.maxLines = maxLines
            self.maxTranscriptTokens = maxTranscriptTokens
            self.maxTokensPerLine = maxTokensPerLine
        }

        public static let `default` = Budget()

        /// A smaller budget, for retrying after the model reports that the
        /// context window overflowed anyway.
        public func reduced(by factor: Double = 0.6) -> Budget {
            return Budget(
                maxLines: max(10, Int(Double(maxLines) * factor)),
                maxTranscriptTokens: max(200, Int(Double(maxTranscriptTokens) * factor)),
                maxTokensPerLine: maxTokensPerLine,
            )
        }
    }

    private let contactManager: any ContactsManagerProtocol
    private let budget: Budget

    public init(
        contactManager: any ContactsManagerProtocol,
        budget: Budget = .default,
    ) {
        self.contactManager = contactManager
        self.budget = budget
    }

    /// Builds a transcript of the unread messages in `thread`.
    ///
    /// Returns `nil` when there is nothing worth summarizing: no unread
    /// messages, or unread messages that carry no text (attachments only,
    /// call events, group updates, and so on).
    public func buildUnreadTranscript(
        thread: TSThread,
        tx: DBReadTransaction,
    ) throws -> ConversationTranscript? {
        let finder = InteractionFinder(threadUniqueId: thread.uniqueId)

        guard
            let oldestUnread = try finder.oldestUnreadInteraction(transaction: tx),
            let oldestUnreadRowId = oldestUnread.sqliteRowId
        else {
            return nil
        }

        // Walk backwards from the newest message rather than forwards from the
        // read boundary. Both directions cover the same messages, but going
        // backwards lets us stop as soon as the budget is spent instead of
        // loading every unread message in a badly-backlogged thread.
        var reversedLines: [ConversationTranscript.Line] = []
        var tokenCount = 0
        var sawOlderUnreadMessage = false

        try finder.enumerateInteractionsForConversationView(
            rowIdFilter: .newest,
            tx: tx,
        ) { interaction in
            guard
                let rowId = interaction.sqliteRowId,
                rowId >= oldestUnreadRowId
            else {
                // We've walked back past the read boundary; everything older
                // has already been read.
                return false
            }

            guard let line = self.line(for: interaction, tx: tx) else {
                // Not summarizable (info message, call, attachment with no
                // caption). Keep walking.
                return true
            }

            // Budget the rendered line, not just its body: the sender name and
            // separator are sent to the model too.
            let lineTokens = TokenEstimate.tokens(in: line.senderName) + TokenEstimate.tokens(in: line.text) + 2

            guard
                reversedLines.count < self.budget.maxLines,
                tokenCount + lineTokens <= self.budget.maxTranscriptTokens
            else {
                sawOlderUnreadMessage = true
                return false
            }

            reversedLines.append(line)
            tokenCount += lineTokens
            return true
        }

        guard !reversedLines.isEmpty else {
            return nil
        }

        return ConversationTranscript(
            conversationName: Self.conversationName(
                for: thread,
                contactManager: contactManager,
                tx: tx,
            ),
            isGroup: thread.isGroupThread,
            lines: reversedLines.reversed(),
            totalUnreadCount: Int(finder.unreadCount(transaction: tx)),
            isTruncated: sawOlderUnreadMessage,
        )
    }

    // MARK: - Private

    private func line(
        for interaction: TSInteraction,
        tx: DBReadTransaction,
    ) -> ConversationTranscript.Line? {
        guard let message = interaction as? TSMessage else {
            // Info messages, call records, and similar carry no conversational
            // content worth summarizing.
            return nil
        }

        // View-once messages are meant to be seen exactly once, by a human. Do
        // not copy their contents into a summary.
        guard !message.isViewOnceMessage else {
            return nil
        }

        guard
            let rawBody = message.rawBody(transaction: tx)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        else {
            return nil
        }

        let text = Self.clipped(rawBody, toTokens: budget.maxTokensPerLine)

        let senderName: String
        let isLocalUser: Bool
        switch message {
        case let incoming as TSIncomingMessage:
            senderName = contactManager.displayNameString(
                for: incoming.authorAddress,
                transaction: tx,
            )
            isLocalUser = false
        case is TSOutgoingMessage:
            senderName = ConversationTranscript.localUserPromptName
            isLocalUser = true
        default:
            return nil
        }

        return ConversationTranscript.Line(
            senderName: senderName,
            isLocalUser: isLocalUser,
            receivedAt: Date(millisecondsSince1970: message.receivedAtTimestamp),
            text: text,
        )
    }

    /// Clips `text` to roughly `tokenLimit` estimated tokens.
    ///
    /// Binary search rather than a character ratio, because the ratio depends
    /// on the script and a single message can mix scripts.
    private static func clipped(_ text: String, toTokens tokenLimit: Int) -> String {
        guard TokenEstimate.tokens(in: text) > tokenLimit else {
            return text
        }

        var low = 0
        var high = text.count
        while low < high {
            let mid = (low + high + 1) / 2
            if TokenEstimate.tokens(in: String(text.prefix(mid))) <= tokenLimit {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return String(text.prefix(low))
    }

    private static func conversationName(
        for thread: TSThread,
        contactManager: any ContactsManagerProtocol,
        tx: DBReadTransaction,
    ) -> String {
        switch thread {
        case let groupThread as TSGroupThread:
            return groupThread.groupNameOrDefault
        case let contactThread as TSContactThread:
            return contactManager.displayNameString(
                for: contactThread.contactAddress,
                transaction: tx,
            )
        default:
            return ""
        }
    }
}
