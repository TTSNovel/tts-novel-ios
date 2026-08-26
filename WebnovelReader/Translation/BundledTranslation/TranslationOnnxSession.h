#ifndef TranslationOnnxSession_h
#define TranslationOnnxSession_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TranslationOnnxDType) {
    TranslationOnnxDTypeFloat32,
    TranslationOnnxDTypeInt64,
    TranslationOnnxDTypeInt32,
    TranslationOnnxDTypeBool,
};

/// One named ONNX tensor, dtype-tagged, raw bytes in `data` (native-endian,
/// tightly packed) — same shape as VieNeuV3OnnxSession's VieNeuV3Tensor
/// (see its doc comment), duplicated here as a separate small ObjC++
/// bridge rather than reused directly: this is a completely unrelated
/// feature (translation, not TTS) and the two happen to need different
/// dtype coverage (this one needs `bool` for the Marian decoder's
/// `use_cache_branch` input; VieNeuV3's graphs never do) and different
/// per-session graph-optimization settings (see
/// OpusMTTranslationEngine's doc comment on why the decoder session
/// disables optimization) — keeping them separate means neither can
/// regress the other.
@interface TranslationOnnxTensor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) TranslationOnnxDType dtype;
@property (nonatomic, copy) NSArray<NSNumber *> *shape;
@property (nonatomic, strong) NSData *data;

- (instancetype)initWithName:(NSString *)name
                        dtype:(TranslationOnnxDType)dtype
                        shape:(NSArray<NSNumber *> *)shape
                         data:(NSData *)data;
@end

@interface TranslationOnnxSession : NSObject

/// `disableGraphOptimization`: the Marian decoder's merged/quantized graph
/// ties its embedding weight to the output projection (`share_encoder_
/// decoder_embeddings` in config.json) — onnxruntime's QDQ graph optimizer
/// has a bug transposing that shared weight's dequantization for this
/// pattern (`TransposeDQWeightsForMatMulNBits ... Missing required
/// scale`), confirmed via a local Python reproduction against the exact
/// same model file before writing this. Disabling graph optimization for
/// just this session avoids it entirely (verified fix, same repro); the
/// encoder session has no such shared/tied weight and works fine with
/// optimization enabled.
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                            intraOpThreads:(int)threads
                    disableGraphOptimization:(BOOL)disableGraphOptimization
                                     error:(NSError **)error;

/// Spike/experimental: same as the initializer above, but also registers
/// onnxruntime's CoreML execution provider (offloads eligible ops to the
/// Apple Neural Engine/GPU instead of running everything on CPU) before
/// building the session. Unproven for this specific model — the decoder
/// graph's `past_key_values.*` inputs change shape every decode step, and
/// CoreML has historically limited support for dynamic shapes, so this may
/// build/run no differently than CPU-only (silent fallback), or may fail to
/// build the session at all. Exists so that can actually be measured rather
/// than guessed at; not wired into `OpusMTTranslationEngine`'s normal
/// session creation.
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                            intraOpThreads:(int)threads
                    disableGraphOptimization:(BOOL)disableGraphOptimization
                                useCoreML:(BOOL)useCoreML
                                     error:(NSError **)error;

- (nullable NSArray<TranslationOnnxTensor *> *)runWithInputs:(NSArray<TranslationOnnxTensor *> *)inputs
                                                    outputNames:(NSArray<NSString *> *)outputNames
                                                          error:(NSError **)error;

@end

/// One sentence's autoregressive decode KV-cache, held as native ORT
/// buffers — see `TranslationOnnxSession`'s `-stepDecoderState:...` doc
/// comment for why this exists (avoiding a Swift round-trip for the cache
/// every decode step). Create one per sentence via `-makeDecoderState...`;
/// not safe to share across sentences decoded concurrently, but each
/// instance is only ever touched sequentially (one step at a time) by
/// whichever single sentence owns it, same as the old per-sentence Swift
/// arrays it replaces.
@interface TranslationOnnxDecoderState : NSObject
@end

@interface TranslationOnnxSession (AutoregressiveDecoding)

- (nullable TranslationOnnxDecoderState *)makeDecoderStateWithNumLayers:(NSInteger)numLayers
                                                                 numHeads:(NSInteger)numHeads
                                                                  headDim:(NSInteger)headDim
                                                                    error:(NSError **)error;

/// One greedy decode step against `self` (a decoder session), called once
/// per generated token for the same `state`. Replaces the old pattern
/// (Swift re-supplying the *entire* growing key/value cache as fresh
/// `TranslationOnnxTensor`s, each a Swift `[Float]` <-> `NSData` copy, on
/// every single call — see `OpusMTTranslationEngine.translateOne`'s prior
/// implementation): `state` instead holds the previous step's `Ort::Value`
/// outputs natively and feeds them straight back in as this step's inputs,
/// so the cache never crosses into Swift/Obj-C after the first step. Only
/// the one new input token crosses in, and only the argmax'd next token id
/// crosses out — the full `vocabSize`-length logits vector is reduced to
/// that single id inside this call, since nothing outside needs the rest.
- (nullable NSNumber *)stepDecoderState:(TranslationOnnxDecoderState *)state
                     encoderHiddenStates:(TranslationOnnxTensor *)encoderHiddenStates
                    encoderAttentionMask:(TranslationOnnxTensor *)encoderAttentionMask
                                  tokenId:(int64_t)tokenId
                                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif
