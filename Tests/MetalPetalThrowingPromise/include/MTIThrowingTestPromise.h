#import <Foundation/Foundation.h>
#import "MetalPetal.h"

NS_ASSUME_NONNULL_BEGIN

/// A promise whose resolution throws a C++ `std::out_of_range`.
///
/// Exists so the render graph's exception guard can be tested for the
/// thing it is actually for: a C++ exception thrown deep inside
/// resolution must not unwind into the caller. It cannot be written in
/// Swift — Swift cannot throw a C++ exception — so it lives in its own
/// ObjC++ target.
@interface MTIThrowingTestPromise : NSObject <MTIImagePromise>
@end

NS_ASSUME_NONNULL_END
