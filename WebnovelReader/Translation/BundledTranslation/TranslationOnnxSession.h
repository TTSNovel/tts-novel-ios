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

- (nullable NSArray<TranslationOnnxTensor *> *)runWithInputs:(NSArray<TranslationOnnxTensor *> *)inputs
                                                    outputNames:(NSArray<NSString *> *)outputNames
                                                          error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif
