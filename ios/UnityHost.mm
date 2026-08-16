#import "UnityHost.h"

#import <UnityFramework/UnityFramework.h>
#include <dlfcn.h>
#include <mach-o/loader.h>

/**
 The receiving half of the Unity → host channel.
 *
 Declared here rather than imported from the Unity project, because
 `UnityEmbedNativeCalls.h` is compiled into UnityFramework and is not part of its
 umbrella — there is nothing to import. Only the selector matters: the sender
 calls it dynamically.

 The name differs from the Unity-side protocol on purpose, so the two
 declarations can never collide in one translation unit.
 */
@protocol UnityEmbedHostCalls <NSObject>
- (void)sendMessageToMobileApp:(NSString *)message;
@end

@interface UnityHost () <UnityEmbedHostCalls, UnityFrameworkListener>
@property (nonatomic, strong, nullable) UnityFramework *ufw;
@end

/**
 The Mach-O header of whichever image this code was linked into.

 ⚠️ Not `&_mh_execute_header`, which is what every Unity-as-a-Library guide
 says.

 That symbol only exists in a main executable. Xcode links a Debug build's app
 code into `<app>.debug.dylib` instead, so referencing it there fails at link
 time with:

     Undefined symbols for architecture arm64:
       "__mh_execute_header", referenced from: -[UnityHost boot]

 The conventional fix is `#ifdef DEBUG` picking `_mh_dylib_header` — but that
 encodes a guess about which configurations use a debug dylib. Asking dyld where
 this function actually lives answers the real question directly, and stays
 correct if Xcode changes its mind.
 */
/// Returns UnityFramework's own `MachHeader` typedef (mach_header_64 on device
/// and simulator alike), so the result drops straight into setExecuteHeader:.
/**
 Runs a block on the main thread, immediately if we are already there.

 ⚠️ Every entry point that touches the player needs this. Expo Modules dispatches
 `Function` bodies onto the module's own queue, so calls arriving from JavaScript
 are NOT on the main thread — and Unity's lifecycle calls are main-thread-only.

 What happens without it: the console prints
 `Warning: Calling UnityPause functions should be done on the main thread!`
 and the app survives the first pause/resume. The second one kills the process
 with SIGTRAP, and no crash report is written. It reads as "re-entering the game
 screen crashes", which points nowhere near threading.
 */
static void OnMainThread(dispatch_block_t block)
{
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static const MachHeader *HostImageHeader(void)
{
    Dl_info info = {};
    if (dladdr((const void *)&HostImageHeader, &info) == 0 || info.dli_fbase == NULL) return NULL;
    return (const MachHeader *)info.dli_fbase;
}

@implementation UnityHost

+ (UnityHost *)shared
{
    static UnityHost *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[UnityHost alloc] init]; });
    return shared;
}

#pragma mark - boot

- (nullable UIView *)startAndGetRootView
{
    if (self.ufw == nil) [self boot];

    // Unity finishes coming up asynchronously; for the first fraction of a
    // second after runEmbedded there is no root view yet. The caller retries.
    return self.ufw.appController.rootView;
}

- (void)boot
{
    NSString *path = [[NSBundle mainBundle].bundlePath
                      stringByAppendingString:@"/Frameworks/UnityFramework.framework"];
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    if (bundle == nil) {
        [NSException raise:@"UnityEmbed"
                    format:@"UnityFramework.framework is not in the app bundle. "
                            "Run scripts/export-unity.sh ios, then rebuild."];
    }
    if (!bundle.isLoaded) [bundle load];

    UnityFramework *ufw = [bundle.principalClass getInstance];

    // Points the engine at the Mach-O header of the image hosting it. See
    // HostImageHeader() for why this is not the &_mh_execute_header every guide
    // shows.
    if (![ufw appController]) [ufw setExecuteHeader:HostImageHeader()];

    // ⚠️ Pairs with PostProcessIOS.cs moving `Data` into UnityFramework. Unity
    // looks for its Data inside the bundle named here; with only one of the two
    // in place it dies at startup with
    //   Could not open .../Data/Managed/Metadata/global-metadata.dat
    [ufw setDataBundleId:bundle.bundleIdentifier.UTF8String];

    [ufw registerFrameworkListener:self];

    static const char *argv[] = { "unity", NULL };
    [ufw runEmbeddedWithArgc:1 argv:(char **)argv appLaunchOpts:@{}];

    // The player is embedded and never allowed to take the app down with it: the
    // host keeps the view mounted for the app's lifetime, so a quit would make
    // every later session impossible.
    ufw.appController.quitHandler = ^{};

    [self detachFromUnitysOwnWindow:ufw];
    [self registerForNativeCalls];

    self.ufw = ufw;
}

/**
 Unity creates its own UIWindow and makes it key, which would put the engine on
 top of the entire React Native UI. Take the root view away from it and hide the
 window; from here on the view hierarchy is ours.
 */
- (void)detachFromUnitysOwnWindow:(UnityFramework *)ufw
{
    UIView *root = ufw.appController.rootView;
    [root removeFromSuperview];

    UIWindow *window = ufw.appController.window;
    window.hidden = YES;
    if (@available(iOS 13.0, *)) window.windowScene = nil;
}

/**
 Hands ourselves to the class Unity exports as its callback target.

 ⚠️ The single most dangerous failure in this whole integration lives here.

 `UnityEmbedFrameworkAPI` is compiled from
 unity/game/Assets/Plugins/iOS/UnityEmbedNativeCalls.mm into UnityFramework. If
 those sources ever stop being compiled into the framework, this lookup returns
 nil — and everything else still works. The app builds with no warning, launches,
 renders the game, and simply never receives a single message from Unity.

 So: raise. A missing channel must not be survivable.
 */
- (void)registerForNativeCalls
{
    Class proxy = NSClassFromString(@"UnityEmbedFrameworkAPI");
    if (proxy == nil) {
        [NSException raise:@"UnityEmbed"
                    format:@"UnityEmbedFrameworkAPI is not in UnityFramework. "
                            "Assets/Plugins/iOS/UnityEmbedNativeCalls.mm was not compiled "
                            "into the framework — re-run scripts/export-unity.sh ios. "
                            "Without it Unity can never talk back to React Native."];
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [proxy performSelector:@selector(registerAPIforNativeCalls:) withObject:self];
#pragma clang diagnostic pop
}

#pragma mark - messaging

- (void)send:(NSString *)gameObject method:(NSString *)method message:(NSString *)message
{
    // No queue on the Unity side: sending before the player is up drops the
    // message silently. The host polls rather than relying on this.
    OnMainThread(^{
        [self.ufw sendMessageToGOWithName:gameObject.UTF8String
                            functionName:method.UTF8String
                                 message:message.UTF8String];
    });
}

/// Called by UnityEmbedNativeCalls.mm, on Unity's thread.
- (void)sendMessageToMobileApp:(NSString *)message
{
    void (^handler)(NSString *) = self.onMessage;
    if (handler == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(message); });
}

- (void)setActive:(BOOL)active
{
    OnMainThread(^{ [self.ufw pause:!active]; });
}

#pragma mark - UnityFrameworkListener

- (void)unityDidUnload:(NSNotification *)notification
{
    // Logged rather than surfaced: nothing in the app unloads the player, so
    // this arriving means something unexpected happened and the next thing to
    // look at is who called it.
    NSLog(@"[UnityEmbed] unityDidUnload");
    self.ufw = nil;
}

- (void)unityDidQuit:(NSNotification *)notification
{
    NSLog(@"[UnityEmbed] unityDidQuit — the player cannot be revived in this process");
    self.ufw = nil;
}

@end
