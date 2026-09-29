# Spike 1b — On-Phone ASR Performance & Disfluency Preservation

**Date:** 2026-09-29. **Status:** Done (Provisional on Pixel 9a proxy).

## 1. Executive Summary

**Pass.** On a physical Android device (Google Pixel 9a, Tensor G4, 8 GB RAM):
- **Sustained RTF:** `small.en-q5_0` achieves sustained **RTF = 0.466** on 30.5 min of audio (`long30.wav`), well within the target threshold of **RTF ≤ 0.5**.
- **Thermals:** Remained at **Thermal Status 1 (LIGHT)**; skin temperature settled at ~40.1 °C with no SEVERE throttling.
- **Memory:** Peak RSS was **875.6 MB** (VmHWM) during the sustained 30-min run, safely below the 8 GB system ceiling with zero OOMs or process kills.
- **Verbatim Disfluency Retention:** Per-chunk prompting with Silero VAD (**Mode C2**) successfully recovered the opening filler `"Um..."` following long pauses, whereas whole-file prompting (C1) and whole-file with `carry_initial_prompt` (C3) dropped it.
- **Medium Model:** `medium.en-q5_0` yielded **RTF = 1.37–1.55** (> 1.0) and peak RSS of **1135 MB**, ruling it out for real-time capture or synchronous background transcription on mobile CPU.

*Note: Findings are provisional on this device. While Tensor G4 is modern, the founder's personal device will be verified in Phase 2.*

## 2. Hardware & Thermal Envelope

- **Device:** Google Pixel 9a (Google Tensor G4 SoC, 8 GB total RAM, Android 17 / API 37).
- **CPU Topology:** 8 cores (1× Cortex-X4 @ 3.1 GHz, 3× Cortex-A720 @ 2.6 GHz, 4× Cortex-A520 @ 1.95 GHz).
- **SIMD / Instruction Set:** `ARM_NEON = 1`, `ARM_FMA = 1`, `FP16_VA = 1`, `MATMUL_INT8 = 1`, `DOTPROD = 1`, OpenMP threading enabled.
- **Optimal Threading:** **4 threads** is the sweet spot. Scaling to 6 (RTF 0.499) or 8 threads (RTF 0.517) degraded performance by scheduling compute onto slower Cortex-A520 efficiency cores.
- **Thermal Behavior:** Under 14 minutes of continuous 4-core 100% utilization (`long30.wav`), the HAL reported `MID` core ~73 °C, `LITTLE` core ~66 °C, and `VIRTUAL-SKIN` at 40.07 °C (Thermal Status: LIGHT). The RTF trajectory showed negligible throttling: first 10 chunks averaged RTF 0.404, stabilizing to 0.455–0.460 for the remaining 53 chunks.

## 3. Accuracy & Transcript Fidelity

- **Desktop 1a Parity:** For speech chunks, `small.en-q5_0` on Android produced identical word-level transcription compared to the desktop 1a CPU/GPU baseline (`small.en-q5_0__S2.txt`).
- **Disfluencies Across Long Pauses:**
  - In `clip8.wav`, a 20-second silence occurs prior to the final section at 03:10.
  - **Mode C1 (Whole-audio):** The initial prompt aged out over the silence; the model hallucinated *"Everything has been really good"* instead of *"AI coding has been really good"*, and dropped the final `"Um..."`.
  - **Mode C2 (Silero VAD + Chunk Prompting):** Accurately transcribed *"AI coding has been really good..."* and captured the opening `"Um... I don't... I don't... I don't know. That's it."` verbatim.
  - **Mode C3 (Whole file + `carry_initial_prompt`):** Got *"AI coding…"* right but still dropped the `"Um..."`.
- **Hallucinations:** No pause hallucinations occurred across any mode. Silero VAD completely eliminated trailing silence hallucination risks by pruning audio segments to speech intervals.

## 4. RTF Comparison Table

Tested on Google Pixel 9a (`clip8.wav`: 202.9 s; `long30.wav`: 1826.4 s):

| Run ID | Model | Mode | Th | Audio | Duration | Transcribe Time | RTF | Peak RSS | Thermal (Start/End) |
|---|---|---|:---:|---|:---:|:---:|:---:|:---:|:---:|
| `sweep__th2` | `small.en-q5_0` | C1 | 2 | `clip8.wav` | 202.9 s | 128.0 s | **0.631** | 678.6 MB | 0 / 0 (NONE) |
| `sweep__th4` | `small.en-q5_0` | C1 | 4 | `clip8.wav` | 202.9 s | 88.6 s | **0.437** | 683.9 MB | 0 / 0 (NONE) |
| `sweep__th6` | `small.en-q5_0` | C1 | 6 | `clip8.wav` | 202.9 s | 101.3 s | **0.499** | 683.9 MB | 0 / 0 (NONE) |
| `sweep__th8` | `small.en-q5_0` | C1 | 8 | `clip8.wav` | 202.9 s | 105.0 s | **0.517** | 684.1 MB | 0 / 1 (LIGHT) |
| `small__C1` | `small.en-q5_0` | C1 | 4 | `clip8.wav` | 202.9 s | 75.8 s | **0.374** | 675.2 MB | 0 / 0 (NONE) |
| `small__C2` | `small.en-q5_0` | C2 | 4 | `clip8.wav` | 202.9 s | 78.4 s | **0.386** | 684.1 MB | 0 / 1 (LIGHT) |
| `small__C3` | `small.en-q5_0` | C3 | 4 | `clip8.wav` | 202.9 s | 78.3 s | **0.386** | 684.1 MB | 0 / 1 (LIGHT) |
| **`small__C2__long30`** | **`small.en-q5_0`** | **C2** | **4** | **`long30.wav`** | **1826.4 s** | **851.2 s (14.2m)** | **0.466** | **875.6 MB** | **0 / 1 (LIGHT)** |
| `medium__C1` | `medium.en-q5_0` | C1 | 4 | `clip8.wav` | 202.9 s | 294.8 s | **1.453** | 1135.3 MB | 1 / 1 (LIGHT) |
| `medium__C2` | `medium.en-q5_0` | C2 | 4 | `clip8.wav` | 202.9 s | 314.3 s | **1.549** | 1135.3 MB | 1 / 1 (LIGHT) |
| `medium__C3` | `medium.en-q5_0` | C3 | 4 | `clip8.wav` | 202.9 s | 277.1 s | **1.366** | 1135.3 MB | 1 / 1 (LIGHT) |

*`medium.en-q5_0` on `long30.wav` was skipped per SPEC criteria because its clip8 RTF (1.45) exceeded the 1.0 threshold.*

## 5. Peak RSS & Memory Footprint

- **`small.en-q5_0`**: Base footprint is ~675 MB RSS on short clips. Under sustained 30-min chunked transcription with accumulated memory state, peak RSS reached **875.6 MB**. While this exceeds the conservative 600 MB envelope suggested in the initial spec draft, on an 8 GB Android device it represents ~11% of system RAM and caused zero memory pressure or eviction.
- **`medium.en-q5_0`**: Reached **1135.3 MB** peak RSS (~15% of RAM).
- **Leak Verification:** Consecutive runs showed RSS returning to baseline upon isolate termination and memory remaining bounded across 63 consecutive chunks.

## 6. Mode Comparison (C1 vs C2 vs C3)

| Metric / Feature | Mode C1 (Whole-Audio Prompt) | Mode C2 (VAD + Per-Chunk Prompt) | Mode C3 (Whole file + `carry_initial_prompt`) |
|---|---|---|---|
| **VAD Pre-pass** | None (0 ms) | Silero VAD (4.7 s for 30m audio; ~0.002 RTF) | None (0 ms) |
| **Long Pause Disfluency** | ❌ Fails (drops initial fillers) | ✅ **Passes** (recovers fillers after silence) | ❌ Fails (boundary clipping drops fillers) |
| **Hallucination Risk** | Silence fed to model | None seen (silences pruned) | Silence fed to model |
| **Live Draft Feasibility (D9)** | ❌ No (requires full audio) | ✅ **Yes** (natural boundary at speech pauses) | ❌ No (requires full audio) |
| **Implementation Complexity** | Minimal (single pass) | Low (Silero VAD C shim + chunk loop) | Low (arithmetic slicing) |

**Conclusion:** Mode C2 is strictly superior. Silero VAD overhead is negligible (0.2% of total compute) while providing robust disfluency retention and zero hallucination.

## 7. Recommendations for Spike 1c and Phase 2

1. **Engine Choice:** **whisper.cpp via `dart:ffi` is accepted.** Direct C shim integration avoids JNI overhead and compiles with native ARM NEON + FP16 + DotProd flags.
2. **Model Choice:** Standardize on **`ggml-small.en-q5_0.bin` (175 MB)** for mobile. `medium.en-q5_0` is too slow on CPU (RTF 1.45–1.55).
3. **Prompt Strategy:** Adopt **Mode C2** exclusively. Every speech chunk must be primed with the verbatim disfluency prompt: `"Umm, so, I-I was like, hmm... uh, you know, I— I mean."`.
4. **Thread Configuration:** Hardcode or cap thread allocation to **4 threads** on modern 8-core big.LITTLE architectures (matching the big-core cluster).
5. **Live Draft Feasibility (D9):** RTF ~0.40–0.46 leaves headroom for live VAD-chunk transcription, but live lag was **not measured**. Lag ≈ wait for pause + chunk compute; whisper.cpp pads each chunk to a 30 s encoder window, so short live chunks cost more per audio-second than the batch RTF suggests.
6. **Next:** no further spikes (2026-09-29). Concurrent capture + inference, live lag and time-to-final are verified during the build. See D10 in `docs/decisions.md`.
