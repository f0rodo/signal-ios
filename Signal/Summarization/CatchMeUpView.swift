//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import SwiftUI

/// The contents of the Catch Me Up sheet.
struct CatchMeUpView: View {

    @ObservedObject var viewModel: CatchMeUpViewModel

    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch viewModel.state {
                    case .loading:
                        loadingContent
                    case .loaded(let summary):
                        summaryContent(summary)
                    case .failed(let message, let isRetryable):
                        failureContent(message: message, isRetryable: isRetryable)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }

            footer
        }
        .background(Color.Signal.groupedBackground)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings.title)
                    .font(.headline)
                    .foregroundStyle(Color.Signal.label)
                Text(viewModel.conversationName)
                    .font(.subheadline)
                    .foregroundStyle(Color.Signal.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer()

            Button(CommonStrings.doneButton, action: onDone)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.Signal.accent)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - States

    private var loadingContent: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(Strings.loading)
                .font(.subheadline)
                .foregroundStyle(Color.Signal.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func summaryContent(_ summary: ConversationSummary) -> some View {
        Text(summary.headline)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.Signal.label)
            .fixedSize(horizontal: false, vertical: true)

        if !summary.bulletPoints.isEmpty {
            section(
                title: Strings.whatHappened,
                items: summary.bulletPoints,
                bulletColor: Color.Signal.tertiaryLabel,
            )
        }

        if !summary.actionItems.isEmpty {
            section(
                title: Strings.needsYourAttention,
                items: summary.actionItems,
                bulletColor: Color.Signal.accent,
            )
        }
    }

    @ViewBuilder
    private func failureContent(message: String, isRetryable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.Signal.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)

            if isRetryable {
                Button(CommonStrings.retryButton) {
                    viewModel.retry()
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.Signal.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func section(
        title: String,
        items: [String],
        bulletColor: Color,
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Color.Signal.secondaryLabel)

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(bulletColor)
                        .frame(width: 5, height: 5)
                        // Nudge the dot down so it sits on the first line's
                        // optical centre rather than its top.
                        .padding(.top, 7)
                    Text(item)
                        .font(.subheadline)
                        .foregroundStyle(Color.Signal.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        Text(Strings.onDeviceFooter)
            .font(.caption)
            .foregroundStyle(Color.Signal.tertiaryLabel)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
    }

    // MARK: - Strings

    private enum Strings {
        static var title: String {
            OWSLocalizedString(
                "CATCH_ME_UP_TITLE",
                comment: "Title of the sheet that summarizes unread messages in a conversation.",
            )
        }
        static var loading: String {
            OWSLocalizedString(
                "CATCH_ME_UP_LOADING",
                comment: "Shown while a summary of unread messages is being generated on the device.",
            )
        }
        static var whatHappened: String {
            OWSLocalizedString(
                "CATCH_ME_UP_SECTION_WHAT_HAPPENED",
                comment: "Header for the list of things that happened in the unread messages.",
            )
        }
        static var needsYourAttention: String {
            OWSLocalizedString(
                "CATCH_ME_UP_SECTION_NEEDS_ATTENTION",
                comment: "Header for the list of unread messages that appear to need a reply or action.",
            )
        }
        static var onDeviceFooter: String {
            OWSLocalizedString(
                "CATCH_ME_UP_ON_DEVICE_FOOTER",
                comment: "Footer clarifying that the summary was generated on the user's own device and that summaries can be wrong.",
            )
        }
    }
}
