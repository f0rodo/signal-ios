# Catch Me Up — on-device conversation summaries

A fork feature that summarizes the messages you haven't read yet, using Apple's
on-device system language model. No conversation content leaves the device.

## Status

v1 is implemented and unbuilt. It was written on Linux, where no Swift
toolchain or Xcode exists, so **nothing here has been compiled or run**. See
[Before you trust this](#before-you-trust-this).

## How it works

```
ConversationViewController
  └─ ConversationViewController+CatchMeUp     entry point: nav bar button
       └─ CatchMeUpSheetViewController        bottom sheet
            └─ CatchMeUpView / ViewModel      SwiftUI, loading/loaded/failed
                 └─ ConversationCatchUpManager        (SignalServiceKit)
                      ├─ ConversationTranscriptBuilder  DB → text
                      └─ OnDeviceConversationSummarizer text → summary
```

### SignalServiceKit/Summarization

| File | Role |
| --- | --- |
| `ConversationTranscript.swift` | Value type holding resolved sender names and message text, plus `renderedForPrompt()`. Holds no database objects, so it crosses actor boundaries freely. |
| `ConversationTranscriptBuilder.swift` | Reads unread messages for a thread and turns them into a transcript, within a budget. |
| `ConversationSummarizer.swift` | The `ConversationSummarizer` protocol, `ConversationSummary`, availability and error types. No Apple Intelligence dependency. |
| `OnDeviceConversationSummarizer.swift` | The only file that touches `FoundationModels`. |
| `ConversationCatchUpManager.swift` | Wires the two together so the app layer has one call. |

### Where the unread boundary comes from

`InteractionFinder.oldestUnreadInteraction` gives the read boundary. The
builder then walks **backwards** from the newest message via
`enumerateInteractionsForConversationView(rowIdFilter: .newest)` and stops once
it crosses that boundary or spends its budget. Walking backwards rather than
forwards means a thread with 4,000 unread messages loads ~150, not 4,000 — and
the messages it keeps are the recent ones, which are the ones worth reading.

Skipped as not summarizable: info messages, call events, group updates,
attachments with no caption, and view-once messages (which are meant to be
seen exactly once, by a human — not copied into a summary).

### Budget

The context window is **4,096 tokens in total** — instructions, prompt, schema
and generated output all share it. That is the binding constraint on this
whole feature.

`ConversationTranscriptBuilder.Budget` defaults to 150 lines / 2,200 estimated
transcript tokens / 250 tokens per message, leaving room for the instructions
and the response.

The budget is in **estimated tokens, not characters**, deliberately. Apple's
ratio is roughly 3-4 characters per token for Latin scripts but about *one
token per character* for Chinese, Japanese and Korean. A character budget
therefore undercounts CJK by 3-4x and reliably overflows the window for those
conversations. `TokenEstimate` charges CJK at ~1 token/character, emoji at 2,
and everything else at 3 characters/token.

There is no public tokenizer, so these are estimates and will sometimes guess
low. `ConversationCatchUpManager` handles that: on
`exceededContextWindowSize` it shrinks the budget by 40% and rebuilds, up to
twice, before surfacing an error.

These numbers are still guesses. Tune them once you can measure real overflow
rates on a device — iOS 26.4 added token-usage tracking, which would replace
the estimator with real numbers.

### Prompt injection

Message bodies are untrusted input written by other people, and they go into a
prompt. Two mitigations:

1. `renderedForPrompt()` collapses newlines within a message, so one message
   cannot render as several speaker lines and forge attribution.
2. The transcript is fenced between `BEGIN TRANSCRIPT` / `END TRANSCRIPT` and
   the instructions tell the model to treat everything between them as data,
   never as instructions.

This is mitigation, not a guarantee. A message can still contain text shaped
like a speaker line. The summary is advisory and the UI says so.

## Before you trust this

Roughly in order of how badly each one bites.

1. **Weak-linking `FoundationModels`.** The app's deployment target is iOS 15;
   `FoundationModels` is iOS 26+. If the framework ends up strongly linked, the
   app will fail to launch on every iOS version below 26. Modern `ld` weak-links
   automatically based on the framework's availability metadata, and nothing
   here overrides that — but **verify it**, because the failure mode is "app
   doesn't start" for most of the user base:
   ```
   otool -L Signal.app/Signal | grep -i foundationmodels
   ```
   It should be listed as weak. If it isn't, add `-weak_framework FoundationModels`
   to `OTHER_LDFLAGS` (keeping `$(inherited)` so the CocoaPods xcconfig survives),
   and re-test launch on an iOS 15–25 device or simulator.

2. **The FoundationModels API surface.** `OnDeviceConversationSummarizer.swift`
   was written against the documented iOS 26 API without a compiler. Expect to
   fix names. The pieces it depends on:
   - `SystemLanguageModel.default.availability` → `.available` / `.unavailable(reason)`
   - `LanguageModelSession(instructions:)` with a string literal
   - `session.respond(to:generating:options:)` → `LanguageModelSession.Response<T>`
   - `@Generable` / `@Guide(description:)` on `GeneratedCatchUpSummary`
   - `LanguageModelSession.GenerationError` cases
   Everything else in the feature is plain Swift and does not depend on this.

3. **Everything else compiling.** Ten new files, one nav-bar hook, fifteen
   strings.

4. **The prompt.** Written blind. It will need iteration against real
   conversations — especially group threads, where attribution matters most.

## Trying it

The entry point only appears when the thread has unread messages *and*
`SystemLanguageModel` reports itself available, so on an ineligible device or
simulator you will see nothing. To exercise the UI regardless, present
`CatchMeUpSheetViewController` directly, or drop a stub conforming to
`ConversationSummarizer` into `ConversationCatchUpManager`'s initializer — the
protocol exists precisely so the UI can be driven without Apple Intelligence.

## Tests

`SignalServiceKit/tests/Summarization/ConversationTranscriptTest.swift` covers
prompt rendering, local-user labelling, and newline collapsing. The builder
itself is untested: it needs a database fixture, which is worth adding once the
target compiles.

## If summaries need to cover more than fits

Everything above summarizes a single window. For arbitrarily long histories,
the two standard options are map-reduce (summarize chunks in parallel, then
merge) and refine (carry a running summary forward through chunks in order).
For chat, refine is the better fit — conversations are chronological, and the
research finds refine more accurate than map-reduce on ordered material, at
the cost of being sequential.

One implementation detail matters more than the choice: **a `LanguageModelSession`
accumulates every prompt and response in its transcript**, and that transcript
counts against the same 4,096 tokens. A chunk loop that reuses one session will
overflow after a few chunks no matter how small each chunk is. Each chunk needs
a *fresh* session, carrying forward only the running summary text.

## Deliberately not done

- No caching. Every tap re-summarizes.
- No streaming. The sheet shows a spinner until the whole summary lands;
  `FoundationModels` can stream partial results and should, eventually.
- No cross-chat digest, no arbitrary time ranges — unread-only, by choice.
- No setting to turn the feature off, and no first-run explanation of what
  runs where. Both are needed before this goes near real users.
