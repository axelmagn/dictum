# Spike 1a — Findings

**Date:** 2026-09-29. **Status:** done.

## 1. Answer

**Pass.** Quantized `small.en` (175–264 MB) with a disfluent initial prompt and greedy decoding
keeps nearly all fillers and repetitions in journaling-style speech, with no hallucination in a
13 s pause. Without the prompt, every model tested drops essentially all of them.

## 2. Results

One founder-recorded clip (3 min 23 s, journaling register, one ~13 s pause), recorded in the
browser as WebM/Opus. No hand-written reference was made. Runs were judged against each other
and by listening. `large-v3-turbo-q8_0` S2 was the most disfluent run and serves as the reference.

| Model | Setting | Size | Disfluencies vs. reference | Word errors | Pause hallucination | RTF (GPU) |
|---|---|---|---|---|---|---|
| base.en | S1 (no prompt) | 148 MB | **~0 kept** | many | none | 0.007 |
| base.en | S2 | 148 MB | most; miscounted a repeat | many | none | 0.004 |
| base.en | S3 (beam 5) | 148 MB | fewer than S2; looped "I don't…" ×4 | fewer | none | 0.008 |
| small.en-q5_0 | S2 | 175 MB | misses 1 | few | none | 0.007 |
| small.en-q8_0 | S2 | 264 MB | misses 2 | few | none | 0.007 |
| small.en (f16) | S2 | 488 MB | identical to q8_0 | few | none | 0.011 |
| medium.en-q5_0 | S2 | 539 MB | misses 1 | ~none | none | 0.014 |
| medium.en-q8_0 / f16 | S2 | 823 / 1534 MB | misses 1; q8_0 ≈ f16 | ~none | none | 0.014–0.018 |
| large-v3-turbo-q8_0 | S2 | 874 MB | reference | ~none | none | 0.010 |
| small.en (all 3 sizes) | S3 | 175–488 MB | same as S2 (±1 either way) | few | none | 0.011–0.015 |
| medium.en (all 3 sizes) | S3 | 539–1534 MB | same as S2 (±1 either way) | ~none | none | 0.019–0.023 |

S1 = `-bs 1 -tp 0`. S2 = S1 + `--prompt "Umm, so, I-I was like, hmm... uh, you know, I— I mean."`.
S3 = S2 with `-bs 5`. S1 was run on `base.en` only. S3 was run on `base.en`, `small.en` and `medium.en`.
RTF values are for relative comparison only. On-phone speed is spike 1b.

## 3. Excerpts

| | Opening | Before the pause | Ending |
|---|---|---|---|
| base.en S1 | Oh, let's see. The spawns we went to… | …and the gate agents were [expletive] useless. | I don't. I don't know. |
| small.en-q5_0 S2 | Oh, let's see, um... This month we went to… | …and the—the gate agents were [expletive] useless. | Um... I don't. I don't. I don't know. That's it. |
| large-v3-turbo-q8_0 S2 | Oh, let's see, um... This month we went to… | …and the, the gate agents were [expletive] useless. | Um... I don't... I don't... I don't know. That's it. |

## 4. Surprises and gotchas

- **The prompt is the whole effect.** With no prompt, every "um" and "I-I" was dropped. With the
  prompt, they came back on every model size.
- **`whisper-cli` defaults to beam search (`-bs 5`), not greedy.** Beam search didn't help here.
  On `base.en` it dropped fillers and produced a repetition loop. On `small.en` and `medium.en` it
  made no real difference: same filler count, no loops, and 1–2 small changes per run in both
  directions (e.g. it recovered "I... I" on `small.en` but dropped "the—the" on `medium.en-q8_0`).
  It cost 35–60 % more GPU time, so greedy stays the choice.
- **Quantization is safe for this behavior.** q8_0 output was identical to f16. q5_0 changed only
  punctuation and line breaks.
- **First word after a long pause gets lost.** Only turbo kept the "Um" that opened speech after the
  13 s pause. D6's VAD chunking re-applies the prompt at each chunk start, which may fix this.
  Spike 1b should confirm the prompt is passed with every chunk.
- **No prompt leakage seen.** Both "you know"s in the prompted runs appear to be real speech: turbo
  gives the first its own 2:07–2:08 segment.
- **Most apparent "speech pattern" errors were `base.en` errors.** Larger models agreed on the
  correct words ("This month", "Douro Valley", "Well, I quit").
- **Turbo's timestamps follow the speech closely** (1–5 s segments). The smaller models give
  10–30 s blocks. This matters for tap-to-play later, not for this spike.
- **Browser recording needs DSP off.** Recording was done in the browser with echo cancellation,
  noise suppression and auto gain control all off. The app's `AudioRecord` path (D7) is lossless
  16 kHz, so these results should hold or improve there.
- Non-speech token suppression (`-sns`) is off by default and was not enabled. CrisperWhisper was
  not needed once the prompted `.en` models passed, so it wasn't converted.

## 5. Recommendation for spike 1b

- **Primary:** `ggml-small.en-q5_0.bin` (175 MB), made with `whisper-quantize` from `ggml-small.en.bin`.
  Flags: `-bs 1 -tp 0 --prompt "Umm, so, I-I was like, hmm... uh, you know, I— I mean."`
- **Step up, if phone RAM and speed allow:** `ggml-medium.en-q5_0.bin` (539 MB), same flags.
- **Later:** `ggml-large-v3-turbo-q8_0.bin` as a higher-quality re-transcription engine
  (e.g. desktop or on charger). D2's multiple transcripts per recording already allow this.
- 1b should measure real-time factor and peak RAM on the target phone for both candidates,
  and check that the prompt is applied per VAD chunk.

## 6. Edit to `docs/decisions.md` (applied 2026-09-29)

Replaced the "Engine choice" open question with:

> - **Engine choice** — spike 1a (2026-09-29) passed: Whisper `.en` with a disfluent initial prompt and
>   greedy decoding keeps disfluencies; without the prompt it drops them. Candidates for spike 1b:
>   `small.en-q5_0` (primary, 175 MB), `medium.en-q5_0` (step up). Open: on-phone speed/RAM, and
>   whether per-chunk prompting recovers fillers after long pauses. See `spikes/01a-verbatim-asr-desktop/FINDINGS.md`.
