import { NativeModule, requireNativeModule } from 'expo';

import type { UnityEmbedModuleEvents } from './UnityEmbed.types';

declare class UnityEmbedModule extends NativeModule<UnityEmbedModuleEvents> {
  /**
   * Delivered to Unity via `UnitySendMessage(gameObject, method, message)`.
   *
   * ⚠️ Not queued. A call made before the player has booted is dropped with no
   * error of any kind. Callers should go through `src/unity/bridge.tsx`, which
   * handles that.
   */
  send(gameObject: string, method: string, message: string): void;

  /** Resume (true) or pause (false) the player. */
  setActive(active: boolean): void;
}

export default requireNativeModule<UnityEmbedModule>('UnityEmbed');
