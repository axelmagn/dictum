# Spike 02 — Real-Time Dictation Prototype Findings

**Date:** 2026-09-29. **Status:** Completed. **Target Device:** Google Pixel 9a (Tensor G4, 8 GB RAM, Android 17 / API 37).  
**Prior Spike:** `spikes/01b-asr-on-phone/FINDINGS.md`.

---

> **2026-09-29 revision: lag FAIL overturned. See §5.** The "fixed 30 s encoder floor" in §3 was wrong: the shim never set `whisper_full_params.audio_ctx`. With the encoder window sized to the chunk, backlog coalescing and live partials: median T_lag **1.30 s** (phonetic), **1.12 s** (5-min), first partial text **~1.2 s** after speech onset, fillers 5/6. New issue: peak RSS 1007 MB on the 5-min run (> 800 MB).

## 1. Executive Summary & Verdict

| Metric | Target (SPEC.md) | Measured Result | Verdict |
|---|---|---|:---:|
| **Perceived Lag ($T_{\text{lag}}$)** | Median $\le 1.5$ s across all chunks | **Median $T_{\text{lag}} = 13.33$ s** (Min: 5.11 s, Max: 22.35 s) | ❌ **FAIL** |
| **Audio Integrity** | Zero underruns, clock match $\pm 0.5\%$ | **0 overruns**, clock discrepancy **0.0012%** | ✅ **PASS** |
| **Verbatim Disfluency Retention** | $\ge 5 / 6$ (83%) target fillers retained | **5 / 6 (83.3%)** retained verbatim | ✅ **PASS** |
| **Memory Footprint** | Peak RSS $\le 800$ MB during active capture | **549.4 MB** (Phonetic) / **737.0 MB** (Long) | ✅ **PASS** |
| **Thermals & Stability** | Thermal Status $\le \text{LIGHT}$ (1), 0 crashes | **Status 0 (NONE)**, zero crashes or OOMs | ✅ **PASS** |

**Conclusion:** **Fail on live CPU latency budget; Pass on audio capture, disfluency retention, memory, and thermals.**  
While Spike 1b demonstrated that `small.en-q5_0` achieves sustained $RTF = 0.466$ on large batch files, Spike 02 reveals the **interactive reality**: whisper.cpp's fixed 30-second transformer audio encoder introduces an inescapable compute floor of $\sim 4.5$–$5.0$ seconds on mobile CPU. When natural speech produces chunks every 1.5–3.0 seconds, the worker isolate operates at effective $RTF > 2.0$, generating an unavoidable backlog queue where perceived lag grows linearly.

---

## 2. Objective Measurements

### 2.1 Standardized Phonetic Test Script (45-second natural pause cadence)

Read aloud or streamed at 32 ms real-time cadence through native Silero VAD into whisper.cpp worker isolate:

```
Script: "Um, hello. I am testing... uh, testing the new prototype. I— I want to see if it catches my pauses.
         Hmm... like, you know, when I stop to think, uh, does it keep every single word? That's, um, that's the whole question."
```

#### Chunk-by-Chunk Breakdown (Google Pixel 9a, Tensor G4, 4 threads):

| Chunk # | Audio Interval | Chunk Duration | Inference Time | Chunk RTF | $T_{\text{lag}}$ | Verbatim Transcript Chunk |
|:---:|:---:|:---:|:---:|:---:|:---:|---|
| 0 | 00:00 – 00:01.6 | 1.60 s | 5.11 s | **3.19** | **5.11 s** | `Um, hello.` |
| 1 | 00:01.9 – 00:03.5 | 1.60 s | 5.36 s | **3.35** | **8.52 s** | `I am testing.` |
| 2 | 00:03.7 – 00:06.6 | 2.91 s | 5.64 s | **1.94** | **11.05 s** | `Uh, testing the new prototype.` |
| 3 | 00:07.0 – 00:11.3 | 4.22 s | 5.85 s | **1.39** | **12.26 s** | `I— I want to see if it catches my pauses.` |
| 4 | 00:11.8 – 00:14.9 | 3.10 s | 5.78 s | **1.86** | **14.40 s** | `Um, like, you know.` |
| 5 | 00:15.1 – 00:17.0 | 1.86 s | 5.81 s | **3.13** | **18.16 s** | `When I stop to think.` |
| 6 | 00:17.2 – 00:20.4 | 3.26 s | 5.87 s | **1.80** | **20.57 s** | `Uh, does it keep every single word?` |
| 7 | 00:21.0 – 00:24.6 | 3.65 s | 5.93 s | **1.63** | **22.35 s** | `That's, um, that's the whole question.` |

- **Median $T_{\text{lag}}$:** **13.33 s** (Threshold: $\le 1.5$ s).
- **Average RTF:** **2.042** (Effective throughput during live chunking).
- **Full Transcript Assembled:**
  > *"Um, hello. I am testing. Uh, testing the new prototype. I— I want to see if it catches my pauses. Um, like, you know. When I stop to think. Uh, does it keep every single word? That's, um, that's the whole question."*

### 2.2 Verbatim Disfluency Retention Analysis

| Target Filler | Occurrence in Test Script | Retained Verbatim? | Output Text Evidence |
|---|---|:---:|---|
| **`"Um"` (initial)** | Opening utterance | ✅ **YES** | `"Um, hello."` |
| **`"uh"`** | Middle of sentence | ✅ **YES** | `"Uh, testing the new prototype."` |
| **`"I— I"`** | False start / stutter | ✅ **YES** | `"I— I want to see if it catches my pauses."` |
| **`"Hmm..."`** | Standalone filler sigh | ❌ **NO** | Filtered by onset gate / merged into adjacent pause |
| **`"you know"`** | Conversational filler | ✅ **YES** | `"Um, like, you know."` |
| **`"um"` (final)** | Final clause filler | ✅ **YES** | `"That's, um, that's the whole question."` |

**Retention Rate:** **5 / 6 = 83.3%** ($\ge 83\%$ threshold passed). Mode C2 static priming prompt (`"Umm, so, I-I was like, hmm... uh, you know, I— I mean."`) successfully prevented Whisper from sterilizing conversational pauses, plosives, and stutter repetitions.

### 2.3 Audio Capture & Subsystem Integrity

- **HAL Buffer Underruns / Overruns:** **0**. The non-blocking Kotlin capture loop (`android.os.Process.THREAD_PRIORITY_URGENT_AUDIO`) executing a zero-allocation read cycle showed zero buffer drops across all runs.
- **Audio Clock Match:**
  - Wall-clock elapsed: 24,608 ms.
  - Recorded PCM samples: 393,728 samples @ 16 kHz = 24,608.0 ms.
  - Clock discrepancy: **0.0012%** (Passing requirement $\le 0.5\%$).
- **WAV Finalization:** Immediate 44-byte RIFF header rewrite upon record stop. Playback via Android `MediaPlayer` verified clean, click-free audio.

### 2.4 Thermals & Memory Envelope

- **Memory:** Peak RSS stabilized at **549.4 MB** on short sessions and **737.0 MB** on extended 5-minute sessions. Both comfortably beat the $\le 800$ MB target envelope. Zero memory growth across consecutive recordings.
- **Thermals:** Under continuous recording and background inference, Android HAL reported `Thermal Status: 0 (NONE)`. Little cores stayed at $\sim 68$ °C, big cores at $\sim 70$ °C, and virtual skin at $36.9$ °C. No thermal throttling occurred.

---

## 3. Deep Dive: Why Whisper CPU Fails the Interactive $\le 1.5$ s Lag Budget

> **Superseded (§5).** The padding cost here is real only while `audio_ctx` = 1500 (the default). whisper.cpp can shrink the encoder window (`audio_ctx`, the `-ac` flag in `examples/stream`). The ~5 s floor was a config default, not a model limit. §4 path recommendations based on it are withdrawn.

### The 30-Second Attention Window Bottleneck

1. **Fixed Positional Embeddings:** OpenAI Whisper's audio encoder uses fixed positional embeddings of length 1500, corresponding to 3000 frames of 80-channel log-mel filterbanks ($30.0$ seconds of audio).
2. **Padding Overhead:** When an audio chunk is smaller than 30 seconds (e.g., a natural speech chunk of 1.6 seconds), whisper.cpp pads the remaining $28.4$ seconds with silence. The encoder transformer must still compute self-attention over the full sequence.
3. **Execution Floor:** On Google Tensor G4 (1× Cortex-X4 @ 3.1 GHz + 3× Cortex-A720 @ 2.6 GHz), a single encoder forward pass requires:
   $$\text{Encoder Compute Time} \approx 4.6\text{ to }5.2\text{ s}$$
4. **Queue Congestion ($RTF > 1.0$):**
   - In batch transcription (Spike 1b), 30 seconds of audio is processed in ~14 seconds ($RTF \approx 0.47 < 1.0$).
   - In live dictation, speech chunks arrive every 1.5 to 3.0 seconds. Processing a 2.0-second chunk in 5.0 seconds yields an effective **$RTF = 2.50$**.
   - As a result, each subsequent chunk is delayed by the accumulated processing time of all preceding chunks:
     $$T_{\text{lag}}(n) = T_{\text{lag}}(0) + \sum_{i=1}^n (T_{\text{infer}}(i) - \Delta T_{\text{arrival}}(i))$$
   - $T_{\text{lag}}$ compounded from $5.11$ s on Chunk 0 to $22.35$ s on Chunk 7.

---

## 4. Architectural Lessons & Recommendations for Phase 2

1. **Keep Audio Capture & VAD Architecture:**  
   The Kotlin `AudioRecord` thread running at `THREAD_PRIORITY_URGENT_AUDIO` with zero memory allocation, streaming Silero VAD evaluation (32 ms window) via `dart:ffi`, and zero-copy IPC via `TransferableTypedData` is fast, reliable, and verified.
2. **Whisper CPU Cannot Deliver Real-Time Live Drafts ($\le 1.5$ s):**  
   Mobile CPU execution of `whisper.cpp` (`small.en-q5_0`) is fundamentally unsuitable for synchronous, per-pause live draft streaming on mobile devices due to the fixed 30-second encoder constraint.
3. **Paths to Achieve $\le 1.5$ s Perceived Lag:**
   - **Path A: Streaming Conformer / RNN-T for Live Draft (Recommended for Phase 2):**  
     Use an on-device streaming acoustic model with causal convolution / chunked attention (e.g., Sherpa-ONNX / Zipformer or Whisper-streaming with NPU acceleration) for the live visual draft ($T_{\text{lag}} < 300$ ms, $RTF < 0.1$).
   - **Path B: Mobile GPU / NPU Acceleration (Vulkan / NNAPI):**  
     Accelerating Whisper encoder via Vulkan or Qualcomm/Tensor NPU can reduce the 30 s encoder time from 5.0 s to $< 0.8$ s, bringing the short-chunk execution floor under 1.0 s.
   - **Path C: D10 Two-Pass Architecture:**  
     Per Decision D10 (`docs/decisions.md`): Render a lightweight draft in real-time, then run the full high-accuracy verbatim pass (`small.en-q5_0` or `medium.en-q5_0`) upon pause or session stop.

---

## 5. Re-test: dynamic `audio_ctx` + coalescing + live partials (2026-09-29, Pixel 9a)

**Changes:**
- `native/shim.c`: `dw_transcribe(..., audio_ctx)`.
- `whisper_worker.dart`: `audio_ctx = clamp(ceil(dur·50)+32, minCtx, 1500)`. Queued finals merged (≤25 s) and prioritized. Partials latest-wins, dropped when a final is waiting.
- `main.dart`: re-transcribes the in-progress utterance every 1 s (first one at 0.5 s) and shows it as a grey draft, replaced by the final on pause. Stop waits for the backlog instead of a fixed 3 s timeout. App bar ctx selector. Report gains `minAudioCtx`, `audioCtx`, `lastIndex`, `medianFirstPartialSec`.

**Phonetic script sweep (single run each, replayed at real-time cadence):**

| min ctx | median T_lag | max T_lag | RTF | 1st partial | fillers | notable errors |
|---|---|---|---|---|---|---|
| 128 | **1.30 s** ✅ | 3.20 s | 0.24 | 1.20 s | 5/6 | "Hmm" dropped (as before) |
| 256 | 1.36 s ✅ | 1.49 s | 0.32 | 1.59 s | 5/6 | "hello"→"the low", "Hmm"→"Ferm" |
| 384 | 2.06 s ❌ | 2.59 s | 0.46 | 2.30 s | 4/6 | "I— I"→"I, I", lost "that's, um," |
| full 1500 | 9.10 s ❌ | 10.15 s | 1.25 | 1.38 s* | 5/6 | backlog merged 2 chunks/call; lag bounded, not growing |

\*The first partial at full ctx landed before the backlog formed.

**5-min continuous (`long30.wav`, ctx≥128):** median T_lag 1.12 s, max 4.18 s, per-quartile medians 1.45/0.97/1.07/1.16 s (no drift), RTF 0.26, 54 partial utterances, thermal 0, 0 overruns. **Peak RSS 1007 MB ❌** (was 737 MB). Suspects: compute-buffer realloc as `audio_ctx` varies per call, and partial snapshot copies. Not investigated.

**Caveats:**
- n=1 per setting. Accuracy differences between 128/256/384 are within run-to-run noise. Repeat runs are needed before picking a ctx.
- Replayed audio, not live mic. A live-mic check of the draft feel is still needed.
- Smaller ctx = a less-validated Whisper regime. The final (verbatim) pass after stop at full ctx (D10) remains advisable.

**Next:** repeat the sweep ×3; investigate RSS; live-mic founder test; consider a D10 post-stop full-ctx pass for the stored verbatim transcript.

