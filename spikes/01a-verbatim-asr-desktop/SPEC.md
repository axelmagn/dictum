# Spike 1a — Verbatim ASR on Desktop

**Timebox:** ½ day. **Status:** done (2026-09-29) — see `FINDINGS.md`. **Owner:** founder + Claude session.
**Read first:** `docs/decisions.md` (esp. D1 verbatim, D5 pluggable engines, D6 async transcription).

## Question

> Does any **locally deployable** speech-to-text model preserve disfluencies —
> filler words ("um", "uh") and repetitions ("I-I", "we—we should") — on
> journaling-style speech?

The answer decides whether Dictum's primary engine is on-device (free, private) or cloud (paid tier).
This spike answers **behavior only**. On-phone speed/RAM is spike 1b.

## Why desktop is a valid proxy

The same quantized whisper.cpp (GGML) model with the same decoding settings produces
effectively the same text on desktop as on a phone. So text behavior can be judged here
in hours, with no mobile toolchain. Test the **deployable form** (quantized GGML via
whisper.cpp), not only the HF/PyTorch checkpoint — quantization can change filler behavior.

## Scope

**In:** a throwaway local web page to record clips and run them through a small matrix of
models × settings; spot-check output by eye and ear (no hand-written reference); write up findings.

**Out (do not build):**
- No eval harness, scoring framework, WER tooling, or engine adapter abstraction.
- No Flutter/Android code. No cloud APIs (they are the fallback, tested later if needed).
- The web tool below is the only code; no framework, build step, auth, or database.

## Tool: local record-and-compare page

One small server (Python stdlib or a single-file `uv run` script) plus one static HTML page.
Bind to `127.0.0.1` only — the browser allows mic access on `localhost` without TLS.

1. **Record** in the browser (`MediaRecorder`), or **upload** an existing file.
   Request the mic with `echoCancellation`, `noiseSuppression` and `autoGainControl` all
   **false**: browser noise suppression can erase quiet fillers before the model sees them,
   which would fake a failure.
2. **Save** the original to `audio/clipN.<ext>` and convert with ffmpeg to `audio/clipN.wav`
   (command under *Test audio*). Saved clips show in a list so they can be re-run.
3. **Run** the clip through the checked cells of the matrix by shelling out to `whisper-cli`
   (one process per model × setting; loads each model fresh, which is fine at this scale).
   Write each raw output to `out/clipN/<model>__<setting>.txt` with its wall time.
4. **Show** results in columns side by side, one per run, with model, setting, RTF, and file size.
   Highlight fillers (um/uh/er/hmm/mm) and immediate word repeats with a regex so they can be
   spotted at a glance. An audio player with the clip sits above the columns.

Each column shows regex hint counts (≈ fillers, ≈ repeats). With no reference, the runs are judged
against each other and against the audio: the highest count across runs of a clip is a floor for
what was actually said, and listening to a few passages tells you what everyone missed. Clicking a segment plays the audio from that point,
and a toggle shows segment timestamps, which is how you spot text invented inside a pause.
`whisper-server` (in whisper.cpp) holds one model at a time, so it doesn't fit the matrix;
shelling to `whisper-cli` is simpler.

## Environment

- Linux, NVIDIA GPU (CUDA), `ffmpeg`, `uv`, `python3`, `git` available.
- Everything lives in this directory. Clone/build artifacts, models, and audio are **gitignored**.

```
spikes/01a-verbatim-asr-desktop/
  SPEC.md        # this file
  FINDINGS.md    # deliverable
  server.py      # throwaway record-and-compare server
  index.html     # its single page
  audio/         # gitignored — test clips
  models/        # gitignored — GGML models
  whisper.cpp/   # gitignored — clone + CUDA build
  out/           # gitignored — raw transcripts per run
```

## Test audio

- Recorded by the founder through the web tool (or uploaded): 2–4 clips, ~1–3 min each, of natural low-stakes speech
  in a journaling register (pauses, trailing off, restarts). **Not real journal content.**
- Must include at least one clip with **long pauses (5–15 s)** to observe hallucination in silence.
- Browser recordings arrive as WebM/Opus, a lossy format. That's close to what a phone
  recorder will produce, so it is acceptable; note the format in FINDINGS.
- The tool converts to the model input format:
  `ffmpeg -i in.m4a -ar 16000 -ac 1 -c:a pcm_s16le audio/clipN.wav`

## Matrix

Models (GGML, whisper.cpp). Prefer `q5_0` and `q8_0` for the models likely to ship:

| # | Model | Notes |
|---|-------|-------|
| M1 | `base.en` | phone-friendly floor |
| M2 | `small.en` | likely phone sweet spot |
| M3 | `medium.en` | upper bound for mid-range phones |
| M4 | `large-v3-turbo` | quality reference; probably too big for phone |
| M5 | CrisperWhisper | Whisper fine-tune trained for verbatim output. HF → GGML conversion via whisper.cpp's `models/convert-h5-to-ggml.py`, then quantize. Verify the current conversion path; if it takes over ~1 h, record it as a finding and move on. |

Settings (apply to each model):

| # | Setting |
|---|---------|
| S1 | greedy (`-bs 1`), temperature 0 |
| S2 | S1 + disfluent initial prompt, e.g. `--prompt "Umm, so, I-I was like, hmm... uh, you know, I— I mean."` |
| S3 | S2 + beam search (`-bs 5`) if S2 looks promising |

Note: `whisper-cli` defaults to beam search with beam size 5, so "defaults" is not greedy.
S1/S2 pass `-bs 1` explicitly. Settings live in `SETTINGS` at the top of `server.py`.

Also note any whisper.cpp flag that suppresses non-speech tokens, and confirm it is **off**.
Check `whisper-cli --help` for current flag names; don't assume.

## What to observe per run

1. **Fillers kept:** ≈ count of um/uh/er/hmm, relative to the best run on the same clip, plus
   anything obvious you hear on spot-check playback that no run caught.
2. **Repetitions kept:** "I-I", "the the", false starts; same relative comparison.
3. **Hallucinations:** invented text, especially inside long pauses, or repeated loops.
4. **Readability:** does the output mangle normal words? (A rough eyeball, not WER.)
5. **Speed on GPU:** real-time factor, for relative comparison only.
6. **Model file size** (a proxy for phone feasibility).

## Pass / fail

- **Pass:** at least one model at `small.en`-class size or smaller (≲ 500 MB quantized) keeps
  **nearly all fillers and repetitions** (≈ as many as the best run, and nothing obvious missing
  on spot-check playback) with no hallucinations the user would notice.
- **Partial:** only M4/M5-sized models pass → on-device is possible but slow; spike 1b
  must measure whether "record now, transcribe later" still works on the target phone.
- **Fail:** nothing keeps disfluencies reliably → cloud is the primary engine;
  next step is a small cloud comparison (Deepgram `filler_words`, AssemblyAI `disfluencies`).

## Deliverable: `FINDINGS.md` (≤ 1 page)

1. **Answer** to the question, in one sentence: pass / partial / fail.
2. **Results table:** model × setting → ≈ fillers, ≈ repetitions, hallucinations, RTF, size.
3. **2–3 short excerpts** showing best vs. worst output on the same passage, with nothing personal.
4. **Surprises and gotchas:** conversion pain, flags, prompt sensitivity, etc.
5. **Recommendation:** candidate engine(s) for spike 1b, with exact model file and flags.
6. **Proposed edits to `docs/decisions.md`**: update the "Engine choice" open question.

## Guardrails

- Test audio is sensitive by nature: keep it gitignored and never upload it anywhere.
  The server listens on `127.0.0.1` only, and the page loads nothing from a CDN.
  No cloud APIs in this spike.
- Stay in the timebox. If a model won't convert or build, record why and move on.
- Throwaway code: optimize for learning, not reuse.
