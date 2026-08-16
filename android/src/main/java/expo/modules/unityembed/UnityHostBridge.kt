package expo.modules.unityembed

/**
 * The Unity → host channel on Android.
 *
 * Unity calls [sendMessageToHost] over JNI:
 *
 *     new AndroidJavaClass("expo.modules.unityembed.UnityHostBridge")
 *         .CallStatic("sendMessageToHost", message);
 *
 * ⚠️ Both the class name and the method name are resolved from strings at
 * runtime. Nothing checks them at build time, and R8 cannot see them at all —
 * which is why `consumer-rules.pro` keeps this class. Without that rule the
 * channel dies silently in a minified Release build while everything else keeps
 * working.
 *
 * Calls arrive on Unity's thread. The module hops to the main thread before
 * emitting.
 */
object UnityHostBridge {
  @Volatile
  var sink: ((String) -> Unit)? = null

  @JvmStatic
  fun sendMessageToHost(message: String) {
    sink?.invoke(message)
  }
}
