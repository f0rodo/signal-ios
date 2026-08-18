//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

extension ConversationViewController {

    /// Shared because building it is cheap but pointless to repeat, and because
    /// the availability check it wraps is queried on every nav bar update.
    static let catchUpManager = ConversationCatchUpManager.makeDefault()

    /// Whether to offer Catch Me Up for this conversation right now.
    ///
    /// There is no point offering it when there is nothing unread, or when the
    /// device can't run the on-device model at all: rather than show an entry
    /// point that always fails, we hide it.
    var canOfferCatchMeUp: Bool {
        guard threadViewModel.unreadCount > 0 else {
            return false
        }
        return Self.catchUpManager.availability.isAvailable
    }

    func makeCatchMeUpBarButtonItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "sparkles"),
            style: .plain,
            target: self,
            action: #selector(didTapCatchMeUp),
        )
        item.accessibilityLabel = OWSLocalizedString(
            "CATCH_ME_UP_BUTTON_LABEL",
            comment: "Accessibility label for the button that summarizes unread messages in a conversation.",
        )
        return item
    }

    @objc
    func didTapCatchMeUp() {
        AssertIsOnMainThread()

        let sheet = CatchMeUpSheetViewController(
            thread: thread,
            conversationName: threadViewModel.name,
            catchUpManager: Self.catchUpManager,
        )
        present(sheet, animated: true)
    }
}
