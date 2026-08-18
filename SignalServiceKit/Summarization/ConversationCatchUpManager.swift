//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Ties transcript building and summarization together, so callers in the app
/// layer have exactly one thing to call.
///
/// Everything here happens on-device.
public final class ConversationCatchUpManager {

    private let db: any DB
    private let contactManager: any ContactsManagerProtocol
    private let summarizer: any ConversationSummarizer
    private let budget: ConversationTranscriptBuilder.Budget

    public init(
        db: any DB,
        contactManager: any ContactsManagerProtocol,
        summarizer: any ConversationSummarizer,
        budget: ConversationTranscriptBuilder.Budget = .default,
    ) {
        self.db = db
        self.contactManager = contactManager
        self.summarizer = summarizer
        self.budget = budget
    }

    /// The manager the app uses, wired to the real database and the on-device
    /// system model.
    public static func makeDefault() -> ConversationCatchUpManager {
        return ConversationCatchUpManager(
            db: DependenciesBridge.shared.db,
            contactManager: SSKEnvironment.shared.contactManagerRef,
            summarizer: OnDeviceConversationSummarizer(),
        )
    }

    /// Whether summarization can run on this device right now.
    public var availability: ConversationSummarizerAvailability {
        return summarizer.availability
    }

    /// A cheap check for whether it's worth offering to catch the user up.
    ///
    /// This only counts unread messages; it doesn't check whether any of them
    /// carry text. The expensive determination happens in ``catchUp(thread:)``,
    /// which throws ``ConversationSummarizerError/nothingToSummarize`` if the
    /// unread messages turn out to be all attachments and call events.
    public func hasUnreadMessages(thread: TSThread) -> Bool {
        return db.read { tx in
            InteractionFinder(threadUniqueId: thread.uniqueId).unreadCount(transaction: tx) > 0
        }
    }

    /// Summarizes everything the user hasn't read in `thread`.
    ///
    /// - Throws: ``ConversationSummarizerError``.
    public func catchUp(thread: TSThread) async throws -> ConversationSummary {
        let builder = ConversationTranscriptBuilder(
            contactManager: contactManager,
            budget: budget,
        )

        let transcript: ConversationTranscript?
        do {
            transcript = try db.read { tx in
                try builder.buildUnreadTranscript(thread: thread, tx: tx)
            }
        } catch {
            throw ConversationSummarizerError.generationFailed(error)
        }

        guard let transcript, !transcript.isEmpty else {
            throw ConversationSummarizerError.nothingToSummarize
        }

        return try await summarizer.summarize(transcript)
    }
}
