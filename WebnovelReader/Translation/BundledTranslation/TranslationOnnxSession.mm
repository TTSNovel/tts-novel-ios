#import "TranslationOnnxSession.h"
#include <onnxruntime/onnxruntime_cxx_api.h>
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
    self = [super init];
    if (!self) return nil;
    try {
        _env = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING, "TranslationOnnx");
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(threads > 0 ? threads : 2);
        options.SetGraphOptimizationLevel(
            disableGraphOptimization ? GraphOptimizationLevel::ORT_DISABLE_ALL
                                      : GraphOptimizationLevel::ORT_ENABLE_ALL);
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
