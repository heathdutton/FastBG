#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Sends `selector` to `target` with one object argument inside @try, for private frameworks whose exceptions Swift
/// can't catch. On success `result` holds the raw return register: an object from an init at +1, or an int. On an
/// exception it returns NO and `reason` says why.
BOOL FBSendCatching(id target, SEL selector, id _Nullable argument, intptr_t *result,
                    NSString * _Nullable * _Nullable reason);

NS_ASSUME_NONNULL_END
