#import "Catching.h"
#import <objc/message.h>

BOOL FBSendCatching(id target, SEL selector, id argument, intptr_t *result, NSString **reason) {
    @try {
        // Typed as returning an integer so ARC leaves an init's +1 alone for the caller to take over.
        *result = ((intptr_t (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
        return YES;
    } @catch (NSException *exception) {
        if (reason) { *reason = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]; }
        return NO;
    }
}
