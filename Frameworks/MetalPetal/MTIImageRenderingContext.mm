//
//  MTIImageRenderingContext.m
//  Pods
//
//  Created by YuAo on 25/06/2017.
//
//

#import "MTIImageRenderingContext+Internal.h"
#import "MTIContext+Internal.h"
#import "MTIImage+Promise.h"
#import "MTIError.h"
#import "MTIPrint.h"
#import "MTIRenderGraphOptimization.h"
#import "MTIImagePromiseDebug.h"

#include <unordered_map>
#include <exception>
#include <vector>
#include <memory>
#include <cstdint>

namespace MTIImageRendering {
    struct ObjcPointerIdentityEqual {
        bool operator()(const id s1, const id s2) const {
            return (s1 == s2);
        }
    };
    struct ObjcPointerHash {
        size_t operator()(const id pointer) const {
            auto addr = reinterpret_cast<uintptr_t>(pointer);
            #if SIZE_MAX < UINTPTR_MAX
            addr %= SIZE_MAX; /* truncate the address so it is small enough to fit in a size_t */
            #endif
            return addr;
        }
    };
};

class MTIImageRenderingDependencyGraph {
    
private:
    typedef std::vector<__unsafe_unretained id<MTIImagePromise>> UnsafeUnretainedImagePromises;
    std::unordered_map<__unsafe_unretained id<MTIImagePromise>, std::shared_ptr<UnsafeUnretainedImagePromises>, MTIImageRendering::ObjcPointerHash, MTIImageRendering::ObjcPointerIdentityEqual> _promiseDenpendentsCountTable;
    
public:
    
    void addDependenciesForImage(MTIImage *image) {
        auto dependencies = image.promise.dependencies;
        for (MTIImage *dependency in dependencies) {
            auto promise = dependency.promise;
            if (_promiseDenpendentsCountTable.count(promise) == 0) {
                //Using array here, because a promise may have two or more identical dependents.
                _promiseDenpendentsCountTable.insert(std::make_pair(promise, std::make_shared<UnsafeUnretainedImagePromises>(1, image.promise)));
                this -> addDependenciesForImage(dependency);
            } else {
                _promiseDenpendentsCountTable[promise] -> push_back(image.promise);
            }
        }
    }
    
    NSInteger dependentCountForPromise(id<MTIImagePromise> promise) const {
        NSCAssert(_promiseDenpendentsCountTable.count(promise) > 0, @"Promise: %@ is not in this dependency graph.", promise);
        //NSCAssert compiles out under NS_BLOCK_ASSERTIONS, so in a release
        //build `.at()` was the only thing between a promise that has left
        //the graph and an uncaught std::out_of_range, which terminates the
        //process rather than surfacing an error. A promise absent from the
        //graph has nothing depending on it, so reporting zero lets the
        //caller release its render target - exactly what this count decides.
        auto entry = _promiseDenpendentsCountTable.find(promise);
        if (entry == _promiseDenpendentsCountTable.end() || entry -> second == nullptr) {
            return 0;
        }
        return entry -> second -> size();
    }
    
    void removeDependentForPromise(id<MTIImagePromise> dependent, id<MTIImagePromise> promise) {
        //find, not operator[]: the subscript DEFAULT-CONSTRUCTS a null
        //shared_ptr for a missing promise and inserts it, after which the
        //null guard below is compiled out in release and the null is
        //dereferenced - and dependentCountForPromise then finds that bogus
        //entry too. Looking up without inserting keeps the table honest.
        auto entry = _promiseDenpendentsCountTable.find(promise);
        NSCAssert(entry != _promiseDenpendentsCountTable.end(), @"Dependents not found.");
        if (entry == _promiseDenpendentsCountTable.end()) {
            return;
        }
        auto dependents = entry -> second;
        NSCAssert(dependents != nullptr, @"Dependents not found.");
        if (dependents == nullptr) {
            return;
        }
        auto index = dependents -> end();
        for (auto i = dependents -> begin(); i != dependents -> end(); ++i) {
            if (*i == dependent) {
                index = i;
                break;
            }
        }
        NSCAssert(index != dependents -> end(), @"Dependent not found in promise's dependents array.");
        if (index != dependents -> end()) {
            dependents -> erase(index);
        }
    }
};

__attribute__((objc_subclassing_restricted))
@interface MTITransientImagePromiseResolution: NSObject <MTIImagePromiseResolution>

@property (nonatomic,copy) void (^invalidationHandler)(id);

@end

@implementation MTITransientImagePromiseResolution

@synthesize texture = _texture;

- (instancetype)initWithTexture:(id<MTLTexture>)texture invalidationHandler:(void (^)(id))invalidationHandler {
    if (self = [super init]) {
        _invalidationHandler = [invalidationHandler copy];
        _texture = texture;
    }
    return self;
}

- (void)markAsConsumedBy:(id)consumer {
    self.invalidationHandler(consumer);
    self.invalidationHandler = nil;
}

- (void)dealloc {
    //Raising here during stack unwinding REPLACES the exception already
    //in flight, so a diagnosable std::out_of_range from the graph
    //arrives at the guard as a bare NSInternalInconsistencyException
    //with the real cause destroyed — and only in debug builds, since
    //NSAssert compiles out under NS_BLOCK_ASSERTIONS. That made the
    //guard's diagnostics worse in debug than in release, which is
    //backwards.
    //
    //Still reported, just not as an exception: an unconsumed resolution
    //is a real leak of a render target and must not pass silently.
    if (self.invalidationHandler != nil) {
        MTIPrint(@"MTITransientImagePromiseResolution deallocated without being consumed — its render target was not released. This is expected only when an exception unwound out of the render graph.");
    }
}

@end

__attribute__((objc_subclassing_restricted))
@interface MTIPersistImageResolutionHolder : NSObject

@property (nonatomic,strong) MTIImagePromiseRenderTarget *renderTarget;

@end

@implementation MTIPersistImageResolutionHolder

- (instancetype)initWithRenderTarget:(MTIImagePromiseRenderTarget *)renderTarget {
    if (self = [super init]) {
        _renderTarget = renderTarget;
        [renderTarget retainTexture];
    }
    return self;
}

- (void)dealloc {
    [_renderTarget releaseTexture];
}

@end

NSString * const MTIContextImagePersistentResolutionHolderTableName = @"MTIContextImagePersistentResolutionHolderTable";

MTIContextImageAssociatedValueTableName const MTIContextImagePersistentResolutionHolderTable = MTIContextImagePersistentResolutionHolderTableName;

@interface MTIImageRenderingContext () {
    std::unordered_map<__unsafe_unretained id<MTIImagePromise>, MTIImagePromiseRenderTarget __strong *, MTIImageRendering::ObjcPointerHash, MTIImageRendering::ObjcPointerIdentityEqual> _resolvedPromises;
    
    MTIImageRenderingDependencyGraph *_dependencyGraph;
    
    std::unordered_map<__unsafe_unretained MTIImage *, __unsafe_unretained id<MTLTexture>, MTIImageRendering::ObjcPointerHash, MTIImageRendering::ObjcPointerIdentityEqual> _currentDependencyResolutionMap;
    
    std::unordered_map<__unsafe_unretained MTIImage *, __unsafe_unretained id<MTLSamplerState>, MTIImageRendering::ObjcPointerHash, MTIImageRendering::ObjcPointerIdentityEqual> _currentDependencySamplerStateMap;
    
    __unsafe_unretained id<MTIImagePromise> _currentResolvingPromise;
    //Set when an exception escaped resolution. The context is then
    //unusable: a command encoder may be open, locals in ObjC (.m)
    //frames have leaked, and the graph is half-built.
    BOOL _graphDidThrow;
}

@end

@interface MTIImageRenderingContext ()
/// `resolutionForImage:error:` without the exception guard — the
/// recursive descent only, which already runs inside the guarded
/// outermost call. Deliberately NOT in the shared internal header: an
/// explicitly unguarded way into the render graph is not something
/// another translation unit should be able to reach for.
- (nullable id<MTIImagePromiseResolution>)unguardedResolutionForImage:(MTIImage *)image error:(NSError **)error;
@end

@implementation MTIImageRenderingContext

- (void)dealloc {
    delete _dependencyGraph;
    
    //Do NOT commit after an escaped exception. Kernels create a render
    //command encoder and call back into this context to resolve their
    //inputs (MTIRenderPipelineKernel), with no @try around endEncoding —
    //so an exception caught in resolutionForImage: leaves an encoder
    //open on this command buffer. Committing one with an uncommitted
    //encoder makes Metal abort, which would turn a survivable render
    //failure into a crash in dealloc with no stack relationship to the
    //cause.
    if (_graphDidThrow) {
        return;
    }
    if (self.commandBuffer.status == MTLCommandBufferStatusNotEnqueued || self.commandBuffer.status == MTLCommandBufferStatusEnqueued) {
        [self.commandBuffer commit];
    }
}

- (instancetype)initWithContext:(MTIContext *)context {
    if (self = [super init]) {
        _context = context;
        _commandBuffer = [context.commandQueue commandBuffer];
        _dependencyGraph = NULL;
    }
    return self;
}

- (id<MTLTexture>)resolvedTextureForImage:(MTIImage *)image {
    auto promise = _currentResolvingPromise;
    NSAssert(promise != nil, @"");
    //find, not operator[]: the subscript default-constructs and INSERTS
    //an entry for a missing image, growing the map and leaving a key
    //that will dangle (the same bug fixed in removeDependentForPromise).
    auto entry = _currentDependencyResolutionMap.find(image);
    auto result = entry == _currentDependencyResolutionMap.end() ? nil : entry -> second;
    if (!result || !promise) {
        [NSException raise:NSInternalInconsistencyException format:@"Do not query resolved texture for image which is not the current resolving promise's dependency. (Promise: %@, Image: %@)", promise, image];
    }
    return result;
}

- (id<MTLSamplerState>)resolvedSamplerStateForImage:(MTIImage *)image {
    auto promise = _currentResolvingPromise;
    NSAssert(promise != nil, @"");
    //find, not operator[]: the subscript default-constructs and INSERTS
    //an entry for a missing image, growing the map and leaving a key
    //that will dangle (the same bug fixed in removeDependentForPromise).
    auto entry = _currentDependencySamplerStateMap.find(image);
    auto result = entry == _currentDependencySamplerStateMap.end() ? nil : entry -> second;
    if (!result || !promise) {
        [NSException raise:NSInternalInconsistencyException format:@"Do not query resolved sampler state for image which is not the current resolving promise's dependency. (Promise: %@, Image: %@)", promise, image];
    }
    return result;
}

//Every caller of this library is Swift, and a C++ exception unwinding
//through Swift frames is undefined behaviour — the process terminates
//rather than surfacing an error. So nothing may be allowed to throw out
//of the render graph, and the catch has to live HERE, in ObjC++, because
//Swift cannot catch it and MTIContext+Rendering.m is not compiled as C++.
//
//This is the floor, not a specific fix: the known case was std::map::at()
//on a promise that had left the graph (see dependentCountForPromise), and
//that one now returns instead of throwing. This guard means the NEXT
//promise-lifetime bug anywhere in the graph costs a dropped frame and an
//NSError rather than a crash. Seen in the field as a fatal
//St12out_of_range during visualizer preset switching
//(SlimController #414).
//
//SCOPE, three things this deliberately does NOT do:
//
// 1. It does not catch NSException. On the 64-bit runtime objc_exception_throw
//    uses the Itanium C++ ABI, so `catch (...)` WOULD swallow one — including
//    this library's own deliberate programmer-error traps (nil image below,
//    the resolved-texture inconsistency checks, MTITexturePool's
//    over-release detector). Those are assertions about caller misuse and
//    must keep killing the process, so they are rethrown unchanged.
// 2. It does not catch Swift runtime traps (fatalError, bounds checks,
//    forced unwraps). Those are not exceptions at all — they are ud2/abort
//    and no handler sees them.
// 3. It is SURVIVE-ONCE, not a per-frame safety net. ObjC (.m) translation
//    units compile with -fno-objc-arc-exceptions by default, and every
//    promise and kernel in this library is .m — so an exception unwinding
//    through them leaks their strong locals permanently, including
//    MTIReusableTextures that then never return to the pool. One caught
//    exception is a dropped frame; one per frame is a texture leak. The
//    context marks itself poisoned so it cannot be reused, and the
//    MTIPrint below is there so the condition is visible in the field
//    rather than silently absorbed.
//
//Guarded at the OUTERMOST call only: the recursive descent below calls
//the unguarded variant. Not for speed — table-driven EH is zero-cost on
//the non-throwing path — but because catching per node would turn one
//real exception into N nested generic errors and bury the origin.
- (id<MTIImagePromiseResolution>)resolutionForImage:(MTIImage *)image error:(NSError * __autoreleasing *)inOutError {
    //Above the guard: a nil image is caller misuse, and the raise below
    //is load-bearing — the next statement dereferences image.promise.
    if (image == nil) {
        [NSException raise:NSInvalidArgumentException format:@"%@: Application is requesting a resolution of a nil image.", self];
    }
    try {
        return [self unguardedResolutionForImage:image error:inOutError];
    } catch (NSException *exception) {
        //An ObjC programmer-error trap. Keep its old behaviour exactly.
        @throw exception;
    } catch (const std::exception &exception) {
        [self markGraphAsThrownWithReason:[NSString stringWithUTF8String:exception.what()] error:inOutError];
        return nil;
    } catch (...) {
        [self markGraphAsThrownWithReason:@"unknown C++ exception" error:inOutError];
        return nil;
    }
}

/// Record that an exception escaped resolution: poison the context,
/// name the promise that was resolving, and report.
- (void)markGraphAsThrownWithReason:(NSString *)reason error:(NSError * __autoreleasing *)inOutError {
    //The promise that was mid-resolution is the single most useful fact
    //for a field report, and it is still here at catch time. The normal
    //root-image failure path prints the same way.
    id<MTIImagePromise> failing = _currentResolvingPromise;
    NSString *description = [NSString stringWithFormat:@"A C++ exception escaped the render graph: %@ (resolving: %@)", reason, failing ?: @"<none>"];
    MTIPrint(@"%@", description);
    _currentResolvingPromise = nil;
    _graphDidThrow = YES;
    if (inOutError) {
        NSDictionary *userInfo = @{NSLocalizedDescriptionKey: description};
        *inOutError = MTIErrorCreate(MTIErrorRenderGraphException, userInfo);
    }
}

- (id<MTIImagePromiseResolution>)unguardedResolutionForImage:(MTIImage *)image error:(NSError * __autoreleasing *)inOutError {
    BOOL isRootImage = NO;
    id<MTIImagePromise> promise = image.promise;
    
    if (!_dependencyGraph) {
        //If we don't have the dependency graph, we're processing the root image.
        isRootImage = YES;
        
        _dependencyGraph = new MTIImageRenderingDependencyGraph();
        if (self.context.isRenderGraphOptimizationEnabled) {
            id<MTIImagePromise> optimizedPromise = [MTIRenderGraphOptimizer promiseByOptimizingRenderGraphOfPromise:promise];
            promise = optimizedPromise;
            
            MTIImage *optimizedImage = [[MTIImage alloc] initWithPromise:optimizedPromise samplerDescriptor:image.samplerDescriptor cachePolicy:image.cachePolicy];
            _dependencyGraph -> addDependenciesForImage(optimizedImage);
        } else {
            _dependencyGraph -> addDependenciesForImage(image);
        }
    }
    
    MTIImagePromiseRenderTarget *renderTarget = nil;
    if (_resolvedPromises.count(promise) > 0) {
        renderTarget = _resolvedPromises.at(promise);
        //Do not need to retain the render target, because it is created or retained during in this rendering context from location [A] or [B].
        //Promise resolved.
        NSAssert(renderTarget != nil, @"");
        NSAssert(renderTarget.texture != nil, @"");
    } else {
        //Maybe the context has a resolved promise. (The image has a persistent cache policy)
        renderTarget = [self.context renderTargetForPromise:promise];
        if ([renderTarget retainTexture]) {
            //Got the render target from the context, we need to retain the texture here, texture ref-count +1. [A]
            //If we don't retain the texture, there will be an over-release error at location [C].
            //The cached render target is valid.
            NSAssert(renderTarget != nil, @"");
            NSAssert(renderTarget.texture != nil, @"");
        } else {
            //All caches miss. Resolve promise.
            NSError *error = nil;
            
            if (promise.dimensions.width > 0 && promise.dimensions.height > 0 && promise.dimensions.depth > 0) {
                
                NSUInteger dependencyCount = promise.dependencies.count;
                
                id<MTIImagePromiseResolution> inputResolutions[dependencyCount];
                memset(inputResolutions, 0, sizeof inputResolutions);
                
                id<MTLSamplerState> inputSamplerStates[dependencyCount];
                memset(inputSamplerStates, 0, sizeof inputSamplerStates);
                
                std::unordered_map<__unsafe_unretained MTIImage *, __unsafe_unretained id<MTLTexture>, MTIImageRendering::ObjcPointerHash, MTIImageRendering::ObjcPointerIdentityEqual> textureMap;
                
                std::unordered_map<__unsafe_unretained MTIImage *, __unsafe_unretained id<MTLSamplerState>, MTIImageRendering::ObjcPointerHash, MTIImageRendering::ObjcPointerIdentityEqual> samplerStateMap;
                
                for (NSUInteger index = 0; index < dependencyCount; index += 1) {
                    MTIImage *image = promise.dependencies[index];
                    id<MTIImagePromiseResolution> resolution = [self unguardedResolutionForImage:image error:&error];
                    if (error) {
                        break;
                    }
                    NSAssert(resolution != nil, @"");
                    inputResolutions[index] = resolution;
                    textureMap[image] = resolution.texture;
                    
                    id<MTLSamplerState> samplerState = [self.context samplerStateWithDescriptor:image.samplerDescriptor error:&error];
                    if (error) {
                        break;
                    }
                    NSAssert(samplerState != nil, @"");
                    inputSamplerStates[index] = samplerState;
                    samplerStateMap[image] = samplerState;
                }
                
                if (!error) {
                    _currentDependencyResolutionMap = textureMap;
                    _currentDependencySamplerStateMap = samplerStateMap;
                    
                    _currentResolvingPromise = promise;
                    
                    renderTarget = [promise resolveWithContext:self error:&error];
                    //New render target got from promise resolving, texture ref-count is 1. [B]
                    
                    _currentResolvingPromise = nil;
                }
                
                for (NSUInteger index = 0; index < dependencyCount; index += 1) {
                    [inputResolutions[index] markAsConsumedBy:promise];
                }
            } else {
                error = MTIErrorCreate(MTIErrorInvalidTextureDimension, nil);
            }
            
            if (error) {
                if (inOutError) {
                    *inOutError = error;
                }
                
                //Failed. Release texture if we got the render target.
                [renderTarget releaseTexture];
                
                if (isRootImage) {
                    MTIPrint(@"An error occurred while resolving promise: %@ for image: %@.\n%@",promise,image,error);
                    //Clean up
                    for (auto entry : _resolvedPromises) {
                        if (_dependencyGraph -> dependentCountForPromise(entry.first) != 0) {
                            [entry.second releaseTexture];
                        }
                    }
                }
                
                return nil;
            }
            
            //Make sure the render target is valid.
            NSAssert(renderTarget != nil, @"");
            NSAssert(renderTarget.texture != nil, @"");
            
            if (image.cachePolicy == MTIImageCachePolicyPersistent) {
                //Share the render result with the context.
                [self.context setRenderTarget:renderTarget forPromise:promise];
            }
        }
        _resolvedPromises[promise] = renderTarget;
    }
    
    if (image.cachePolicy == MTIImageCachePolicyPersistent) {
        MTIPersistImageResolutionHolder *persistResolution = [self.context valueForImage:image inTable:MTIContextImagePersistentResolutionHolderTable];
        if (!persistResolution) {
            //Create a holder for the render taget. Retain the texture. Preventing the texture from being reused at location [C]
            //When the MTIPersistImageResolutionHolder deallocates, it releases the texture.
            persistResolution = [[MTIPersistImageResolutionHolder alloc] initWithRenderTarget:renderTarget];
            [self.context setValue:persistResolution forImage:image inTable:MTIContextImagePersistentResolutionHolderTable];
        }
    }
    
    if (isRootImage) {
        return [[MTITransientImagePromiseResolution alloc] initWithTexture:renderTarget.texture invalidationHandler:^(id consumer) {
            //Root render result is consumed, releasing the texture.
            [renderTarget releaseTexture];
        }];
    } else {
        return [[MTITransientImagePromiseResolution alloc] initWithTexture:renderTarget.texture invalidationHandler:^(id consumer){
            self -> _dependencyGraph -> removeDependentForPromise(consumer, promise);
            if (self -> _dependencyGraph -> dependentCountForPromise(promise) == 0) {
                //Nothing depends on this render result, releasing the texture. [C]
                [renderTarget releaseTexture];
            }
        }];
    }
}

@end


__attribute__((objc_subclassing_restricted))
@interface MTIImageBufferPromise: NSObject <MTIImagePromise>

@property (nonatomic, strong, readonly) MTIPersistImageResolutionHolder *resolution;

@property (nonatomic, weak, readonly) MTIContext *context;

@end

@implementation MTIImageBufferPromise

@synthesize dimensions = _dimensions;
@synthesize alphaType = _alphaType;

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (NSArray<MTIImage *> *)dependencies {
    return @[];
}

- (instancetype)initWithPersistImageResolutionHolder:(MTIPersistImageResolutionHolder *)holder dimensions:(MTITextureDimensions)dimensions alphaType:(MTIAlphaType)alphaType context:(MTIContext *)context {
    if (self = [super init]) {
        _dimensions = dimensions;
        _alphaType = alphaType;
        _resolution = holder;
        _context = context;
    }
    return self;
}

- (MTIImagePromiseRenderTarget *)resolveWithContext:(MTIImageRenderingContext *)renderingContext error:(NSError * __autoreleasing *)error {
    MTIContext *context = self.context;
    NSParameterAssert(renderingContext.context == context);
    if (renderingContext.context != context) {
        if (error) {
            *error = MTIErrorCreate(MTIErrorCrossContextRendering, nil);
        }
        return nil;
    }
    [_resolution.renderTarget retainTexture];
    return _resolution.renderTarget;
}


- (instancetype)promiseByUpdatingDependencies:(NSArray<MTIImage *> *)dependencies {
    NSParameterAssert(dependencies.count == 0);
    return self;
}

- (MTIImagePromiseDebugInfo *)debugInfo {
    return [[MTIImagePromiseDebugInfo alloc] initWithPromise:self type:MTIImagePromiseTypeSource content:self.resolution];
}

@end


@implementation MTIContext (RenderedImageBuffer)

- (MTIImage *)renderedBufferForImage:(MTIImage *)targetImage {
    NSParameterAssert(targetImage.cachePolicy == MTIImageCachePolicyPersistent);
    MTIPersistImageResolutionHolder *persistResolution = [self valueForImage:targetImage inTable:MTIContextImagePersistentResolutionHolderTable];
    if (!persistResolution) {
        return nil;
    }
    return [[MTIImage alloc] initWithPromise:[[MTIImageBufferPromise alloc] initWithPersistImageResolutionHolder:persistResolution dimensions:targetImage.dimensions alphaType:targetImage.alphaType context:self] samplerDescriptor:targetImage.samplerDescriptor cachePolicy:MTIImageCachePolicyPersistent];
}

@end
