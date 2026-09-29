# Dictum — Decision Log

Lightweight record of product and architecture decisions. Append new entries; supersede rather than rewrite.

## Context

Dictum is a dead-simple voice journal: speak, and it records your words **verbatim**. The only organizing structure is a timeline.

The first user is a specific person who uses dictation for **therapeutic journaling** on **Android**, in **English**. They have tried and rejected existing tools (Voice Memos, Google Recorder, Otter, etc.) because those tools clean up speech. Secondary audience: people on iOS.

Guiding principles, in priority order:

1. **Never lose an entry.**
2. **Never leak an entry.**
3. **Never clean up their words.**
4. Capture is instant; retrieval is effortless.

---

## D1 — "Verbatim" means disfluencies are preserved
**Status:** accepted (2026-09-29)

Filler words ("um", "uh") and repetitions/false starts ("I-I", "we—we should") are kept exactly as spoken. Scoring must measure disfluency retention separately from WER, since standard normalizers strip fillers.

## D2 — Audio is the source of truth; transcripts are derived
**Status:** accepted (2026-09-29)

Every entry stores its audio. A recording may have many transcripts, each stamped with engine id + version; one is marked active. Enables re-transcription as engines improve, playback verification, and no data loss on transcription failure.

## D3 — Flutter for the app; native code owns capture
**Status:** accepted (2026-09-29)

Flutter for UI and app logic, for iOS reach (secondary audience is on iOS; cross-ecosystem portability matters). Native code (Kotlin on Android, Swift on iOS later) owns:

- audio capture (recorder / foreground service) — the mic goes hot without waiting for the Flutter engine
- OS entry points (Quick Settings tile, widgets; later App Intents / Controls / Live Activities)

Each native capability sits behind a Dart platform interface so the iOS implementation slots in later.

Accepted cost: ~100–300 ms extra cold start to the timeline UI, two languages plus a channel boundary, headless-engine background work.

## D4 — Android first
**Status:** accepted (2026-09-29)

The first user is on Android. iOS follows; requires a Mac / cloud Mac CI.

## D5 — Pluggable transcription engines
**Status:** accepted (2026-09-29)

Transcription is behind an interface covering lifecycle as well as inference: engine info (id, version, privacy class on-device|cloud), status (ready / needs download / needs auth / unsupported), prepare (download, warm-up), and transcribe (audio → stream of timestamped segments). Prefer engines that run on both platforms (e.g. whisper.cpp); platform-only engines are optional plugins.

## D6 — Transcription is asynchronous background work
**Status:** accepted (2026-09-29); amended by D10 (2026-09-29): the final pass starts during recording, not after

Record now, transcribe after. Jobs are persisted and chunked (VAD-split at pauses) so they resume after process death and never feed long silences to the model (Whisper hallucination risk). Android: WorkManager + headless Flutter engine. See D9 for the live draft shown during recording; this job still produces the canonical transcript.

## D7 — Crash-safe recording format
**Status:** accepted in principle; exact container decided during build (no spike planned) (2026-09-29)

No `MediaRecorder` → MP4/M4A (unplayable if the process dies before the moov atom is written). Use `AudioRecord`, 16 kHz mono, written incrementally in a truncation-tolerant format (chunked WAV or Ogg/Opus).

## D8 — Local-first business model
**Status:** accepted (2026-09-29)

Local features are free. Paid tier covers online features: cloud inference and cross-device/cross-platform sync (own backend, ideally E2E encrypted). Cloud transcription requires explicit, informed consent — audio leaving the device is never a buried setting. Free export/import in a documented open format (audio + JSON transcripts).

## D9 — Live draft transcript while recording
**Status:** accepted (2026-09-29); amended by D10: the draft uses a smaller model than the final pass

While the user records, the transcript streams into the UI and updates in near real time. The live text is a **draft**. When recording stops, D6's background job still produces the canonical transcript (D2), which replaces the draft. The live path adds to D6; it doesn't replace it.

- Same engine family and prompt as the final pass (Whisper + disfluent prompt), transcribing VAD chunks as each pause closes. Expect a lag of a few seconds, not word-by-word output.
- The draft must not clean up speech either (principle 3). A filler-dropping preview engine such as the OS recognizer is not acceptable, even as a draft.
- Capture wins. Live transcription must never put the recording at risk (principle 1). If it can't keep up because of thermal limits, battery or RAM, it pauses or drops back to "transcribe after".
- v1 can ship without it if on-device speed isn't enough.

## D10 — Two-pass transcription: live preview, then final
**Status:** accepted (2026-09-29)

Both passes use whisper.cpp via `dart:ffi`, the same Silero VAD chunks, and the disfluent prompt on every chunk (spike 1b mode C2), with greedy decoding, temperature 0 and 4 threads.

- **Preview:** `small.en-q5_0` (175 MB, RTF ~0.47 on Pixel 9a). Transcribes each VAD chunk as its pause closes. Shown highlighted (yellow) as provisional.
- **Final:** `medium.en-q5_0` (539 MB, RTF ~1.45). Starts during recording at low priority, using CPU time the preview leaves idle. It continues after stop as D6's background job. Each finished chunk replaces the matching preview chunk in place, live. Shared chunk boundaries make every swap atomic: one chunk at a time, no word-level diffing.
- **Priority:** capture > preview > final. The final pass can't keep up live (RTF > 1), so it finishes after stop. Rough estimate on Pixel 9a (unmeasured): ~4 min after stop for a 4-min entry, ~9 min after stop for a 10-min entry.
- **Storage:** preview and final are separate transcripts (D2). The final becomes active when complete.
- **Why medium:** both models fit in RAM (~1.8 GB RSS combined), but only small is fast enough to run live. In 1a, medium matched small on disfluencies and had fewer word errors. That's one clip, so re-check the quality gain on more entries.
- **Fallbacks:** if the device can't sustain both passes (heat, battery, RAM), the final pass waits for the charger or idle time, and the preview stays active until then. If the preview can't keep up, D9's rules apply.
- **Watch:** log whenever the final drops a disfluency the preview kept (principle 3). The overwrite UX is accepted as is; revisit if the user finds it jarring.
- Run inference in a separate process from capture, so an OOM kill during inference can't take the recording down with it.

---

## Open questions

- **Engine choice** — resolved by D10 (small preview + medium final). Provisional until re-verified on the user's phone. Evidence: `spikes/01a-verbatim-asr-desktop/FINDINGS.md`, `spikes/01b-asr-on-phone/FINDINGS.md`.
- **Target device** — user's phone model and RAM are still unknown. Validated only on a proxy (Pixel 9a, Tensor G4, 8 GB: small RTF 0.466 sustained, RSS 875 MB, thermal LIGHT; medium RTF 1.45, RSS 1135 MB). Re-run 1b's `run-on-device.sh` on the user's phone. If small's RTF is above ~0.7 there, drop live preview to "transcribe after". If medium can't finish within ~2× the entry length, run the final pass on charger only.
- **Unmeasured, verify during build** (no more spikes planned): live lag per chunk (whisper.cpp pads chunks to 30 s, so short chunks cost more than the batch RTF suggests), concurrent capture + both passes, time-to-final after stop, heat and battery for a 10-min entry.
- **Typical entry length** — 1–10 min, median ~4 min (2026-09-29). Longer entries must still record and transcribe safely, just more slowly.
- **At-rest protection** — encryption, optional biometric lock.
- **Sync design** — deferred to paid tier.
