# Spike 02 — Real-Time Dictation Prototype

**Timebox:** 1–2 days. **Status:** Draft / Ready for Implementation. **Owner:** founder + coding agent.  
**Read first:** `docs/decisions.md` (esp. D1 verbatim, D3 Flutter + native capture, D9 live draft, D10 two-pass), `spikes/01b-asr-on-phone/FINDINGS.md`.

---

## 1. Question

> Can a self-contained on-device Flutter prototype capture live microphone audio, stream live draft transcription chunks via whisper.cpp (`small.en-q5_0`) as natural speech pauses occur, and deliver acceptable perceived lag ($\le 1.5$ s) with verbatim disfluency retention, without audio glitching or UI starvation?

1b proved `small.en-q5_0` achieves RTF ~0.47 on batch files. Spike 02 tests **live interactive reality**: live mic streaming, real-time Silero VAD pause segmentation, background FFI dispatch, and UI rendering while speaking.

---

## 2. Scope

### In
- **In-app audio capture:** Android `AudioRecord` (16 kHz, mono, 16-bit PCM `s16le`) running on dedicated thread (`THREAD_PRIORITY_URGENT_AUDIO`).
- **Disk recording:** Native thread appends raw PCM to a standard `.wav` file in app storage.
- **Streaming Silero VAD:** 32 ms frame evaluation (512 samples) with recurrent state (`h`, `c`) maintained in native C shim.
- **Dynamic chunking:** Pause detection (~500 ms) with pre-speech lookback (300 ms) and post-speech margin (300 ms).
- **Single-pass live inference:** Whisper `small.en-q5_0` via `dart:ffi` in background isolate using `Mode C2` static prompt (`"Umm, so, I-I was like, hmm... uh, you know, I— I mean."`).
- **Single-screen UI:**
  - Large Record / Stop toggle button + duration counter.
  - Live streaming transcript view (chunks appear as speech pauses close).
  - Audio playback bar (scrubber, play/pause) post-recording.
  - Live diagnostics overlay: latency per chunk ($T_{\text{lag}}$), RTF, buffer overrun count.

### Out (Do Not Build)
- No lock-screen widgets, Quick Settings tiles, or external triggers (Spike 03).
- No background WorkManager execution or survival across app process death (Spike 04).
- No concurrent `medium.en` live pass during recording (1b showed RTF 1.45; running 8 threads on 4 big cores causes CPU starvation and audio dropouts). Optional post-stop batch pass only.
- No crash-safe container work (D7) or custom moov repair. Plain WAV header on normal completion.
- No iOS, cloud APIs, database, or sync.

---

## 3. Architecture & Audio Pipeline

```
[Microphone]
     │
     ▼
[Native AudioRecord Thread] (Priority: URGENT_AUDIO)
     ├──► Appends to out.wav on disk
     └──► Pushes 512-sample (32ms) s16le PCM to Native Ring Buffer
               │
               ▼
     [Streaming Silero VAD (C Shim)]
          - Evaluates P(speech) every 32ms frame
          - Tracks speech onset (>0.5 for >=64ms) & pause end (<0.35 for >=500ms)
          - Prepends 300ms pre-speech circular buffer
               │
               ▼ (On pause close or max chunk 25s)
     [Speech Chunk Ready (Float32List)]
               │
               ▼ TransferableTypedData via SendPort
     [Whisper Background Isolate] (4 threads, normal priority)
          - Transcribes chunk using small.en-q5_0 + Mode C2 prompt
          - Emits segment text + master start/end timestamps
               │
               ▼ SendPort
     [Flutter UI Thread]
          - Appends text chunk to live transcript
          - Updates T_lag metric
```

---

## 4. Native C Shim & Streaming VAD Contract

Spike 01b used batch VAD (`dw_vad_segments`). Spike 02 extends `native/shim.c`:

```c
// Whisper inference (existing from 01b)
void*       dw_init(const char* model_path);
int         dw_transcribe(void* ctx, const float* pcm, int n_samples,
                          const char* prompt, int n_threads, int carry_prompt);
int         dw_n_segments(void* ctx);
const char* dw_segment_text(void* ctx, int i);
long        dw_segment_t0(void* ctx, int i);
long        dw_segment_t1(void* ctx, int i);
void        dw_free(void* ctx);

// Streaming Silero VAD (new for 02)
void*       dw_vad_stream_init(const char* vad_model_path);
// Feeds exactly 512 float32 samples (32 ms @ 16 kHz), outputs speech probability [0.0, 1.0]
float       dw_vad_stream_feed(void* vctx, const float* pcm512);
void        dw_vad_stream_reset(void* vctx); // Resets recurrent hidden state (h, c)
void        dw_vad_stream_free(void* vctx);
```

---

## 5. VAD Chunking & Boundary Parameters

To satisfy **D1 (preserve disfluencies)** and prevent word clipping:

| Parameter | Value | Rationale |
|---|---|---|
| **Frame Size** | 512 samples (32 ms) | Native Silero VAD window at 16 kHz. |
| **Speech Onset** | $P \ge 0.5$ for $\ge 64$ ms (2 frames) | Filters transient clicks/taps. |
| **Pre-Speech Buffer** | 300 ms (4,800 samples) | Circular buffer prepended to chunk; captures initial unvoiced plosives & fillers ("um", "uh", "p-"). |
| **Pause Threshold** | $P < 0.35$ for $\ge 500$ ms (16 frames) | Marks natural sentence/clause pause. |
| **Post-Speech Margin** | 300 ms (4,800 samples) | Included at end of chunk to avoid cutting final consonants. |
| **Min Chunk Duration** | 1.5 seconds | Avoids encoder thrashing on micro-sounds (cough, single sigh). Short chunks accumulate until pause $> 1.0$ s. |
| **Max Chunk Duration** | 25.0 seconds | Whisper hard ceiling is 30 s. If continuous speech exceeds 25 s without a pause, cut at lowest probability minimum between 20–25 s (or hard split at 25 s). |

---

## 6. Concurrency, Priority & Memory

- **Capture Thread:** Kotlin dedicated thread with `android.os.Process.setThreadPriority(THREAD_PRIORITY_URGENT_AUDIO)`. Reads from `AudioRecord` in non-blocking loop; zero memory allocations inside read loop.
- **Whisper Worker Isolate:** 4 threads (`n_threads = 4`). CPU affinity / niceness set to background priority so capture and UI threads are never starved.
- **Zero-Copy IPC:** PCM audio transferred from capture handler to Whisper isolate using `TransferableTypedData` to prevent GC pauses on main isolate.
- **Target Memory Envelope:** Peak RSS $\le 800$ MB during active recording (matches 01b benchmark).

---

## 7. UI State Machine & Interaction Lifecycle

```
[Idle] ──(Tap Record)──► [Requesting Permission] ──(Granted)──► [Recording]
  ▲                                                                   │
  │                                                             (Tap Stop)
  │                                                                   ▼
[Review / Playback] ◄──(All Inferences Flushed)───────────── [Stopping (Flush)]
```

1. **Idle:** Record button active. Diagnostic summary visible.
2. **Recording:**
   - Audio waveform / VU meter active.
   - Elapsed timer ticking.
   - Text chunks stream into scrollable view with visual cue (yellow highlight = newly arrived chunk).
3. **Stopping:**
   - Mic closes immediately.
   - WAV header finalized on disk.
   - UI shows "Finalizing..." spinner while background isolate finishes transcribing the final queued chunk.
4. **Review / Playback:**
   - Play/pause audio player enabled (playing recorded `.wav`).
   - Scrubber linked to audio.
   - Full transcript selectable/copyable.

---

## 8. Test Protocol & Pass / Fail Metrics

Tested on physical Google Pixel 9a (or founder target phone).

### Objective Metrics

1. **Perceived Lag ($T_{\text{lag}}$):**
   $$T_{\text{lag}} = T_{\text{ui\_render}} - T_{\text{pause\_detected}}$$
   - **Pass:** Median $T_{\text{lag}} \le 1.5$ s across all chunks.
   - **Fail:** Median $T_{\text{lag}} > 2.5$ s.

2. **Audio Integrity:**
   - **Pass:** Zero buffer underruns (`AudioRecord.ERROR_INVALID_OPERATION`), total recorded audio samples match wall-clock time within $\pm 0.5\%$. No clicks or gaps audible during playback.
   - **Fail:** Audible dropouts or buffer drop counter $> 0$.

3. **Verbatim Disfluency Retention (Phonetic Test Script):**
   Read aloud the following standardized 45-second test script with natural pauses:
   > *"Um, hello. I am testing... uh, testing the new prototype. I— I want to see if it catches my pauses. Hmm... like, you know, when I stop to think, uh, does it keep every single word? That's, um, that's the whole question."*
   - Target fillers: 6 items (`"Um"`, `"uh"`, `"I— I"`, `"Hmm..."`, `"you know"`, `"um"`).
   - **Pass:** $\ge 5 / 6$ ($\ge 83\%$) target fillers retained verbatim in output.
   - **Fail:** $< 4 / 6$ fillers retained (model cleaned up speech).

4. **Thermals & Stability:**
   - Run a 5-minute continuous dictation session.
   - **Pass:** Thermal status remains $\le \text{LIGHT}$ (1), zero crashes or isolate OOMs.

---

## 9. Deliverables

When implementation begins, Spike 02 will produce:
1. `spikes/02-dictation-prototype/app/`: Complete Flutter + Android native project.
2. `spikes/02-dictation-prototype/FINDINGS.md`: Objective measurements ($T_{\text{lag}}$, audio underrun count, filler retention rate, thermal profile) and subjective founder feedback on interactive dictation feel.
