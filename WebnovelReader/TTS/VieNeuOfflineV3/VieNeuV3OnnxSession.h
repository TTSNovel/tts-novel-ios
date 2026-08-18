#ifndef VieNeuV3OnnxSession_h
#define VieNeuV3OnnxSession_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VieNeuV3DType) {
    VieNeuV3DTypeFloat32,
    VieNeuV3DTypeInt64,
    VieNeuV3DTypeInt32,
};

/// One named ONNX tensor, dtype-tagged, raw bytes in `data` (native-endian,
/// tightly packed — 4 bytes/element for every dtype here). Used for BOTH
/// feeds and fetches so `VieNeuV3OnnxSession` stays a single generic
/// "run this graph with these named tensors" method — the v3-turbo engine
/// (VieNeuV3OnnxEngine.swift) drives 4 different graphs (prefill,
/// decode_step, acoustic_cached, MOSS codec decode) through the exact same
/// entry point instead of one bespoke wrapper per graph.
@interface VieNeuV3Tensor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) VieNeuV3DType dtype;
@property (nonatomic, copy) NSArray<NSNumber *> *shape;
@property (nonatomic, strong) NSData *data;

/// Plain designated initializer — Swift bridges this predictably as
/// `VieNeuV3Tensor(name:dtype:shape:data:)`, unlike an Obj-C class-method
/// factory whose selector doesn't happen to start with the class name (the
/// only pattern the Swift importer turns into a callable initializer).
- (instancetype)initWithName:(NSString *)name
                        dtype:(VieNeuV3DType)dtype
                        shape:(NSArray<NSNumber *> *)shape
                         data:(NSData *)data;
@end

@interface VieNeuV3OnnxSession : NSObject

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                            intraOpThreads:(int)threads
                                     error:(NSError **)error;

/// Runs the graph once. `outputNames` selects + orders the returned
/// tensors (mirrors Python's positional `session.run(None, feed)` output
/// order by asking for outputs in that same declared order explicitly,
/// rather than relying on an implicit "all outputs" default).
- (nullable NSArray<VieNeuV3Tensor *> *)runWithInputs:(NSArray<VieNeuV3Tensor *> *)inputs
                                            outputNames:(NSArray<NSString *> *)outputNames
                                                  error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif
