#import <Foundation/Foundation.h>

// The Unity → host channel on iOS. There is no other one.
//
// Written here rather than copied from a third-party package or from Unity's
// uaal-example, so the project owns it outright and carries no licence question
// for twenty lines of Objective-C.
//
// How the two halves find each other:
//
//   * This file is compiled **into UnityFramework** (Unity puts everything under
//     Assets/Plugins/iOS/ there). `UnityEmbedFrameworkAPI` is therefore a symbol
//     that lives inside the framework.
//   * The host module does NOT import this header. It looks the class up with
//     NSClassFromString(@"UnityEmbedFrameworkAPI") and calls
//     registerAPIforNativeCalls: through a selector, passing an object that
//     responds to -sendMessageToMobileApp:.
//
// ⚠️ Which means the class name and that selector are the entire contract. If
// this file ever stops being compiled into UnityFramework, the lookup returns
// nil and Unity → host messages vanish with no error anywhere — the app builds,
// launches, and renders perfectly. The host treats a nil lookup as fatal for
// exactly that reason.
//
// `visibility("default")` is required: without it the class is not exported from
// the framework and NSClassFromString cannot find it.

@protocol UnityEmbedNativeCallsProtocol <NSObject>
@required
- (void)sendMessageToMobileApp:(NSString *)message;
@end

__attribute__((visibility("default")))
@interface UnityEmbedFrameworkAPI : NSObject
+ (void)registerAPIforNativeCalls:(id<UnityEmbedNativeCallsProtocol>)api;
@end
