using System.Runtime.InteropServices;
using UnityEngine;

/// <summary>
/// The Unity → host transport. Copy this file, together with
/// Plugins/iOS/UnityEmbedNativeCalls.{h,mm}, into the consuming Unity project —
/// `react-native-unity-export` does that for you and warns when the copies drift.
///
/// Deliberately transport only: it knows how to carry a string out of Unity and
/// nothing about what any string means. The game defines its own MonoBehaviour
/// for that, names it whatever it likes, and calls <see cref="Send"/>.
///
/// The other direction needs nothing from this package: the host calls
/// `UnitySendMessage(gameObject, method, json)`, which Unity delivers to a method
/// on a GameObject of that name. Both names are chosen by the app.
///
/// ⚠️ Two names below are contracts no compiler checks:
///
///   * `UnityEmbedSendMessageToHost` must match the C function exported by
///     Plugins/iOS/UnityEmbedNativeCalls.mm. In the Editor the DllImport is
///     compiled out, so a mismatch is invisible until you build for a device.
///   * `expo.modules.unityembed.UnityHostBridge` / `sendMessageToHost` must match
///     the Kotlin object in this package's android/ sources. It is resolved from
///     a string at runtime and is invisible to R8, which is why the package
///     ships a consumer ProGuard rule keeping it.
/// </summary>
public static class UnityEmbedNative
{
    /// <summary>
    /// Sends one message up to the host.
    ///
    /// A message sent before the host has registered as the receiver is dropped
    /// — silently, by design of the underlying channel. The host side of this
    /// package polls rather than relying on a single hello, so this is safe to
    /// call as early as you like.
    /// </summary>
    public static void Send(string message)
    {
#if UNITY_IOS && !UNITY_EDITOR
        NativeAPI.UnityEmbedSendMessageToHost(message);
#elif UNITY_ANDROID && !UNITY_EDITOR
        using (var bridge = new AndroidJavaClass("expo.modules.unityembed.UnityHostBridge"))
        {
            bridge.CallStatic("sendMessageToHost", message);
        }
#else
        Debug.Log($"[UnityEmbed] (editor) {message}");
#endif
    }
}

/// <summary>
/// The C entry point exported by UnityEmbedNativeCalls.mm. In its own type so
/// the DllImport is not compiled on other platforms.
/// </summary>
public static class NativeAPI
{
#if UNITY_IOS && !UNITY_EDITOR
    [DllImport("__Internal")]
    public static extern void UnityEmbedSendMessageToHost(string message);
#endif
}
