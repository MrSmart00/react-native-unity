package expo.modules.unityembed

import android.content.Context
import android.graphics.Color
import android.util.Log
import android.view.ViewGroup
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.views.ExpoView

/**
 * The surface Unity draws into.
 *
 * It owns no state and takes no props. The player's lifetime belongs to
 * [UnityHost] (Unity is a process singleton), so this view only ever attaches
 * the player's own FrameLayout to itself. A recycled view simply re-attaches.
 */
class UnityEmbedView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
  /**
   * ⚠️ Load-bearing, and its absence fails in total silence.
   *
   * ExpoView defaults this to false, meaning React Native drives layout — and RN
   * only lays out children it knows about. Unity's view is added natively, so it
   * never gets measured: it stays 0×0, its SurfaceView never receives a surface,
   * and the engine never starts.
   *
   * What that looks like: a black screen, no exception, no Unity log beyond
   * `Context Type: ActivityOrService`, and a host that sits in `handshaking…`
   * until it times out. Nothing points at layout.
   */
  override val shouldUseAndroidLayout = true

  init {
    setBackgroundColor(Color.BLACK)
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()

    val activity = appContext.currentActivity
    if (activity == null) {
      Log.e(TAG, "no current Activity — Unity cannot be created")
      return
    }

    val unityView = UnityHost.ensureFrameLayout(activity)

    // The player's view can still be attached to a previous host view (or to the
    // Activity, if it was warmed up there). Detach before re-parenting rather
    // than letting addView throw.
    (unityView.parent as? ViewGroup)?.removeView(unityView)

    addView(
      unityView,
      0,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )
    unityView.requestFocus()

    // The window may already have focus by the time we attach, in which case no
    // callback is coming and Unity would wait forever for one.
    if (hasWindowFocus()) UnityHost.setWindowFocus(true)
  }

  /**
   * Forwards the focus change the embedding otherwise swallows. See
   * [UnityHost.setWindowFocus] — without this the player never starts rendering
   * and says nothing about it.
   */
  override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
    super.onWindowFocusChanged(hasWindowFocus)
    UnityHost.setWindowFocus(hasWindowFocus)
  }

  private companion object {
    const val TAG = "UnityEmbed"
  }
}
