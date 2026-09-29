# Spike 1b — Verbatim ASR on the Phone

**Timebox:** 1 day, including ≤ 2 h of toolchain setup. **Status:** done (see FINDINGS.md). **Owner:** founder + coding agent.
**Read first:** `docs/decisions.md` (esp. D3 Flutter + native, D5 pluggable engines, D6 async chunked
transcription), then `spikes/01a-verbatim-asr-desktop/FINDINGS.md`.

## Question

> Is the engine chosen by spike 1a (whisper.cpp `small.en-q5_0`, greedy, disfluent prompt) **fast
> enough and small enough in RAM** on the target Android phone, when called from a Flutter app,
> and does **per-chunk prompting** keep disfluencies across long pauses?

The answer decides whether on-device transcription is the default engine, a charger-only/overnight
engine, or whether cloud (or a smaller model) is needed.

1a answered text *behavior* on desktop. This spike answers *speed, memory, heat, and integration*
on the phone. It also checks that the phone build writes the same text as the desktop build.

## Scope

**In:** a throwaway Flutter app (Android only, arm64 only) that loads a GGML model and a WAV file
from app storage, transcribes it with whisper.cpp via `dart:ffi`, and records timings, memory,
thermal status and battery. Runs are started by hand from a single screen.

**Out (do not build):**
- No recording, no mic, no capture service (spikes 02/03). Audio comes from 1a's clips.
- No WorkManager or background execution (spike 04). Runs happen in the foreground with the screen on.
- No engine interface/abstraction layer, no database, no persistence beyond result files.
- No iOS. No cloud APIs. No GPU backends (Vulkan/OpenCL), unless CPU fails (see *Pass / fail*).
- No UI polish: one screen with dropdowns, a Run button, a live log, and the last transcript.

## Environment and setup

Host: Linux (CachyOS/Arch), `fvm` 4.3.1, `cmake`, `ffmpeg`, `uv`. **Toolchain is installed and
verified (2026-09-29):** a release APK of the default template builds.

- Android Studio 2026.1.4 (AUR) at `/opt/android-studio`. Its bundled JDK is **25**, which is fine
  because the 3.47.1 template uses Gradle 9.3.1 + AGP 9.1.0. Don't install another JDK or change Gradle.
- SDK at `~/Android/Sdk` (user-owned), with `platform-tools` (`adb`) and `cmdline-tools/latest`.
  NDK **r28c** (`28.2.13676358`) and platform 36 were installed by Gradle on the first build.
  Gradle installs any other SDK packages (e.g. `cmake`) on demand.
- Flutter is pinned by `.fvmrc` in this directory. Always run `fvm flutter …`, never a bare `flutter`.
- Known noise: `flutter doctor` reports "Android license status unknown". This is cosmetic.
  `sdkmanager` was replaced by the new `android` CLI and Flutter can't parse its output, but the license
  file exists and Gradle accepts it. `--android-licenses` is a no-op. Chrome warnings don't matter.

Installing system packages needs `sudo`, so **ask the founder to run those commands** (suggest
`! <cmd>`). Don't work around a missing tool.

**Phone:** developer options + USB debugging on, `adb devices` shows it. If it shows `no permissions`,
ask the founder to install udev rules (`sudo pacman -S android-udev`) and replug.

**Test phone (connected 2026-09-29):** Google Pixel 9a, Tensor G4 (1× X4 3.1 GHz + 3× A720 2.6 GHz
+ 4× A520 1.95 GHz), 8 GB RAM, Android 17 / API 37, arm64. `/proc/cpuinfo` features include `asimddp`
(dotprod), `fphp` (fp16), `i8mm`, `sve2`. `/sdcard/Android/data` is accessible via adb.
This is a **proxy**, not the first user's phone. It's the only device available now. The spike will be
re-run later on the user's phone (see *Re-running on another phone*).
Expect the thread sweep to peak around 4 (the fast cores). Tensor chips throttle under sustained
load, so the long30 run is the one that decides the result.

If any remaining setup is over 2 h, stop and write down what blocked it. That is a finding too.

## Layout

```
spikes/01b-asr-on-phone/
  SPEC.md  FINDINGS.md  .fvmrc  .gitignore
  app/                    # fvm flutter create --platforms=android --org dev.dictum.spike app
    lib/main.dart         # the one screen + run loop
    lib/whisper_ffi.dart  # dart:ffi bindings to the shim
    native/shim.c         # flat C API over whisper.cpp (below)
    native/CMakeLists.txt # builds whisper.cpp + shim into libdictum_whisper.so
    android/…             # Gradle externalNativeBuild → native/CMakeLists.txt; small Kotlin MethodChannel
  whisper.cpp/            # gitignored — clone at the SAME commit as 1a (below)
  models/  audio/  out/   # gitignored
```

## Native build

- Clone whisper.cpp into `whisper.cpp/` and check out **`6e4ab854f67f743900934a703d5603419384c961`**,
  1a's commit, so text differences can't come from a version change.
- Build with CMake through Gradle's `externalNativeBuild` (`add_subdirectory` on whisper.cpp, plus
  the shim). Use `abiFilters "arm64-v8a"` only. `examples/whisper.android` in the clone is a useful
  reference for flags, but don't copy its structure.
- **Force Release for the native code in every build** (`-DCMAKE_BUILD_TYPE=Release` via Gradle
  `cmake.arguments`), and time only `fvm flutter run --release` / `build apk --release` builds.
  An unoptimized ggml runs many times slower, which would fake a fail.
- On startup, log `whisper_print_system_info()` and check that NEON, FMA, FP16 and DOTPROD (and MATMUL_INT8, since the Tensor G4 has i8mm) are enabled.
  If they aren't, set the ARM arch flags in ggml's CMake. Look up the option names in
  `whisper.cpp/ggml/CMakeLists.txt` at the pinned commit, and don't assume them.

**Shim, not struct mirroring.** `whisper_full_params` is large and changes between versions.
Don't mirror it in Dart. Write a small C shim that takes only primitives and sets params in C, e.g.

```c
void* dw_init(const char* model_path);                 // whisper_init_from_file_with_params, no GPU
int   dw_transcribe(void* ctx, const float* pcm, int n_samples, const char* prompt,
                    int n_threads, int carry_prompt);  // greedy, temperature 0, no_context=1, print_*=0
int   dw_n_segments(void* ctx);  const char* dw_segment_text(void* ctx, int i);
long  dw_segment_t0(void* ctx, int i);  long dw_segment_t1(void* ctx, int i);   // centiseconds
void* dw_vad_init(const char* vad_model_path);
int   dw_vad_segments(void* vctx, const float* pcm, int n, float* out_t0t1, int max_segments);
const char* dw_system_info(void);  void dw_free(void* ctx);  void dw_vad_free(void* vctx);
```

Settings must match 1a's S2: `WHISPER_SAMPLING_GREEDY`, temperature 0, **no temperature fallback**
(`temperature_inc = 0`, the same as 1a's `-tp 0`), `suppress_nst = false`, language `en`, and the prompt
`"Umm, so, I-I was like, hmm... uh, you know, I— I mean."`. Leave any param 1a didn't set at its
default. Read `whisper.h` and don't guess.

Call `dw_transcribe` from a background isolate (`Isolate.run`) so the UI and the stats sampler keep running.

## Test assets (pushed with `adb`, never bundled in the APK)

- **Models:** `ggml-small.en-q5_0.bin` (primary) and `ggml-medium.en-q5_0.bin` (step up). Hardlink or
  copy them from `../01a-verbatim-asr-desktop/models/`. VAD model: `whisper.cpp/models/download-vad-model.sh`
  (Silero; use the version the script offers by default).
- **Audio:** `../01a-verbatim-asr-desktop/audio/clip8.wav` (3:23, 16 kHz mono s16le, one ~13 s pause).
  1a's reference transcripts for this clip are in `../01a-verbatim-asr-desktop/out/clip8/`.
- **Long file** for sustained load and heat: about 30 min of clip8 on a loop.
  `ffmpeg -stream_loop 8 -i ../01a-verbatim-asr-desktop/audio/clip8.wav -c copy audio/long30.wav` (9 × 3:23 ≈ 30.5 min)
- Push to the app's external files dir, e.g. `/sdcard/Android/data/dev.dictum.spike.app/files/{models,audio}/`.
  If the device refuses `adb push` there, add an "Import file" button (file picker → copy into app storage).
  Don't make the app debuggable just to use `run-as`.
- The app reads WAV itself: parse the header, **assert** 16 kHz / mono / s16le, and convert to `Float32List`.

## Modes

| # | Mode | What it tests |
|---|------|---------------|
| C1 | Whole file, one `dw_transcribe` call, prompt once | Parity with 1a S2 desktop output |
| C2 | App-level VAD chunks: merge adjacent VAD segments into chunks ≤ 30 s, split only at silences; one `dw_transcribe` per chunk, **prompt on every chunk**, `no_context`; offset timestamps by chunk start | D6's intended design; does the "Um" after the 13 s pause come back? |
| C3 | Whole file, `carry_initial_prompt = 1` | Does whisper.cpp's built-in option give C2's benefit without app chunking? |

Also sweep **threads** once, on `small.en-q5_0` × C1 × clip8, with 2 / 4 / 6 / 8 (or up to the
core count), and use the fastest for all other runs. Big.LITTLE phones often peak at the big-core count.

## Run matrix

| Model | clip8 × C1/C2/C3 | long30 × C2 |
|-------|------------------|-------------|
| small.en-q5_0 | yes | yes: the key number |
| medium.en-q5_0 | yes | yes, if clip8 RTF ≤ 1.0 |

Kill and relaunch the app between models so memory figures aren't polluted.

## Re-running on another phone

The same build will run later on the first user's phone, probably in one short session with the
founder's help. That session has to be cheap and hard to get wrong:

- **`run-on-device.sh`** (at the spike root) does the whole thing for whatever device `adb` sees:
  install the release APK, push the models, VAD model and audio, print what to tap, then pull
  `out/` into `out/<device-model>/`. Nothing in it is hard-coded to the Pixel.
- **A "Run all" button** runs the whole matrix in order, with no choices on screen. It relaunches
  between models (or writes a marker and asks to be relaunched). Keep the per-run dropdowns for development.
- Every result file includes the device block, so results from different phones can go in one table.
- The APK needs no setup beyond install. If the user's phone can't take `adb push` into
  `Android/data`, the "Import file" fallback (above) is the way in. Build it only if the Pixel also needs it,
  and otherwise note it as a possible gap.
- The founder's test audio on the user's phone is fine (it's the founder's own voice), but it's
  deleted with the app afterwards. `run-on-device.sh` ends by printing the uninstall command.

## What each run records

Write `out/<run-id>.json` plus `out/<run-id>.txt` (segments with timestamps) to the app's external
files dir, then fetch them with `adb pull` into this spike's `out/`.

- Device (once, via a Kotlin MethodChannel): `Build.MANUFACTURER/MODEL`, `Build.SOC_MODEL` (API 31+),
  total RAM (`ActivityManager.MemoryInfo.totalMem`), Android version, CPU core count, `dw_system_info()`.
- Model, mode, threads, audio duration, model load time, VAD time, transcribe wall time, **RTF**.
- **Peak memory:** sample `VmRSS` from `/proc/self/status` every 500 ms during the run (main isolate),
  and read `VmHWM` at the end.
- **Per-chunk timeline** (C2): chunk start/end, wall time, RTF, so throttling shows as RTF climbing over time.
- **Thermal status** (`PowerManager.getCurrentThermalStatus`) and **battery %** + charging state
  (`BatteryManager`), at start and end, and sampled every 30 s on long runs.
- Keep the screen on during runs (`FLAG_KEEP_SCREEN_ON` from the Kotlin side). Unplug the phone for the
  long30 battery reading. Measure it via `adb` over Wi-Fi, or start the run and then unplug.

## Pass / fail (proposed thresholds, founder may adjust before starting)

Measured on the **target phone**, with `small.en-q5_0`, C2, and long30:

- **Pass:** sustained RTF **≤ 0.5** (a 10-min entry is ready about 5 min later), peak RSS **≤ 600 MB**,
  no crash or OOM, thermal status stays below `SEVERE`. **And** the clip8 C1 text matches 1a's
  `small.en-q5_0__S2.txt` (the same disfluencies; small float/thread-count differences are OK).
- **Partial:** RTF 0.5–1.5, or passes only while charging → on-device stays the default engine, but
  transcription is scheduled for charger/idle (D6 already makes this possible). Note what the user waits for.
- **Fail:** RTF > 1.5, OOM, or thermal shutdown → next steps in order: `base.en` + prompt,
  GPU backend (Vulkan/OpenCL), cloud engine (D8 consent flow).

Separately, **per-chunk prompting** passes if C2 keeps at least as many disfluencies as C1 on clip8
and doesn't add hallucinations at chunk boundaries (listen to the boundaries).

## Deliverable: `FINDINGS.md` (≤ 1 page)

1. **Answer** in one sentence: pass / partial / fail, on which device. Mark it **provisional**, since
   the Pixel 9a is a proxy.
2. **Device table:** model, SoC, RAM, Android version, and whether it is the first user's phone or a proxy.
   Leave a row for the user's phone, to be filled in by the re-run.
   Also note which result on the user's phone would **change the recommendation** (e.g. "if small.en
   RTF > 1.0 there, switch to charger-only transcription").
3. **Results table:** model × mode × audio → threads, load time, RTF, peak RSS, thermal end state, battery Δ.
4. **Text parity:** clip8 C1 vs. 1a desktop, diff summary. **Chunking:** C1 vs. C2 vs. C3 on the disfluencies
   around the 13 s pause and at chunk boundaries (short excerpts, nothing personal).
5. **Gotchas:** toolchain, build flags, FFI, `adb push` access, anything that cost > 15 min.
6. **Recommendation:** ship engine + threads + chunking mode, and whether medium is viable.
7. **Proposed edits to `docs/decisions.md`:** resolve "Engine choice", update "Target device", and
   refine D6 (chunking + prompt strategy).

## Guardrails

- Test audio is sensitive. It goes only to the founder's own phone via `adb`, stays gitignored,
  and is never uploaded, bundled in the APK, or shared via share sheets.
- The app declares **no `INTERNET` permission** in the release manifest. (Flutter adds it only to
  debug/profile manifests, so check the merged release manifest.)
- The Pixel 9a is a proxy (upper mid-range). Say so plainly in FINDINGS. Its numbers may not hold
  on the user's phone, and the decision is final only after the re-run.
- Stay in the timebox. If the FFI build won't link or a mode won't work, record why and move on.
- Throwaway code: optimize for learning, not reuse. The shim's shape may inform the D5 engine
  interface later; note that in FINDINGS if it does.
