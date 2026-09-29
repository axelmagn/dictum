#include "whisper.h"
#include "ggml.h"
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

#ifdef __cplusplus
extern "C" {
#endif

// Progress callback hook
typedef void (*dw_progress_cb)(int progress);
static __thread dw_progress_cb g_progress_cb = NULL;

EXPORT void dw_set_progress_callback(dw_progress_cb cb) {
    g_progress_cb = cb;
}

static void whisper_progress_thunk(struct whisper_context* ctx, struct whisper_state* state, int progress, void* user_data) {
    (void)ctx;
    (void)state;
    (void)user_data;
    if (g_progress_cb) {
        g_progress_cb(progress);
    }
}

// Whisper inference (existing from 01b)
EXPORT void* dw_init(const char* model_path) {
    if (!model_path) return NULL;
    struct whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;
    return (void*)whisper_init_from_file_with_params(model_path, cparams);
}

EXPORT int dw_transcribe(void* ctx, const float* pcm, int n_samples, const char* prompt,
                         int n_threads, int carry_prompt, int audio_ctx) {
    if (!ctx || !pcm || n_samples <= 0) return -1;

    struct whisper_context* wctx = (struct whisper_context*)ctx;
    struct whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);

    wparams.n_threads = n_threads > 0 ? n_threads : 4;
    wparams.offset_ms = 0;
    // Shrink encoder window to chunk length (0 = full 30 s / 1500 ctx).
    wparams.audio_ctx = audio_ctx > 0 ? audio_ctx : 0;
    if (g_progress_cb) {
        wparams.progress_callback = whisper_progress_thunk;
        wparams.progress_callback_user_data = NULL;
    }
    wparams.translate = false;
    wparams.no_context = true;
    wparams.single_segment = true;
    wparams.no_timestamps = true;
    wparams.print_special = false;
    wparams.print_progress = false;
    wparams.print_realtime = false;
    wparams.print_timestamps = false;

    if (prompt && strlen(prompt) > 0) {
        wparams.initial_prompt = prompt;
    }
    wparams.carry_initial_prompt = (carry_prompt != 0);

    wparams.language = "en";
    wparams.detect_language = false;
    wparams.suppress_nst = false;
    wparams.temperature = 0.0f;
    wparams.temperature_inc = 0.2f;
    wparams.entropy_thold = 2.4f;
    wparams.logprob_thold = -1.0f;
    wparams.max_initial_ts = 1.0f;

    return whisper_full(wctx, wparams, pcm, n_samples);
}

EXPORT int dw_n_segments(void* ctx) {
    if (!ctx) return 0;
    return whisper_full_n_segments((struct whisper_context*)ctx);
}

EXPORT const char* dw_segment_text(void* ctx, int i) {
    if (!ctx) return "";
    return whisper_full_get_segment_text((struct whisper_context*)ctx, i);
}

EXPORT int64_t dw_segment_t0(void* ctx, int i) {
    if (!ctx) return 0;
    return whisper_full_get_segment_t0((struct whisper_context*)ctx, i);
}

EXPORT int64_t dw_segment_t1(void* ctx, int i) {
    if (!ctx) return 0;
    return whisper_full_get_segment_t1((struct whisper_context*)ctx, i);
}

EXPORT void dw_free(void* ctx) {
    if (ctx) {
        whisper_free((struct whisper_context*)ctx);
    }
}

// Quiet log callback to suppress per-frame VAD logs from flooding logcat
static void whisper_quiet_log_callback(enum ggml_log_level level, const char* text, void* user_data) {
    (void)level;
    (void)text;
    (void)user_data;
}

EXPORT void dw_suppress_logs(void) {
    whisper_log_set(whisper_quiet_log_callback, NULL);
}

// Streaming Silero VAD (Spike 02)
EXPORT void* dw_vad_stream_init(const char* vad_model_path) {
    if (!vad_model_path) return NULL;
    struct whisper_vad_context_params vparams = whisper_vad_default_context_params();
    vparams.n_threads = 1;
    vparams.use_gpu = false;
    return (void*)whisper_vad_init_from_file_with_params(vad_model_path, vparams);
}

EXPORT float dw_vad_stream_feed(void* vctx, const float* pcm512) {
    if (!vctx || !pcm512) return 0.0f;
    struct whisper_vad_context* ctx = (struct whisper_vad_context*)vctx;
    if (!whisper_vad_detect_speech_no_reset(ctx, pcm512, 512)) {
        return 0.0f;
    }
    if (whisper_vad_n_probs(ctx) > 0) {
        return whisper_vad_probs(ctx)[0];
    }
    return 0.0f;
}

EXPORT void dw_vad_stream_reset(void* vctx) {
    if (vctx) {
        whisper_vad_reset_state((struct whisper_vad_context*)vctx);
    }
}

EXPORT void dw_vad_stream_free(void* vctx) {
    if (vctx) {
        whisper_vad_free((struct whisper_vad_context*)vctx);
    }
}

EXPORT const char* dw_system_info(void) {
    return whisper_print_system_info();
}

#ifdef __cplusplus
}
#endif
