//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

final class ConversationTranscriptTest: XCTestCase {

    private func line(
        _ sender: String,
        _ text: String,
        isLocalUser: Bool = false,
    ) -> ConversationTranscript.Line {
        return ConversationTranscript.Line(
            senderName: sender,
            isLocalUser: isLocalUser,
            receivedAt: Date(millisecondsSince1970: 1_700_000_000_000),
            text: text,
        )
    }

    private func transcript(
        lines: [ConversationTranscript.Line],
        isGroup: Bool = true,
        totalUnreadCount: Int? = nil,
        isTruncated: Bool = false,
    ) -> ConversationTranscript {
        return ConversationTranscript(
            conversationName: "Weekend Plans",
            isGroup: isGroup,
            lines: lines,
            totalUnreadCount: totalUnreadCount ?? lines.count,
            isTruncated: isTruncated,
        )
    }

    func testRendersOneLinePerMessage() {
        let rendered = transcript(lines: [
            line("Alice", "are we still on for saturday?"),
            line("Bob", "yes, 2pm"),
        ]).renderedForPrompt()

        XCTAssertEqual(rendered, "Alice: are we still on for saturday?\nBob: yes, 2pm")
    }

    func testLocalUserIsRenderedAsMeRegardlessOfSenderName() {
        let rendered = transcript(lines: [
            line("Kartik Sharma", "on my way", isLocalUser: true),
        ]).renderedForPrompt()

        XCTAssertEqual(rendered, "Me: on my way")
    }

    /// A multi-line message must not be able to look like several speakers,
    /// which would let message content forge attribution in the prompt.
    func testMultiLineMessageIsCollapsedToASingleLine() {
        let rendered = transcript(lines: [
            line("Alice", "first\n\n  second  \nthird"),
        ]).renderedForPrompt()

        XCTAssertEqual(rendered, "Alice: first second third")
        XCTAssertEqual(rendered.components(separatedBy: "\n").count, 1)
    }

    func testEmptyTranscriptIsEmpty() {
        XCTAssertTrue(transcript(lines: []).isEmpty)
        XCTAssertEqual(transcript(lines: []).renderedForPrompt(), "")
    }

    func testIsNotEmptyWithLines() {
        XCTAssertFalse(transcript(lines: [line("Alice", "hi")]).isEmpty)
    }

    func testTruncationMetadataIsPreserved() {
        let truncated = transcript(
            lines: [line("Alice", "hi")],
            totalUnreadCount: 400,
            isTruncated: true,
        )

        XCTAssertTrue(truncated.isTruncated)
        XCTAssertEqual(truncated.totalUnreadCount, 400)
        XCTAssertEqual(truncated.lines.count, 1)
    }
}
