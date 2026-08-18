//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// A rough estimate of how many tokens a string costs in the on-device model.
///
/// The FoundationModels framework exposes no tokenizer, so we cannot count
/// exactly; we can only budget conservatively and handle
/// `exceededContextWindowSize` when we guess low.
///
/// The ratio is not uniform across scripts, and getting this wrong is not a
/// rounding error. Apple's guidance is roughly three to four characters per
/// token for Latin-script languages, but about **one token per character** for
/// Chinese, Japanese and Korean. A budget expressed in characters therefore
/// under-counts CJK text by 3-4x, which is the difference between fitting in
/// the window and reliably failing.
public enum TokenEstimate {

    /// Characters per token for Latin-ish scripts. Deliberately pessimistic:
    /// chat text is full of names, punctuation and short tokens, which tokenize
    /// less efficiently than prose.
    static let latinCharactersPerToken: Double = 3.0

    /// Emoji routinely cost several tokens each.
    static let tokensPerEmoji: Double = 2.0

    /// Estimated token cost of `string`.
    public static func tokens(in string: String) -> Int {
        var denseCharacters = 0   // ~1 token each (CJK)
        var emoji = 0
        var otherCharacters = 0

        for scalarCluster in string {
            if scalarCluster.unicodeScalars.contains(where: \.isEmojiPresentation) {
                emoji += 1
            } else if scalarCluster.unicodeScalars.contains(where: \.isDenselyTokenized) {
                denseCharacters += 1
            } else {
                otherCharacters += 1
            }
        }

        let estimate = Double(denseCharacters)
            + Double(emoji) * tokensPerEmoji
            + Double(otherCharacters) / latinCharactersPerToken

        return Int(estimate.rounded(.up))
    }
}

private extension Unicode.Scalar {

    /// Scripts that tokenize at roughly one token per character.
    var isDenselyTokenized: Bool {
        switch value {
        case 0x3040...0x30FF,      // Hiragana, Katakana
             0x3400...0x4DBF,      // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,      // CJK Unified Ideographs
             0xAC00...0xD7AF,      // Hangul syllables
             0xF900...0xFAFF,      // CJK Compatibility Ideographs
             0x20000...0x2FA1F:    // CJK extensions B-F
            return true
        default:
            return false
        }
    }

    var isEmojiPresentation: Bool {
        return properties.isEmojiPresentation
    }
}
