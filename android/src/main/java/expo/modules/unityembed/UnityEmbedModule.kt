package expo.modules.unityembed

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import kotlinx.coroutines.launch

/**
 * Hosts the Unity player and carries messages both ways.
 *
 * The module — not the view — owns the player and emits its events, because
 * Unity is a process singleton and its messages belong to the process. Routing
 * them through a view instead is what forces a native module to keep a static
 * reference to the current view, null it on drop, resolve surface ids, and
 * re-post onto the UI thread; none of that is needed here.
 */
class UnityEmbedModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("UnityEmbed")

    Events("onUnityMessage")

    OnCreate {
      // Calls arrive on Unity's thread; hop to the main thread before emitting.
      UnityHostBridge.sink = { message ->
        appContext.mainQueue.launch {
          sendEvent("onUnityMessage", mapOf("message" to message))
        }
      }
    }

    OnDestroy {
      UnityHostBridge.sink = null
    }

    Function("send") { gameObject: String, method: String, message: String ->
      UnityHost.send(gameObject, method, message)
    }

    Function("setActive") { active: Boolean ->
      UnityHost.setActive(active)
    }

    // The app going to the background must pause the player too, not just the
    // host leaving the game screen — otherwise Unity keeps rendering off-screen.
    OnActivityEntersForeground {
      UnityHost.setActive(true)
    }

    OnActivityEntersBackground {
      UnityHost.setActive(false)
    }

    View(UnityEmbedView::class) {}
  }
}
