//
//  EchoTransBridge.h
//  EchoTrans 本地转写引擎 C 桥接层
//
//  统一封装 whisper.cpp 与 sherpa-onnx(SenseVoice) 的 C API，
//  供 Swift 侧通过 -import-objc-header 直接调用。
//

#ifndef EchoTransBridge_h
#define EchoTransBridge_h

#include <stdint.h>

#if __cplusplus
extern "C" {
#endif

/// 用 whisper.cpp 转写 16kHz 单声道 PCM。
/// @param model_path  ggml 模型文件路径（如 ggml-large-v3-turbo.bin）
/// @param language    语言代码（"zh"/"en"/"ja"...），NULL 或 "auto" 表示自动检测
/// @param samples     16kHz 单声道 float32 PCM
/// @param n_samples   采样点数
/// @param out_text    成功时返回 malloc 分配的 UTF-8 文本，需用 et_free_string 释放
/// @return 0 成功；-1 模型加载失败；-2 转写失败
int et_whisper_transcribe(const char *model_path,
                          const char *language,
                          const float *samples,
                          int32_t n_samples,
                          char **out_text);

/// 用 sherpa-onnx SenseVoice 转写。
/// @param model_path   SenseVoice onnx 模型路径（model.int8.onnx）
/// @param tokens_path  tokens.txt 路径
/// @param language     "zh"/"en"/"ja"/"ko"/"yue"，空串表示自动
/// @param sample_rate  采样率（建议 16000）
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

#if __cplusplus
}
#endif

#endif /* EchoTransBridge_h */
