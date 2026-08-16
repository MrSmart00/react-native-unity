package expo.modules.unityembed

import android.app.Activity
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.FrameLayout
import com.unity3d.player.IUnityPlayerLifecycleEvents
import com.unity3d.player.UnityPlayer
import com.unity3d.player.UnityPlayerForActivityOrService

/**
 * Owns the Unity player. Process-wide, because Unity is.
 *
 * ⚠️ This is deliberately much smaller than the equivalent in the third-party
 * libraries, and the difference is worth understanding before "restoring" any of
 * it.
 *
 * Those libraries reach `UnityPlayer` through reflection — locating the class by
 * name, picking a constructor by signature, calling `getFrameLayout` and `setZ`
 * through `Method` objects — because they support many Unity versions at once,
 * and Unity renamed `UnityPlayer` to `UnityPlayerForActivityOrService` in
 * Unity 6. This project pins one Unity version (see
 * unity/game/ProjectSettings/ProjectVersion.txt), and `javap` on the exported
 * `unity-classes.jar` confirms every member used here is public:
 *
 *     public UnityPlayerForActivityOrService(Context, IUnityPlayerLifecycleEvents)
 *     public static void UnityPlayer.UnitySendMessage(String, String, String)
 *     public void pause(); resume(); getFrameLayout()
 *
 * So it compiles directly. If the Unity version is ever raised, re-run that
 * javap before assuming this still holds.
 */
object UnityHost : IUnityPlayerLifecycleEvents {
  private const val TAG = "UnityEmbed"

  private var player: UnityPlayerForActivityOrService? = null

  /** Boots the player if needed and returns the view Unity renders into. */
  fun ensureFrameLayout(activity: Activity): FrameLayout {
    player?.let { return it.frameLayout }

    // Unity renders through a SurfaceView; without an explicit pixel format the
    // window can end up in a configuration that composites the surface wrong.
    activity.window.setFormat(PixelFormat.RGBA_8888)

    val created = UnityPlayerForActivityOrService(activity, this)
    player = created
    created.resume()
    return created.frameLayout
  }

  /**
   * ⚠️ Not queued. A message sent before the player has booted is dropped with
   * no exception and no log line. The host polls rather than relying on this.
   */
  fun send(gameObject: String, method: String, message: String) {
    UnityPlayer.UnitySendMessage(gameObject, method, message)
  }

  /**
   * Entering or leaving the game screen.
   *
   * ⚠️ Forced onto the main thread. Expo Modules dispatches `Function` bodies
   * onto the module's own queue, so calls arriving from JavaScript are not on the
   * main thread — and Unity's lifecycle calls are main-thread-only. On iOS the
   * same mistake killed the process with SIGTRAP on the *second* pause/resume,
   * with no crash report and nothing pointing at threading.
   */
  fun setActive(active: Boolean) = onMainThread {
    val current = player ?: return@onMainThread
    if (active) current.resume() else current.pause()
  }

  private inline fun onMainThread(crossinline block: () -> Unit) {
    if (Looper.myLooper() == Looper.getMainLooper()) block()
    else Handler(Looper.getMainLooper()).post { block() }
  }

  /**
   * ⚠️ Required, and its absence fails silently.
   *
   * In the standard Unity-as-a-Library setup the host Activity forwards
   * `onWindowFocusChanged` to the player — that is how Unity learns it may
   * render. Embedding the player in a view instead means nobody forwards it: the
   * Activity's callback goes to React Native's, and Unity is never told.
   *
   * The result is a player that constructs fine, gets a real SurfaceView, and
   * then does nothing. Its log stops after `Context Type: ActivityOrService`,
   * the screen stays black, and no error is produced anywhere.
   *
   * So [UnityEmbedView] forwards the event it actually receives. This is not the
   * speculative `windowFocusChanged(true)` that gets added to "fix" frozen warm
   * transitions — it is the callback the embedding removed, put back where it
   * belongs.
   */
  fun setWindowFocus(hasFocus: Boolean) {
    player?.windowFocusChanged(hasFocus)
  }

  override fun onUnityPlayerUnloaded() {
    Log.w(TAG, "onUnityPlayerUnloaded — nothing in this app unloads the player")
    player = null
  }

  override fun onUnityPlayerQuitted() {
    Log.w(TAG, "onUnityPlayerQuitted — the player cannot be revived in this process")
    player = null
  }
}
