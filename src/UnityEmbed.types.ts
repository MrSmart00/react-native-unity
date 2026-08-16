/**
 * Events the module emits.
 *
 * Deliberately emitted by the **module**, not by the view.
 *
 * Unity is a process singleton, so its messages belong to the process, not to
 * whichever view happens to be mounted. Routing them through a view is what
 * forces a native module to keep a static reference to the current view, null it
 * on drop, resolve surface ids, and re-post onto the UI thread — several hundred
 * lines that exist only to undo a routing decision. Emitting from the module
 * skips all of it, and makes view recycling a non-event.
 */
export type UnityEmbedModuleEvents = {
  onUnityMessage: (params: { message: string }) => void;
};
