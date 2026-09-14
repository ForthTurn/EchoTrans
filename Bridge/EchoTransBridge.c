//
//  EchoTransBridge.c
//  whisper.cpp + sherpa-onnx (SenseVoice) 的 C 桥接实现
//

#include "EchoTransBridge.h"

#include "whisper.h"
#include "sherpa-onnx/c-api/c-api.h"

#include <stdlib.h>
#include <string.h>

static char *dup_text(const char *src) {
    if (!src) src = "";
    size_t n = strlen(src) + 1;
    char *dst = (char *)malloc(n);
    if (dst) memcpy(dst, src, n);
    return dst;
}

// ─────────────────────────── whisper.cpp ───────────────────────────

static int whisper_run(struct whisper_context *ctx,
                       const char *language,
                       const float *samples,
                       int32_t n_samples,
                       char **out_text) {
    struct whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wparams.print_progress   = false;
    wparams.print_special    = false;
    wparams.print_realtime   = false;
    wparams.print_timestamps = false;
    wparams.translate        = false;
    wparams.single_segment   = false;
    wparams.no_context       = true;
    wparams.suppress_nst     = true;
    wparams.temperature      = 0.0f;
    wparams.temperature_inc  = 0.0f;  // 单遍解码，长音频提速明显
    wparams.greedy.best_of   = 1;
    wparams.language         = (language && strcmp(language, "auto") != 0) ? language : NULL;
    wparams.n_threads        = 4;

    if (whisper_full(ctx, wparams, samples, (int)n_samples) != 0) {
        return -2;
    }

    // 拼接所有分段文本（按换行分隔）
    int n_seg = whisper_full_n_segments(ctx);
    size_t cap = 4096, len = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) return -3;
    buf[0] = '\0';

    for (int i = 0; i < n_seg; i++) {
        const char *seg = whisper_full_get_segment_text(ctx, i);
        if (!seg) continue;
        while (*seg == ' ' || *seg == '\n' || *seg == '\t') seg++;
        size_t seg_len = strlen(seg);
        while (seg_len > 0 && (seg[seg_len-1] == '\n')) seg_len--;
        if (seg_len == 0) continue;
        size_t need = len + seg_len + 2;
        if (need > cap) {
            while (cap < need) cap *= 2;
            char *nb = (char *)realloc(buf, cap);
            if (!nb) { free(buf); return -3; }
            buf = nb;
        }
        memcpy(buf + len, seg, seg_len);
        len += seg_len;
        buf[len++] = '\n';
        buf[len] = '\0';
    }

    *out_text = buf;
    return 0;
}

int et_whisper_transcribe(const char *model_path,
                          const char *language,
                          const float *samples,
                          int32_t n_samples,
                          char **out_text) {
    if (!model_path || !samples || n_samples <= 0 || !out_text) return -1;

    struct whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = true;
    struct whisper_context *ctx = whisper_init_from_file_with_params(model_path, cparams);
    if (!ctx) return -1;

    int rc = whisper_run(ctx, language, samples, n_samples, out_text);
    whisper_free(ctx);
    return rc;
}

void *et_whisper_open(const char *model_path) {
    if (!model_path) return NULL;
    struct whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = true;
    return whisper_init_from_file_with_params(model_path, cparams);
}

int et_whisper_transcribe_ctx(void *handle,
                              const char *language,
                              const float *samples,
                              int32_t n_samples,
                              char **out_text) {
    if (!handle || !samples || n_samples <= 0 || !out_text) return -1;
    return whisper_run((struct whisper_context *)handle, language, samples, n_samples, out_text);
}

void et_whisper_close(void *handle) {
    if (handle) whisper_free((struct whisper_context *)handle);
}

// ─────────────────────────── SenseVoice (sherpa-onnx) ───────────────────────────

static const SherpaOnnxOfflineRecognizer *sensevoice_create(const char *model_path,
                                                            const char *tokens_path,
                                                            const char *language) {
    SherpaOnnxOfflineRecognizerConfig config;
    memset(&config, 0, sizeof(config));

    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;

    config.model_config.tokens          = tokens_path;
    config.model_config.num_threads     = 4;
    config.model_config.debug           = 0;
    config.model_config.provider        = "cpu";
    config.model_config.sense_voice.model    = model_path;
    config.model_config.sense_voice.language = language ? language : "";
    config.model_config.sense_voice.use_itn  = 1;

    config.decoding_method = "greedy_search";

    return SherpaOnnxCreateOfflineRecognizer(&config);
}

/// 单块转写（调用方保证块长 ≤30s）
static int sensevoice_run_once(const SherpaOnnxOfflineRecognizer *recognizer,
                               const float *samples,
                               int32_t n_samples,
                               int32_t sample_rate,
                               char **out_text) {
    const SherpaOnnxOfflineStream *stream = SherpaOnnxCreateOfflineStream(recognizer);
    if (!stream) return -2;

    SherpaOnnxAcceptWaveformOffline(stream, sample_rate > 0 ? sample_rate : 16000, samples, n_samples);
    SherpaOnnxDecodeOfflineStream(recognizer, stream);

    const SherpaOnnxOfflineRecognizerResult *result = SherpaOnnxGetOfflineStreamResult(stream);
    char *text = dup_text(result ? result->text : "");
    if (result) SherpaOnnxDestroyOfflineRecognizerResult(result);

    SherpaOnnxDestroyOfflineStream(stream);

    *out_text = text;
    return 0;
}

int et_sensevoice_transcribe(const char *model_path,
                             const char *tokens_path,
                             const char *language,
                             const float *samples,
                             int32_t n_samples,
                             int32_t sample_rate,
                             char **out_text) {
    if (!model_path || !tokens_path || !samples || n_samples <= 0 || !out_text) return -1;
    if (sample_rate <= 0) sample_rate = 16000;

    const SherpaOnnxOfflineRecognizer *recognizer = sensevoice_create(model_path, tokens_path, language);
    if (!recognizer) return -1;

    // SenseVoice 离线模型无法一次吃下超长音频，按 30s 分块逐一解码
    const int32_t chunk = 16000 * 30;
    size_t cap = 4096, len = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) { SherpaOnnxDestroyOfflineRecognizer(recognizer); return -3; }
    buf[0] = '\0';

    for (int32_t offset = 0; offset < n_samples; offset += chunk) {
        int32_t n = (n_samples - offset < chunk) ? (n_samples - offset) : chunk;
        char *piece = NULL;
        int rc = sensevoice_run_once(recognizer, samples + offset, n, sample_rate, &piece);
        if (rc != 0) {
            free(buf);
            SherpaOnnxDestroyOfflineRecognizer(recognizer);
            return rc;
        }
        const char *text = piece ? piece : "";
        size_t text_len = strlen(text);
        if (text_len > 0) {
            size_t need = len + text_len + 1;
            if (need > cap) {
                while (cap < need) cap *= 2;
                char *nb = (char *)realloc(buf, cap);
                if (!nb) {
                    free(piece);
                    free(buf);
                    SherpaOnnxDestroyOfflineRecognizer(recognizer);
                    return -3;
                }
                buf = nb;
            }
            memcpy(buf + len, text, text_len);
            len += text_len;
            buf[len] = '\0';
        }
        free(piece);
    }

    SherpaOnnxDestroyOfflineRecognizer(recognizer);
    *out_text = buf;
    return 0;
}

void *et_sensevoice_open(const char *model_path,
                         const char *tokens_path,
                         const char *language) {
    if (!model_path || !tokens_path) return NULL;
    return (void *)sensevoice_create(model_path, tokens_path, language);
}

int et_sensevoice_transcribe_ctx(void *handle,
                                 const float *samples,
                                 int32_t n_samples,
                                 int32_t sample_rate,
                                 char **out_text) {
    if (!handle || !samples || n_samples <= 0 || !out_text) return -1;
    return sensevoice_run_once((const SherpaOnnxOfflineRecognizer *)handle,
                               samples, n_samples, sample_rate, out_text);
}

void et_sensevoice_close(void *handle) {
    if (handle) SherpaOnnxDestroyOfflineRecognizer((const SherpaOnnxOfflineRecognizer *)handle);
}

void et_free_string(char *s) {
    if (s) free(s);
}
