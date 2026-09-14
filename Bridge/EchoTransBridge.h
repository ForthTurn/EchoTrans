//
//  EchoTransBridge.h
//  EchoTrans 本地转写引擎 C 桥接层
//
//  统一封装 whisper.cpp 与 sherpa-onnx(SenseVoice) 的 C API，
//  供 Swift 侧通过 -import-objc-header 直接调用。
//
//  两套接口：
//   1. 一次性（et_whisper_transcribe / et_sensevoice_transcribe）：加载→转写→释放，适合整段离线转写
//   2. 持久句柄（et_*_open / et_*_transcribe_ctx / et_*_close）：模型常驻内存，适合实时分块转写
//

#ifndef EchoTransBridge_h
#define EchoTransBridge_h

#include <stdint.h>

#if __cplusplus
extern "C" {
#endif

// ─────────────────────────── 一次性接口 ───────────────────────────

/// 用 whisper.cpp 转写 16kHz 单声道 PCM。
/// @return 0 成功；-1 模型加载失败；-2 转写失败
int et_whisper_transcribe(const char *model_path,
                          const char *language,
                          const float *samples,
                          int32_t n_samples,
                          char **out_text);

/// 用 sherpa-onnx SenseVoice 转写（内部按 30s 分块，支持任意长度）。
/// @return 0 成功；-1 识别器创建失败；-2 流创建失败
int et_sensevoice_transcribe(const char *model_path,
                             const char *tokens_path,
                             const char *language,
                             const float *samples,
                             int32_t n_samples,
                             int32_t sample_rate,
                             char **out_text);

/// 释放上述函数返回的字符串
void et_free_string(char *s);

// ─────────────────────────── 持久句柄接口 ───────────────────────────
// 模型只在 open 时加载一次，适合实时场景反复调用小块音频。
// 注意：句柄非线程安全，调用方需串行调用。

/// 打开 whisper 模型（常驻内存）。失败返回 NULL。
void *et_whisper_open(const char *model_path);

/// 用已打开的 whisper 句柄转写一块音频（≤30s 为宜）。
int et_whisper_transcribe_ctx(void *handle,
                              const char *language,
                              const float *samples,
                              int32_t n_samples,
                              char **out_text);

/// 关闭并释放 whisper 句柄。
void et_whisper_close(void *handle);

/// 打开 SenseVoice 识别器（常驻内存）。失败返回 NULL。
void *et_sensevoice_open(const char *model_path,
                         const char *tokens_path,
                         const char *language);

/// 用已打开的 SenseVoice 句柄转写一块音频（≤30s 为宜）。
int et_sensevoice_transcribe_ctx(void *handle,
                                 const float *samples,
                                 int32_t n_samples,
                                 int32_t sample_rate,
                                 char **out_text);

/// 关闭并释放 SenseVoice 句柄。
void et_sensevoice_close(void *handle);

#if __cplusplus
}
#endif

#endif /* EchoTransBridge_h */
