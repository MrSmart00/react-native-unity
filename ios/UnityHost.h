#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/**
 Everything that touches UnityFramework, behind an interface Swift can see.

 ⚠️ Do NOT `#import <UnityFramework/...>` in this header.

 The pod defines a module, so this header ends up in its umbrella. Importing
 UnityFramework here would drag the engine's headers into the Swift module build
 for every file in the pod. It would also not help: UnityFramework's umbrella
 exposes UnityAppController but not the plugin sources under Assets/Plugins/iOS,
 so `UnityEmbedFrameworkAPI` is not visible to Swift no matter what. All of that
 stays in UnityHost.mm, which looks the class up by name at runtime.
 */
NS_ASSUME_NONNULL_BEGIN

@interface UnityHost : NSObject

/// Process-wide, because the Unity player is process-wide.
@property (class, readonly) UnityHost *shared;

/// Called on every message Unity sends up. Set by the Expo module.
@property (nonatomic, copy, nullable) void (^onMessage)(NSString *message);

/// Boots the player if it is not already running, and returns its root view.
/// Returns nil while Unity is still coming up — call again shortly.
- (nullable UIView *)startAndGetRootView;

- (void)send:(NSString *)gameObject method:(NSString *)method message:(NSString *)message;
- (void)setActive:(BOOL)active;

@end

NS_ASSUME_NONNULL_END
