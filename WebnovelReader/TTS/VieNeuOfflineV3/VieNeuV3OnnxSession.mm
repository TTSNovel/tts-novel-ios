#import "VieNeuV3OnnxSession.h"
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <vector>

@implementation VieNeuV3Tensor

- (instancetype)initWithName:(NSString *)name
                        dtype:(VieNeuV3DType)dtype
                        shape:(NSArray<NSNumber *> *)shape
                         data:(NSData *)data {
    self = [super init];
    if (!self) return nil;
    _name = name; _dtype = dtype; _shape = shape; _data = data;
    return self;
}

@end

// Ort::Value::CreateTensor asserts its data pointer is non-null even for a
// zero-element tensor (the very first acoustic-decoder call feeds an empty
// `past_k_0`/`past_v_0` — see VieNeuV3OnnxEngine.acousticFrame) — NSData's
// `.bytes` for a zero-length NSData is allowed to return NULL, so route
// every empty buffer through this one static non-null placeholder instead
// (never dereferenced: ORT only reads `count` elements, which is 0 here).
static uint8_t sEmptyTensorByte = 0;

static NSError *ortError(const char *what, const std::exception &e) {
    NSString *msg = [NSString stringWithFormat:@"%s: %s", what, e.what()];
    return [NSError errorWithDomain:@"VieNeuV3OnnxSession" code:1
                            userInfo:@{NSLocalizedDescriptionKey: msg}];
}

@implementation VieNeuV3OnnxSession {
    std::unique_ptr<Ort::Env> _env;
    std::unique_ptr<Ort::Session> _session;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                            intraOpThreads:(int)threads
                                     error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    try {
        _env = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING, "VieNeuV3");
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(threads > 0 ? threads : 2);
        options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        _session = std::make_unique<Ort::Session>(*_env, modelPath.UTF8String, options);
    } catch (const std::exception &e) {
        if (error) *error = ortError("session init failed", e);
        return nil;
    }
    return self;
}

- (nullable NSArray<VieNeuV3Tensor *> *)runWithInputs:(NSArray<VieNeuV3Tensor *> *)inputs
                                            outputNames:(NSArray<NSString *> *)outputNames
                                                  error:(NSError **)error {
    try {
        Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

        // Keep every C-string / std::vector alive for the whole call —
        // Ort::Value wraps the raw pointers, it doesn't copy.
        std::vector<std::string> inputNameStrings;
        std::vector<const char *> inputNamesC;
        std::vector<Ort::Value> inputValues;
        std::vector<std::vector<int64_t>> shapeStorage;
        inputNameStrings.reserve(inputs.count);
        inputNamesC.reserve(inputs.count);
        inputValues.reserve(inputs.count);
        shapeStorage.reserve(inputs.count);

        for (VieNeuV3Tensor *t in inputs) {
            std::vector<int64_t> shape;
            for (NSNumber *n in t.shape) shape.push_back(n.longLongValue);
            shapeStorage.push_back(shape);
            std::vector<int64_t> &shapeRef = shapeStorage.back();

            const void *rawPtr = t.data.length > 0 ? t.data.bytes : (const void *)&sEmptyTensorByte;
            switch (t.dtype) {
                case VieNeuV3DTypeFloat32: {
                    size_t count = t.data.length / sizeof(float);
                    inputValues.push_back(Ort::Value::CreateTensor<float>(
                        memInfo, const_cast<float *>((const float *)rawPtr), count, shapeRef.data(), shapeRef.size()));
                    break;
                }
                case VieNeuV3DTypeInt64: {
                    size_t count = t.data.length / sizeof(int64_t);
                    inputValues.push_back(Ort::Value::CreateTensor<int64_t>(
                        memInfo, const_cast<int64_t *>((const int64_t *)rawPtr), count, shapeRef.data(), shapeRef.size()));
                    break;
                }
                case VieNeuV3DTypeInt32: {
                    size_t count = t.data.length / sizeof(int32_t);
                    inputValues.push_back(Ort::Value::CreateTensor<int32_t>(
                        memInfo, const_cast<int32_t *>((const int32_t *)rawPtr), count, shapeRef.data(), shapeRef.size()));
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

        NSMutableArray<VieNeuV3Tensor *> *result = [NSMutableArray arrayWithCapacity:outputs.size()];
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
                [result addObject:[[VieNeuV3Tensor alloc] initWithName:name dtype:VieNeuV3DTypeFloat32 shape:shape data:data]];
            } else if (elemType == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) {
                size_t count = info.GetElementCount();
                NSData *data = [NSData dataWithBytes:v.GetTensorData<int64_t>() length:count * sizeof(int64_t)];
                [result addObject:[[VieNeuV3Tensor alloc] initWithName:name dtype:VieNeuV3DTypeInt64 shape:shape data:data]];
            } else if (elemType == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32) {
                size_t count = info.GetElementCount();
                NSData *data = [NSData dataWithBytes:v.GetTensorData<int32_t>() length:count * sizeof(int32_t)];
                [result addObject:[[VieNeuV3Tensor alloc] initWithName:name dtype:VieNeuV3DTypeInt32 shape:shape data:data]];
            } else {
                if (error) {
                    *error = [NSError errorWithDomain:@"VieNeuV3OnnxSession" code:2
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
