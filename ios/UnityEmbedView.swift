import ExpoModulesCore

/**
 The surface Unity draws into.

 It owns no state and takes no props. The player's lifetime belongs to
 `UnityHost` (Unity is a process singleton), so this view only ever attaches the
 engine's root view to itself. That makes Fabric's view recycling harmless — a
 recycled view simply re-attaches — instead of something that has to be detected
 and paused around.
 */
class UnityEmbedView: ExpoView {
  /// Unity boots asynchronously; its root view does not exist for the first
  /// fraction of a second after `runEmbedded`. 20 × 0.25s = 5s of patience.
  private static let maxAttachRetries = 20
  private var attachRetries = 0

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    backgroundColor = .black
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil else { return }
    attachRetries = 0
    attach()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // ⚠️ Unity's root view has to keep a non-zero size for the app's lifetime.
    // A zero-sized Metal layer is not a layout bug, it is
    // `MTLTextureDescriptor has width of zero` and the process dies.
    for subview in subviews {
      subview.frame = bounds
    }
  }

  private func attach() {
    guard let root = UnityHost.shared.startAndGetRootView() else {
      guard attachRetries < Self.maxAttachRetries else {
        NSLog("[UnityEmbed] Unity produced no root view after 5s — the player did not boot")
        return
      }
      attachRetries += 1
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        guard let self, self.window != nil else { return }
        self.attach()
      }
      return
    }

    guard root.superview !== self else { return }
    root.frame = bounds
    addSubview(root)
    setNeedsLayout()
  }
}
