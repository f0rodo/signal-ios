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

    /// Caps on how much conversation we will feed the model.
    ///
    /// The on-device model has a small context window shared between the
    /// instructions, the transcript and the generated response, so we budget
    /// conservatively and truncate from the *oldest* end: if someone has 400
    /// unread messages, the most recent ones are the ones worth summarizing.
    public struct Budget {
        public let maxLines: Int
        public let maxCharacters: Int
        /// Messages longer than this are individually clipped, so that one
        /// pasted wall of text can't consume the whole budget.
        public let maxCharactersPerLine: Int

        public init(
            maxLines: Int = 150,
            maxCharacters: Int = 8_000,
            maxCharactersPerLine: Int = 1_000,
        ) {
            self.maxLines = maxLines
            self.maxCharacters = maxCharacters
            self.maxCharactersPerLine = maxCharactersPerLine
        }

        public static let `default` = Budget()
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
        var characterCount = 0
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

            guard
                reversedLines.count < self.budget.maxLines,
                characterCount + line.text.count <= self.budget.maxCharacters
            else {
                sawOlderUnreadMessage = true
                return false
            }

            reversedLines.append(line)
            characterCount += line.text.count
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

        let text = String(rawBody.prefix(budget.maxCharactersPerLine))

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
