import { requireNativeView } from 'expo';
import type { ViewProps } from 'react-native';

/**
 * The surface Unity draws into.
 *
 * Intentionally dumb: it owns no state and takes no commands. The player's
 * lifetime belongs to the module (Unity is a process singleton), so this view
 * only ever attaches or re-attaches the engine's own view to itself. That makes
 * Fabric's view recycling harmless — a recycled view just re-attaches — instead
 * of something that has to be detected and paused around.
 *
 * Do not add props here. Layout, in particular, is fixed by `UnityStage` in
 * `src/unity/bridge.tsx`: a zero-sized parent is a native crash, not a layout
 * bug, so it must not be reachable from application code.
 */
const NativeView = requireNativeView<ViewProps>('UnityEmbed');

export default NativeView;
