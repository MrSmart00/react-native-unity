#import "UnityEmbedNativeCalls.h"

static id<UnityEmbedNativeCallsProtocol> sHost = nil;

@implementation UnityEmbedFrameworkAPI

+ (void)registerAPIforNativeCalls:(id<UnityEmbedNativeCallsProtocol>)api
{
    sHost = api;
}

@end

extern "C" {

/// Called from C# — see `NativeAPI` in UnityEmbedNative.cs.
///
/// ⚠️ This name is half of a contract that the compiler cannot check: the other
/// half is the `[DllImport("__Internal")]` declaration in UnityEmbedNative.cs. Rename
/// one and the link fails at build time on device, but in the Editor nothing
/// happens at all, because the DllImport is compiled out there.
///
/// A message sent before the host has registered is dropped. That is expected
/// and is why the host polls rather than waiting for a single hello — Unity's
/// Start() can run before the native view has registered itself, in which case
/// whatever it announced went into a nil receiver.
void UnityEmbedSendMessageToHost(const char *message)
{
    if (sHost == nil || message == NULL) return;
    [sHost sendMessageToMobileApp:[NSString stringWithUTF8String:message]];
}

}
