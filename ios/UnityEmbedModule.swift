import ExpoModulesCore

/**
 Hosts the Unity player and carries messages both ways.

 The module — not the view — owns the player and emits its events, because Unity
 is a process singleton and its messages belong to the process. Routing them
 through a view instead is what forces a native module to keep a static
 reference to the current view, null it on drop, resolve surface ids, and re-post
 onto the UI thread; none of that is needed here.

 Everything that touches UnityFramework lives in `UnityHost.mm`. See the note in
 `UnityHost.h` for why that boundary is where it is.
 */
public class UnityEmbedModule: Module {
  public func definition() -> ModuleDefinition {
    Name("UnityEmbed")

    Events("onUnityMessage")

    OnCreate {
      UnityHost.shared.onMessage = { [weak self] message in
        self?.sendEvent("onUnityMessage", ["message": message])
      }
    }

    Function("send") { (gameObject: String, method: String, message: String) in
      UnityHost.shared.send(gameObject, method: method, message: message)
    }

    Function("setActive") { (active: Bool) in
      UnityHost.shared.setActive(active)
    }

    View(UnityEmbedView.self) {}
  }
}
