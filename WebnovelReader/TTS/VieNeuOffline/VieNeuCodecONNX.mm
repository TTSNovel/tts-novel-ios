#import "VieNeuCodecONNX.h"
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <vector>

static NSError *ortError(const char *what, const std::exception &e) {
    NSString *msg = [NSString stringWithFormat:@"%s: %s", what, e.what()];
    return [NSError errorWithDomain:@"VieNeuCodecONNX" code:1
                            userInfo:@{NSLocalizedDescriptionKey: msg}];
}

@implementation VieNeuCodecONNX {
    std::unique_ptr<Ort::Env> _env;
    std::unique_ptr<Ort::Session> _session;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    try {
        _env = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING, "VieNeuCodec");
        Ort::SessionOptions options;
        // Modest thread count: the backbone (VieNeuLlamaBackbone) also runs
        // CPU-bound on this same device around the same time (see its
        // n_gpu_layers=0 doc comment) -- avoid oversubscribing cores.
        options.SetIntraOpNumThreads(2);
        _session = std::make_unique<Ort::Session>(*_env, modelPath.UTF8String, options);
    } catch (const std::exception &e) {
        if (error) *error = ortError("session init failed", e);
        return nil;
    }
    return self;
}

- (nullable NSArray<NSNumber *> *)decodeWithContentIds:(NSArray<NSNumber *> *)contentIds
                                          voiceEmbedding:(NSArray<NSNumber *> *)voiceEmbedding
                                                    error:(NSError **)error {
    try {
        std::vector<int64_t> ids;
        ids.reserve(contentIds.count);
        for (NSNumber *n in contentIds) ids.push_back(n.longLongValue);

        std::vector<float> voice;
        voice.reserve(voiceEmbedding.count);
        for (NSNumber *n in voiceEmbedding) voice.push_back(n.floatValue);

        Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

        std::vector<int64_t> idsShape = {1, (int64_t)ids.size()};
        Ort::Value idsValue = Ort::Value::CreateTensor<int64_t>(
            memInfo, ids.data(), ids.size(), idsShape.data(), idsShape.size());

        std::vector<int64_t> voiceShape = {1, (int64_t)voice.size()};
        Ort::Value voiceValue = Ort::Value::CreateTensor<float>(
            memInfo, voice.data(), voice.size(), voiceShape.data(), voiceShape.size());

        const char *inputNames[] = {"content_ids", "voice_embedding"};
        const char *outputNames[] = {"div_1"};
        Ort::Value inputs[] = {std::move(idsValue), std::move(voiceValue)};

        auto outputs = _session->Run(Ort::RunOptions{nullptr}, inputNames, inputs, 2, outputNames, 1);
        if (outputs.empty()) {
            if (error) {
                *error = [NSError errorWithDomain:@"VieNeuCodecONNX" code:2
                                          userInfo:@{NSLocalizedDescriptionKey: @"no output"}];
            }
            return nil;
        }

        const float *data = outputs[0].GetTensorData<float>();
        size_t count = outputs[0].GetTensorTypeAndShapeInfo().GetElementCount();
        NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:count];
        for (size_t i = 0; i < count; i++) {
            [result addObject:@(data[i])];
        }
        return result;
    } catch (const std::exception &e) {
        if (error) *error = ortError("decode failed", e);
        return nil;
    }
}

@end
