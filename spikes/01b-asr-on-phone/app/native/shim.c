#include "whisper.h"
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

#ifdef __cplusplus
extern "C" {
#endif

EXPORT void* dw_init(const char* model_path) {
    if (!model_path) return NULL;
    struct whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;
    return (void*)whisper_init_from_file_with_params(model_path, cparams);
}

EXPORT int dw_transcribe(void* ctx, const float* pcm, int n_samples, const char* prompt,
                         int n_threads, int carry_prompt) {
    if (!ctx || !pcm || n_samples <= 0) return -1;

    struct whisper_context* wctx = (struct whisper_context*)ctx;
    struct whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);

    wparams.n_threads = n_threads > 0 ? n_threads : 4;
    wparams.offset_ms = 0;
    wparams.translate = false;
    wparams.no_context = true;
    wparams.single_segment = false;
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
    wparams.temperature_inc = 0.0f;

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

EXPORT void* dw_vad_init(const char* vad_model_path) {
    if (!vad_model_path) return NULL;
    struct whisper_vad_context_params vparams = whisper_vad_default_context_params();
    vparams.n_threads = 4;
    vparams.use_gpu = false;
    return (void*)whisper_vad_init_from_file_with_params(vad_model_path, vparams);
}

EXPORT int dw_vad_segments(void* vctx, const float* pcm, int n, float* out_t0t1, int max_segments) {
    if (!vctx || !pcm || n <= 0 || !out_t0t1 || max_segments <= 0) return 0;

    struct whisper_vad_context* ctx = (struct whisper_vad_context*)vctx;
    struct whisper_vad_params vp = whisper_vad_default_params();
    struct whisper_vad_segments* segs = whisper_vad_segments_from_samples(ctx, vp, pcm, n);
    if (!segs) return 0;

    int n_segs = whisper_vad_segments_n_segments(segs);
    int to_copy = (n_segs > max_segments) ? max_segments : n_segs;

    for (int i = 0; i < to_copy; i++) {
        // whisper_vad_segments stores centiseconds in .start and .end
        out_t0t1[2 * i] = whisper_vad_segments_get_segment_t0(segs, i) / 100.0f;
        out_t0t1[2 * i + 1] = whisper_vad_segments_get_segment_t1(segs, i) / 100.0f;
    }

    whisper_vad_free_segments(segs);
    return to_copy;
}

EXPORT const char* dw_system_info(void) {
    return whisper_print_system_info();
}

EXPORT void dw_free(void* ctx) {
    if (ctx) {
        whisper_free((struct whisper_context*)ctx);
    }
}

EXPORT void dw_vad_free(void* vctx) {
    if (vctx) {
        whisper_vad_free((struct whisper_vad_context*)vctx);
    }
}

#ifdef __cplusplus
}
#endif
