# Summarizing long chats on a 4K on-device model

Research notes for the summarizer. Written against Apple's on-device
FoundationModels model, but most of it is model-agnostic.

Sources are listed at the bottom.

## 1. The constraint that decides everything else

The on-device model's context window is **4,096 tokens, total** — instructions,
prompt, the guided-generation schema, *and* the generated output all come out of
the same budget. Exceed it and you get `exceededContextWindowSize`.

Three consequences that are easy to get wrong:

**Tokens are not characters, and the ratio is not constant.** Roughly 3–4
characters per token for Latin-script languages, but about **one token per
character** for Chinese, Japanese and Korean. Emoji cost several tokens each.
A budget expressed in characters silently overshoots by 3–4× for CJK
conversations. (We hit this — the first version of `Budget` was in characters.)

**There is no public tokenizer.** You cannot count before sending; you can only
estimate and handle the error. iOS 26.4 added token-usage *tracking*, which
gives you real numbers after the fact — useful for calibrating an estimator, not
for preventing an overflow. So treat overflow as an expected, recoverable
outcome: shrink and retry, don't fail the user.

**A session's transcript accumulates.** Every `respond()` call appends its
prompt and response to the `LanguageModelSession` transcript, and that
transcript counts against the same 4,096 tokens. This is the trap in every
chunking loop: reuse one session across chunks and you will overflow after a
few chunks no matter how small each chunk is. **Each chunk needs a fresh
session**, carrying forward only the running summary text. Apple's own guidance
for long tasks is to start new sessions for subtasks and pass forward a summary
of what came before.

## 2. Picking a strategy

| Strategy | How it works | Good for | Cost |
| --- | --- | --- | --- |
| **Stuff** | Everything in one prompt | Fits in the window | 1 call, best quality |
| **Refine** | Running summary carried forward chunk by chunk | Ordered material | N sequential calls |
| **Map-reduce** | Summarize chunks independently, then merge | Speed, parallelism | N parallel + 1 |
| **Hierarchical merge** | Merge pairwise up a tree until one summary remains | Very long inputs | O(N) calls, deeper |

For **chat specifically, refine is the better default** once you exceed one
window. Conversations are chronological and causally linked — later messages
resolve earlier ones — and the research finds refine more accurate than
map-reduce on ordered material, precisely because it maintains an evolving
global context. Map-reduce's advantage is parallelism, which matters less here:
on-device inference is serialized by the hardware anyway.

Hierarchical merging is what you reach for when even refine is too many
sequential calls. Its known weakness is **error propagation** — a mistake in an
early chunk summary is inherited by everything above it, and later stages can't
see the source text to correct it. Passing some original context alongside the
intermediate summaries mitigates this.

Practical shape for us:

- Unread fits in one window → **stuff** (what we do today)
- Unread spans a handful of windows → **refine**, fresh session per chunk
- Unread spans a lot → **hierarchical**, and consider telling the user the
  summary is coarse rather than pretending otherwise

## 3. Chunking a conversation

Don't chunk on a fixed token count. Chat has natural seams and they are better
split points:

- **Never split a speaker turn.** A half-message attributed to the wrong person
  is worse than a smaller chunk.
- **Prefer time gaps.** A multi-hour silence is almost always a topic boundary.
- **Overlap slightly** (a few turns) so a thread of discussion spanning a seam
  isn't decapitated.
- Chunk size is task-dependent: smaller chunks isolate specific facts better,
  larger chunks preserve thematic and contextual relationships. Catch-up
  summaries lean thematic, so err larger.

**Position bias matters here.** Models weight the beginning and end of the
context disproportionately, and degrade on material buried in the middle — the
"lost in the middle" effect, an echo of primacy and recency. Notably, *recency
dominates as the content grows to fill the window*, which is the regime we're
in. Two implications:

- Putting the newest messages last is right for catch-up — they're both what
  the user cares about most and where the model attends most.
- Anything that must not be missed (the instruction to be faithful, the note
  that the transcript is truncated) belongs at the very top or very bottom, not
  buried mid-prompt.

## 4. Prompt design

### The failure mode is not what you'd guess

The instinct is to guard against fabrication. But the ACL 2024 analysis of LLM
behaviour in *dialogue* summarization finds the dominant modern error is
different: models "generate plausible inferences, supported by circumstantial
evidence in the conversation, that lack direct evidence." They named the
category **Contextual Inference**, and note it is *less* prevalent in older
models — this is a behaviour that got worse as models got more capable.

In chat, that looks like:

- asserting people **agreed** when they only discussed
- reporting how someone **feels** from tone alone
- resolving an ambiguous **pronoun or name** to the most plausible candidate
- supplying the **conclusion** a discussion was heading toward but never reached

So "don't make things up" is the wrong instruction — the model isn't making
things up, it's over-reading. The instructions need to forbid inference
specifically, and give the model a licence to leave things unresolved:

```
- Report only what people actually said. Do not infer how anyone feels, what
  they intended, or whether they agreed, unless they said so outright.
- If a discussion was left open, say it was left open. Do not supply the
  conclusion it seemed to be heading toward.
- If you are unsure who said something or who a name refers to, leave it out.
```

### Grounding

Give the model the source and tell it the source is the only permitted
authority: *"Summarize only from the text provided. If the text does not state
something, say so. Do not guess or add outside information."* Grounding this
explicitly measurably reduces pull from parametric knowledge.

The strongest single lever is **asking for a short supporting quote per claim** —
a hybrid extractive/abstractive shape, where generation is constrained to
material that was actually selected from the source. It's also expensive: quotes
cost output tokens, and we have very few. A reasonable compromise on a 4K
window is to require evidence only for the highest-stakes field — action items,
where a false positive costs the user a real mistake.

### Structured output

Guided generation (`@Generable`) is worth it beyond convenience: constraining
decoding to a schema removes a whole class of formatting failures and the
parsing code that goes with them. Note the schema itself consumes prompt tokens.

**Control length through the schema, not through the prose.** Small models are
unreliable at "in about 50 words". "Three bullet points" enforced structurally
is reliable in a way a word count is not.

### Chain of Density — interesting, wrong fit here

Chain of Density iteratively rewrites a summary to be more entity-dense: start
sparse, then repeatedly identify 1–3 missing salient entities and fuse them in
*without increasing length*, ~5 times. Humans preferred the denser outputs over
vanilla GPT-4 summaries.

It's a poor fit for this product as specified: five round-trips on a 4K window,
and every iteration grows the session transcript against the same budget. The
transferable insight is smaller and still useful — **first-pass summaries are
entity-sparse** — which could justify a *single* "what salient detail did you
omit?" pass later, on a fresh session, rather than five.

## 5. Measuring quality

This is the part that needs the most decisions, and where the missing
`spec-summary-quality.md` presumably lives.

**One number is not enough.** The consensus shape is 3–6 rubric dimensions
scored separately — typically **faithfulness, coverage, coherence,
conciseness** — with faithfulness dominating for summarization. Collapsing them
hides the tradeoff that actually matters: a summary can be perfectly faithful
and useless (says nothing) or comprehensive and wrong.

**An uncalibrated LLM judge is, in the memorable phrasing from the literature, a
confident random number generator.** If we use LLM-as-judge: pin the judge
model, version the rubric prompt, and score it against human-labelled examples
to measure agreement before trusting it on anything.

### The tension specific to this product

Standard eval practice is to run a bigger judge model over real inputs. **We
cannot do that.** The entire premise is that conversation content never leaves
the device. A pipeline that ships user chats to a judge model destroys the
thing being built.

That pushes the eval design toward a **synthetic fixture corpus** — conversations
we author, with ground truth planted deliberately:

- facts that **are** stated (must appear → coverage)
- facts that are **not** stated but strongly implied (must **not** appear →
  catches Contextual Inference, the dominant error)
- discussions deliberately **left unresolved** (must be reported as open)
- **ambiguous** pronouns and repeated names (must not be confidently resolved)
- **adversarial** messages containing instruction-shaped text (must be
  summarized as content, not obeyed)
- **mixed-language** and CJK threads (exercise the token budget)
- **large group** threads with many speakers (attribution stress)

Synthetic fixtures are weaker than real data for measuring naturalness, but far
stronger for measuring faithfulness, because you know the ground truth exactly.
For anything needing real conversations, it has to be explicitly consented
dogfooding on our own threads — not a background pipeline.

## 6. What this implies for the code as it stands

Done:

- Budget in estimated tokens, script-aware (`TokenEstimate`)
- Overflow treated as recoverable — shrink and retry
- Instructions target Contextual Inference, not just fabrication
- Guided generation for structured output
- Newest messages last (right side of the position-bias curve)

Not done, roughly in order of value:

1. **Refine pipeline for backlogs larger than one window.** Today we truncate
   and say so. Fresh session per chunk — this is where the transcript-growth
   trap bites.
2. **Fixture corpus + a way to run it.** Nothing above is measurable until this
   exists. It is also the cheapest thing on this list.
3. **Chunking on time gaps and turn boundaries** rather than a flat cap.
4. **Evidence quotes for action items.**
5. **Streaming**, so long summaries feel responsive instead of a spinner.
6. **Calibrate `TokenEstimate`** against the real iOS 26.4 token-usage numbers.

## Sources

- [TN3193: Managing the on-device foundation model's context window](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)
- [Deep dive into the Foundation Models framework — WWDC25](https://developer.apple.com/videos/play/wwdc2025/301/)
- [Counting tokens in Foundation Models](https://zats.io/blog/counting-tokens-in-foundation-models/)
- [Tracking token usage in Foundation Models](https://artemnovichkov.com/blog/tracking-token-usage-in-foundation-models)
- [Analyzing LLM Behavior in Dialogue Summarization: Unveiling Circumstantial Hallucination Trends (ACL 2024)](https://aclanthology.org/2024.acl-long.677/)
- [Context-Aware Hierarchical Merging for Long Document Summarization](https://arxiv.org/pdf/2502.00977)
- [BooookScore: A systematic exploration of book-length summarization](https://arxiv.org/pdf/2310.00785)
- [From Sparse to Dense: GPT-4 Summarization with Chain of Density Prompting](https://arxiv.org/pdf/2309.04269)
- [Lost in the Middle: How Language Models Use Long Contexts](https://cs.stanford.edu/~nfliu/papers/lost-in-the-middle.arxiv2023.pdf)
- [Positional Biases Shift as Inputs Approach Context Window Limits](https://arxiv.org/pdf/2508.07479)
- [Mitigating Hallucination in Abstractive Summarization (NAACL 2024 Findings)](https://aclanthology.org/2024.findings-naacl.117.pdf)
- [LLM-as-a-judge: a complete guide to using LLMs for evaluations](https://www.evidentlyai.com/llm-guide/llm-as-a-judge)
- [LLM Evaluation Rubrics: Templates, Examples, and Reviewer Calibration](https://www.twine.net/blog/llm-evaluation-rubrics/)
- [Master LLM Summarization Strategies and their Implementations](https://galileo.ai/blog/llm-summarization-strategies)
