//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Presents ``CatchMeUpView`` as a bottom sheet.
class CatchMeUpSheetViewController: HostingController<CatchMeUpView> {

    init(
        thread: TSThread,
        conversationName: String,
        catchUpManager: ConversationCatchUpManager,
    ) {
        let viewModel = CatchMeUpViewModel(
            thread: thread,
            conversationName: conversationName,
            catchUpManager: catchUpManager,
        )

        // The view needs a way to dismiss us, but we don't exist until after
        // `super.init`. Hand it an indirect reference we fill in below.
        var dismissHandler: (() -> Void)?
        super.init(wrappedView: CatchMeUpView(
            viewModel: viewModel,
            onDone: { dismissHandler?() },
        ))
        dismissHandler = { [weak self] in
            self?.dismiss(animated: true)
        }

        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("unimplemented")
    }

    override var prefersNavigationBarHidden: Bool { true }
}
