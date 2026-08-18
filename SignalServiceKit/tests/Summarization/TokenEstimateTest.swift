//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

final class TokenEstimateTest: XCTestCase {

    func testEmptyStringCostsNothing() {
        XCTAssertEqual(TokenEstimate.tokens(in: ""), 0)
    }

    func testLatinTextIsCheaperThanOneTokenPerCharacter() {
        let text = "are we still on for saturday afternoon"
        let estimate = TokenEstimate.tokens(in: text)

        XCTAssertLessThan(estimate, text.count)
        XCTAssertGreaterThan(estimate, 0)
    }

    /// The bug this guards: CJK costs roughly one token per character, about
    /// three times what the same character count costs in English. Budgeting
    /// in characters silently overshoots the context window for these scripts.
    func testCJKCostsRoughlyOneTokenPerCharacter() {
        for text in ["今天下午三点开会", "こんにちは、明日の予定は", "안녕하세요 내일 봐요"] {
            let estimate = TokenEstimate.tokens(in: text)
            XCTAssertGreaterThanOrEqual(estimate, text.count, text)
        }
    }

    func testCJKCostsMoreThanLatinOfTheSameLength() {
        let latin = String(repeating: "a", count: 40)
        let han = String(repeating: "中", count: 40)

        XCTAssertGreaterThan(
            TokenEstimate.tokens(in: han),
            TokenEstimate.tokens(in: latin) * 2,
        )
    }

    func testEmojiCostMoreThanOneTokenEach() {
        let emoji = "🎉🎉🎉🎉"
        XCTAssertGreaterThanOrEqual(TokenEstimate.tokens(in: emoji), 8)
    }

    func testEstimateGrowsMonotonicallyWithLength() {
        let short = TokenEstimate.tokens(in: "hello there")
        let long = TokenEstimate.tokens(in: "hello there, and here is quite a lot more text besides")

        XCTAssertGreaterThan(long, short)
    }

    func testMixedScriptIsChargedPerSegment() {
        let mixed = "meeting 会議 at 3"
        let latinOnly = "meeting at 3"

        XCTAssertGreaterThan(
            TokenEstimate.tokens(in: mixed),
            TokenEstimate.tokens(in: latinOnly),
        )
    }
}
