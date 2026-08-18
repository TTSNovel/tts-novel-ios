#ifndef VieNeuCodecONNX_h
#define VieNeuCodecONNX_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C wrapper around ONNX Runtime's C++ API (onnxruntime_cxx_
/// api.h), used only from Swift (see VieNeuCodecDecoder.swift) — kept
/// separate from that Swift-facing wrapper because ORT's C API doesn't
/// import cleanly into Swift directly (function-pointer-table style),
/// unlike llama.h's plain extern "C" functions. Mirrors
/// `BaseTurboVieNeuTTS._decode` (vieneu/turbo.py): one stateless
/// session.run() call, `content_ids` (int64) + `voice_embedding` (float32,
/// 128) in, PCM float out.
@interface VieNeuCodecONNX : NSObject

- (nullable instancetype)initWithModelPath:(NSString *)modelPath error:(NSError **)error;

/// `contentIds`: audio-code token ids from VieNeuLlamaBackbone.
/// `voiceEmbedding`: the bundled preset's 128-float vector.
/// Returns mono PCM samples, or nil on failure (see `error`).
- (nullable NSArray<NSNumber *> *)decodeWithContentIds:(NSArray<NSNumber *> *)contentIds
                                          voiceEmbedding:(NSArray<NSNumber *> *)voiceEmbedding
                                                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif
