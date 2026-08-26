#import "TranslationOnnxSession.h"
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <onnxruntime/coreml_provider_factory.h>
#include <limits>
#include <string>
#include <vector>

@implementation TranslationOnnxTensor

- (instancetype)initWithName:(NSString *)name
                        dtype:(TranslationOnnxDType)dtype
                        shape:(NSArray<NSNumber *> *)shape
                         data:(NSData *)data {
    self = [super init];
    if (!self) return nil;
    _name = name; _dtype = dtype; _shape = shape; _data = data;
    return self;
}

@end

// Same rationale as VieNeuV3OnnxSession's identical placeholder — ORT
// asserts a non-null data pointer even for a zero-element tensor (the
// decoder's first call feeds empty `past_key_values.*` of length 0).
static uint8_t sEmptyTensorByte = 0;

static NSError *ortError(const char *what, const std::exception &e) {
    NSString *msg = [NSString stringWithFormat:@"%s: %s", what, e.what()];
    return [NSError errorWithDomain:@"TranslationOnnxSession" code:1
                            userInfo:@{NSLocalizedDescriptionKey: msg}];
}

@implementation TranslationOnnxSession {
    std::unique_ptr<Ort::Env> _env;
    std::unique_ptr<Ort::Session> _session;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                            intraOpThreads:(int)threads
                    disableGraphOptimization:(BOOL)disableGraphOptimization
                                     error:(NSError **)error {
    return [self initWithModelPath:modelPath intraOpThreads:threads
             disableGraphOptimization:disableGraphOptimization useCoreML:NO error:error];
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                            intraOpThreads:(int)threads
                    disableGraphOptimization:(BOOL)disableGraphOptimization
                                useCoreML:(BOOL)useCoreML
                                     error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    try {
        _env = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING, "TranslationOnnx");
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(threads > 0 ? threads : 2);
        options.SetGraphOptimizationLevel(
            disableGraphOptimization ? GraphOptimizationLevel::ORT_DISABLE_ALL
                                      : GraphOptimizationLevel::ORT_ENABLE_ALL);
        if (useCoreML) {
            // Spike — see this initializer's header doc comment. ANE-only
            // isn't required (COREML_FLAG_ONLY_ENABLE_DEVICE_WITH_ANE
            // omitted): the point here is first just seeing whether the
            // session builds and runs at all with this provider attached,
            // not restricting where it's allowed to run yet.
            uint32_t coremlFlags = COREML_FLAG_USE_NONE;
            OrtStatus *status = OrtSessionOptionsAppendExecutionProvider_CoreML(options, coremlFlags);
            if (status != nullptr) {
                NSString *msg = [NSString stringWithUTF8String:Ort::GetApi().GetErrorMessage(status)];
                Ort::GetApi().ReleaseStatus(status);
                if (error) {
                    *error = [NSError errorWithDomain:@"TranslationOnnxSession" code:3
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                  [NSString stringWithFormat:@"CoreML EP registration failed: %@", msg]}];
                }
                return nil;
            }
        }
        _session = std::make_unique<Ort::Session>(*_env, modelPath.UTF8String, options);
    } catch (const std::exception &e) {
        if (error) *error = ortError("session init failed", e);
        return nil;
    }
    return self;
}

- (nullable NSArray<TranslationOnnxTensor *> *)runWithInputs:(NSArray<TranslationOnnxTensor *> *)inputs
                                                    outputNames:(NSArray<NSString *> *)outputNames
                                                          error:(NSError **)error {
    try {
        Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

        std::vector<std::string> inputNameStrings;
        std::vector<const char *> inputNamesC;
        std::vector<Ort::Value> inputValues;
        std::vector<std::vector<int64_t>> shapeStorage;
        inputNameStrings.reserve(inputs.count);
        inputNamesC.reserve(inputs.count);
        inputValues.reserve(inputs.count);
        shapeStorage.reserve(inputs.count);

        for (TranslationOnnxTensor *t in inputs) {
            std::vector<int64_t> shape;
            for (NSNumber *n in t.shape) shape.push_back(n.longLongValue);
            shapeStorage.push_back(shape);
            std::vector<int64_t> &shapeRef = shapeStorage.back();

            const void *rawPtr = t.data.length > 0 ? t.data.bytes : (const void *)&sEmptyTensorByte;
            switch (t.dtype) {
                case TranslationOnnxDTypeFloat32: {
                    size_t count = t.data.length / sizeof(float);
                    inputValues.push_back(Ort::Value::CreateTensor<float>(
                        memInfo, const_cast<float *>((const float *)rawPtr), count, shapeRef.data(), shapeRef.size()));
                    break;
                }
                case TranslationOnnxDTypeInt64: {
                    size_t count = t.data.length / sizeof(int64_t);
                    inputValues.push_back(Ort::Value::CreateTensor<int64_t>(
                        memInfo, const_cast<int64_t *>((const int64_t *)rawPtr), count, shapeRef.data(), shapeRef.size()));
                    break;
                }
                case TranslationOnnxDTypeInt32: {
                    size_t count = t.data.length / sizeof(int32_t);
                    inputValues.push_back(Ort::Value::CreateTensor<int32_t>(
                        memInfo, const_cast<int32_t *>((const int32_t *)rawPtr), count, shapeRef.data(), shapeRef.size()));
                    break;
                }
                case TranslationOnnxDTypeBool: {
                    // ORT's C API represents `tensor(bool)` as 1-byte
                    // elements — use the untyped CreateTensor overload with
                    // an explicit element type rather than
                    // CreateTensor<bool>, since C++ `bool`'s size/layout
                    // isn't guaranteed to match ORT's on-wire bool
                    // representation the way it happens to on Apple
                    // platforms; being explicit here costs nothing.
                    size_t count = t.data.length / sizeof(uint8_t);
                    inputValues.push_back(Ort::Value::CreateTensor(
                        memInfo, const_cast<void *>(rawPtr), count * sizeof(uint8_t),
                        shapeRef.data(), shapeRef.size(), ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL));
                    break;
                }
            }
            inputNameStrings.push_back(std::string(t.name.UTF8String));
        }
        for (auto &s : inputNameStrings) inputNamesC.push_back(s.c_str());

        std::vector<std::string> outputNameStrings;
        std::vector<const char *> outputNamesC;
        outputNameStrings.reserve(outputNames.count);
        outputNamesC.reserve(outputNames.count);
        for (NSString *n in outputNames) outputNameStrings.push_back(std::string(n.UTF8String));
        for (auto &s : outputNameStrings) outputNamesC.push_back(s.c_str());

        auto outputs = _session->Run(Ort::RunOptions{nullptr},
                                      inputNamesC.data(), inputValues.data(), inputValues.size(),
                                      outputNamesC.data(), outputNamesC.size());

        NSMutableArray<TranslationOnnxTensor *> *result = [NSMutableArray arrayWithCapacity:outputs.size()];
        for (size_t i = 0; i < outputs.size(); i++) {
            Ort::Value &v = outputs[i];
            auto info = v.GetTensorTypeAndShapeInfo();
            auto shapeVec = info.GetShape();
            NSMutableArray<NSNumber *> *shape = [NSMutableArray arrayWithCapacity:shapeVec.size()];
            for (int64_t d : shapeVec) [shape addObject:@(d)];

            ONNXTensorElementDataType elemType = info.GetElementType();
            NSString *name = outputNames[i];
            if (elemType == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
                size_t count = info.GetElementCount();
                NSData *data = [NSData dataWithBytes:v.GetTensorData<float>() length:count * sizeof(float)];
                [result addObject:[[TranslationOnnxTensor alloc] initWithName:name dtype:TranslationOnnxDTypeFloat32 shape:shape data:data]];
            } else if (elemType == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) {
                size_t count = info.GetElementCount();
                NSData *data = [NSData dataWithBytes:v.GetTensorData<int64_t>() length:count * sizeof(int64_t)];
                [result addObject:[[TranslationOnnxTensor alloc] initWithName:name dtype:TranslationOnnxDTypeInt64 shape:shape data:data]];
            } else if (elemType == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32) {
                size_t count = info.GetElementCount();
                NSData *data = [NSData dataWithBytes:v.GetTensorData<int32_t>() length:count * sizeof(int32_t)];
                [result addObject:[[TranslationOnnxTensor alloc] initWithName:name dtype:TranslationOnnxDTypeInt32 shape:shape data:data]];
            } else {
                if (error) {
                    *error = [NSError errorWithDomain:@"TranslationOnnxSession" code:2
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                  [NSString stringWithFormat:@"unsupported output dtype for %@", name]}];
                }
                return nil;
            }
        }
        return result;
    } catch (const std::exception &e) {
        if (error) *error = ortError("run failed", e);
        return nil;
    }
}

@end

// One sentence's autoregressive decode KV-cache, held as native `Ort::Value`s
// — see TranslationOnnxSession.h's `-stepDecoderState:...` doc comment for
// why. `encoderKey`/`encoderValue` are set once (from the first step's
// outputs) and never moved again — every step wraps a fresh non-owning
// *view* onto whatever they currently hold (the constructor's empty
// placeholder, or the captured real values) rather than consuming them, so
// they survive across every remaining step unchanged. `decoderKey`/
// `decoderValue`, in contrast, really do get replaced every step (that's
// the actual growing cache), so those are freely moved in and out.
struct DecoderCacheState {
    std::vector<Ort::Value> decoderKey;
    std::vector<Ort::Value> decoderValue;
    std::vector<Ort::Value> encoderKey;
    std::vector<Ort::Value> encoderValue;
    std::vector<std::string> decoderKeyNames;
    std::vector<std::string> decoderValueNames;
    std::vector<std::string> encoderKeyNames;
    std::vector<std::string> encoderValueNames;
    std::vector<std::string> presentDecoderKeyNames;
    std::vector<std::string> presentDecoderValueNames;
    std::vector<std::string> presentEncoderKeyNames;
    std::vector<std::string> presentEncoderValueNames;
    int numLayers = 0;
    // True from the second call onward — this sentence's very first step
    // both feeds `use_cache_branch=false` to the model *and* is the one
    // step that still needs to fetch `present.*.encoder.key/value` (to
    // capture into `encoderKey`/`encoderValue` for every later step); both
    // conditions flip together, so one flag covers both.
    bool warm = false;
};

@implementation TranslationOnnxDecoderState {
@public
    std::unique_ptr<DecoderCacheState> cppState;
}
@end

@implementation TranslationOnnxSession (AutoregressiveDecoding)

- (nullable TranslationOnnxDecoderState *)makeDecoderStateWithNumLayers:(NSInteger)numLayers
                                                                 numHeads:(NSInteger)numHeads
                                                                  headDim:(NSInteger)headDim
                                                                    error:(NSError **)error {
    try {
        auto state = std::make_unique<DecoderCacheState>();
        state->numLayers = (int)numLayers;

        Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        std::vector<int64_t> emptyShape = {1, (int64_t)numHeads, 0, (int64_t)headDim};

        state->decoderKey.reserve(numLayers);
        state->decoderValue.reserve(numLayers);
        state->encoderKey.reserve(numLayers);
        state->encoderValue.reserve(numLayers);
        for (NSInteger i = 0; i < numLayers; i++) {
            // Same zero-element-tensor trick as `runWithInputs:...` above
            // (`sEmptyTensorByte`) — this sentence's first step has no real
            // cache yet in any of these four slots.
            state->decoderKey.push_back(Ort::Value::CreateTensor<float>(
                memInfo, (float *)&sEmptyTensorByte, 0, emptyShape.data(), emptyShape.size()));
            state->decoderValue.push_back(Ort::Value::CreateTensor<float>(
                memInfo, (float *)&sEmptyTensorByte, 0, emptyShape.data(), emptyShape.size()));
            state->encoderKey.push_back(Ort::Value::CreateTensor<float>(
                memInfo, (float *)&sEmptyTensorByte, 0, emptyShape.data(), emptyShape.size()));
            state->encoderValue.push_back(Ort::Value::CreateTensor<float>(
                memInfo, (float *)&sEmptyTensorByte, 0, emptyShape.data(), emptyShape.size()));

            std::string idx = std::to_string(i);
            state->decoderKeyNames.push_back("past_key_values." + idx + ".decoder.key");
            state->decoderValueNames.push_back("past_key_values." + idx + ".decoder.value");
            state->encoderKeyNames.push_back("past_key_values." + idx + ".encoder.key");
            state->encoderValueNames.push_back("past_key_values." + idx + ".encoder.value");
            state->presentDecoderKeyNames.push_back("present." + idx + ".decoder.key");
            state->presentDecoderValueNames.push_back("present." + idx + ".decoder.value");
            state->presentEncoderKeyNames.push_back("present." + idx + ".encoder.key");
            state->presentEncoderValueNames.push_back("present." + idx + ".encoder.value");
        }

        TranslationOnnxDecoderState *result = [[TranslationOnnxDecoderState alloc] init];
        result->cppState = std::move(state);
        return result;
    } catch (const std::exception &e) {
        if (error) *error = ortError("decoder state init failed", e);
        return nil;
    }
}

- (nullable NSNumber *)stepDecoderState:(TranslationOnnxDecoderState *)state
                     encoderHiddenStates:(TranslationOnnxTensor *)encoderHiddenStates
                    encoderAttentionMask:(TranslationOnnxTensor *)encoderAttentionMask
                                  tokenId:(int64_t)tokenId
                                    error:(NSError **)error {
    try {
        DecoderCacheState &s = *state->cppState;
        Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

        int64_t tokenIdStorage = tokenId;
        std::vector<int64_t> tokenShape = {1, 1};
        Ort::Value inputIdsValue = Ort::Value::CreateTensor<int64_t>(
            memInfo, &tokenIdStorage, 1, tokenShape.data(), tokenShape.size());

        std::vector<int64_t> maskShape;
        for (NSNumber *n in encoderAttentionMask.shape) maskShape.push_back(n.longLongValue);
        Ort::Value maskValue = Ort::Value::CreateTensor<int64_t>(
            memInfo, (int64_t *)encoderAttentionMask.data.bytes,
            encoderAttentionMask.data.length / sizeof(int64_t), maskShape.data(), maskShape.size());

        std::vector<int64_t> hiddenShape;
        for (NSNumber *n in encoderHiddenStates.shape) hiddenShape.push_back(n.longLongValue);
        Ort::Value hiddenValue = Ort::Value::CreateTensor<float>(
            memInfo, (float *)encoderHiddenStates.data.bytes,
            encoderHiddenStates.data.length / sizeof(float), hiddenShape.data(), hiddenShape.size());

        uint8_t useCacheBranchByte = s.warm ? 1 : 0;
        std::vector<int64_t> boolShape = {1};
        Ort::Value useCacheBranchValue = Ort::Value::CreateTensor(
            memInfo, &useCacheBranchByte, sizeof(uint8_t), boolShape.data(), boolShape.size(),
            ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL);

        // Non-owning *views* onto whatever `s.encoderKey`/`encoderValue`
        // currently hold — safe to build fresh each step without copying,
        // since `CreateTensor` here just wraps the existing buffer (same
        // pattern as `maskValue`/`hiddenValue` above) rather than
        // allocating/copying a new one.
        std::vector<Ort::Value> encoderKeyViews, encoderValueViews;
        encoderKeyViews.reserve(s.numLayers);
        encoderValueViews.reserve(s.numLayers);
        for (int i = 0; i < s.numLayers; i++) {
            auto keyInfo = s.encoderKey[i].GetTensorTypeAndShapeInfo();
            auto keyShape = keyInfo.GetShape();
            encoderKeyViews.push_back(Ort::Value::CreateTensor<float>(
                memInfo, s.encoderKey[i].GetTensorMutableData<float>(), keyInfo.GetElementCount(),
                keyShape.data(), keyShape.size()));
            auto valueInfo = s.encoderValue[i].GetTensorTypeAndShapeInfo();
            auto valueShape = valueInfo.GetShape();
            encoderValueViews.push_back(Ort::Value::CreateTensor<float>(
                memInfo, s.encoderValue[i].GetTensorMutableData<float>(), valueInfo.GetElementCount(),
                valueShape.data(), valueShape.size()));
        }

        // Build the ordered input list, *moving* the decoder KV-cache's
        // `Ort::Value`s straight out of `s` — no re-serialization, no
        // Swift/NSData crossing. They get replaced by this step's fresh
        // `present.*.decoder.*` outputs right after `Run()` below.
        std::vector<Ort::Value> inputValues;
        std::vector<const char *> inputNamesC;
        inputValues.reserve(4 + s.numLayers * 4);
        inputNamesC.reserve(4 + s.numLayers * 4);

        inputValues.push_back(std::move(inputIdsValue));       inputNamesC.push_back("input_ids");
        inputValues.push_back(std::move(maskValue));           inputNamesC.push_back("encoder_attention_mask");
        inputValues.push_back(std::move(hiddenValue));         inputNamesC.push_back("encoder_hidden_states");
        inputValues.push_back(std::move(useCacheBranchValue)); inputNamesC.push_back("use_cache_branch");
        for (int i = 0; i < s.numLayers; i++) {
            inputValues.push_back(std::move(s.decoderKey[i]));      inputNamesC.push_back(s.decoderKeyNames[i].c_str());
            inputValues.push_back(std::move(s.decoderValue[i]));    inputNamesC.push_back(s.decoderValueNames[i].c_str());
            inputValues.push_back(std::move(encoderKeyViews[i]));   inputNamesC.push_back(s.encoderKeyNames[i].c_str());
            inputValues.push_back(std::move(encoderValueViews[i])); inputNamesC.push_back(s.encoderValueNames[i].c_str());
        }

        // `present.*.encoder.*` only requested on this sentence's first
        // step (`!s.warm`) — from then on the encoder KV never changes, so
        // there's nothing new to fetch; matches the old Swift loop's
        // `if !useCacheBranch { pastEncoderKey[i] = ... }` guard, just
        // avoiding computing/returning values that would be discarded.
        std::vector<const char *> outputNamesC;
        outputNamesC.reserve(1 + s.numLayers * (s.warm ? 2 : 4));
        outputNamesC.push_back("logits");
        for (int i = 0; i < s.numLayers; i++) {
            outputNamesC.push_back(s.presentDecoderKeyNames[i].c_str());
            outputNamesC.push_back(s.presentDecoderValueNames[i].c_str());
            if (!s.warm) {
                outputNamesC.push_back(s.presentEncoderKeyNames[i].c_str());
                outputNamesC.push_back(s.presentEncoderValueNames[i].c_str());
            }
        }

        auto outputs = _session->Run(Ort::RunOptions{nullptr},
                                      inputNamesC.data(), inputValues.data(), inputValues.size(),
                                      outputNamesC.data(), outputNamesC.size());

        // Argmax computed directly on ORT's own output buffer — the full
        // `vocabSize`-length logits vector never gets copied out to
        // NSData/Swift at all, unlike the old per-step `floats(logits)`.
        Ort::Value &logits = outputs[0];
        auto logitsInfo = logits.GetTensorTypeAndShapeInfo();
        auto logitsShape = logitsInfo.GetShape();
        int64_t vocabSize = logitsShape.back();
        const float *logitsData = logits.GetTensorData<float>();
        int64_t elementCount = (int64_t)logitsInfo.GetElementCount();
        int64_t lastStepStart = elementCount - vocabSize;
        int64_t bestIndex = 0;
        float bestValue = -std::numeric_limits<float>::infinity();
        for (int64_t i = 0; i < vocabSize; i++) {
            float v = logitsData[lastStepStart + i];
            if (v > bestValue) { bestValue = v; bestIndex = i; }
        }

        // Refill `s` from this step's outputs — `present.i.decoder.key/
        // value` are always outputs[1 + i*2]/[1 + i*2 + 1] (requested every
        // step); `present.i.encoder.key/value` only exist in `outputs` on
        // the first step (see the `!s.warm` guard above), captured into `s`
        // once there and left untouched (via the view mechanism above) on
        // every step after.
        int idx = 1;
        for (int i = 0; i < s.numLayers; i++) {
            s.decoderKey[i] = std::move(outputs[idx++]);
            s.decoderValue[i] = std::move(outputs[idx++]);
            if (!s.warm) {
                s.encoderKey[i] = std::move(outputs[idx++]);
                s.encoderValue[i] = std::move(outputs[idx++]);
            }
        }
        s.warm = true;

        return @(bestIndex);
    } catch (const std::exception &e) {
        if (error) *error = ortError("decoder step failed", e);
        return nil;
    }
}

@end
