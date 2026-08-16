# @mrsmart00/react-native-unity

Embed a Unity player inside a React Native (Expo) app, using Unity's own
Unity as a Library support. No third-party bridge library underneath.

```
React Native screen ──[mount]──▶ Unity renders ⇄ messages both ways
```

> [!NOTE]
> The scope in the name is not decoration — the unscoped `react-native-unity`
> is an unrelated package on npm.

---

## What it does

- Hosts the Unity player in a React Native view, on iOS and Android
- Carries messages in both directions
- Pauses and resumes the player
- Applies, as an Expo config plugin, the native build settings that
  `expo prebuild` would otherwise wipe
- Exports your Unity project into the app with a single command

## What it deliberately does not do

These are properties of embedding Unity, not gaps to be filled later.

- **One player per process.** Unity does not support more.
- **The view cannot be unmounted.** Doing so unloads the player, and a player
  cannot be recreated in the same process.
- **`display: none` is not available either.** A zero-sized parent kills the app
  natively with `MTLTextureDescriptor has width of zero`.
- **There is no API to quit the player.** Quitting would make every later
  session impossible, so it is not exposed.

---

## Verified against

| | |
|---|---|
| Unity | 6000.3.22f1 (Unity 6.3 LTS) |
| Expo SDK | 57 |
| React Native | 0.86 |
| Xcode | 26 |
| Platforms | iOS Simulator, Android emulator (arm64) |

**Not yet verified on physical devices**, and exercised by one real app so far.
Treat 0.x as exactly that. Reports from other Unity versions and real hardware
are the most useful thing you can contribute.

Unity **6 or newer is required**: the Android sources compile directly against
`UnityPlayerForActivityOrService` rather than reaching it by reflection. The
export command checks for it and fails with a clear message on older engines.

---

## Requirements

- Unity 6+, with iOS and Android Build Support installed
- An **arm64-v8a** Android emulator, unless you widen `architectures` (below)
- A licensed Unity Editor. Activating a Personal licence needs the Unity Hub
  GUI — that is the one step of this pipeline that cannot be automated.

## Install

```bash
npm install @mrsmart00/react-native-unity
```

Three pieces of configuration in your app:

```jsonc
// package.json
"dependencies": { "@mrsmart00/react-native-unity": "^0.1.0" },
"unityEmbed":   { "project": "../unity" }   // where your Unity project lives

// app.json
"plugins": ["@mrsmart00/react-native-unity"]
```

Then export **before** prebuilding:

```bash
npx react-native-unity-export all   # ios | android | all
npx expo prebuild --clean
```

The export command:

1. Copies this package's Unity-side sources into your Unity project, reporting
   anything that changed
2. Builds your Unity project in batch mode into `<app>/unity/builds/{ios,android}/`
3. On iOS, stages the framework into the pod and **runs `pod install`**

> [!IMPORTANT]
> Step 3's `pod install` is not optional. Skip it and the build succeeds with the
> *previous* Unity framework still inside the `.app` — see
> [Stale engine keeps running](#stale-engine-keeps-running). The command runs it
> for you because an instruction in a README does not survive contact with a
> deadline.

### Plugin options

Defaults are what this package was verified with. Override only what you need:

```jsonc
"plugins": [
  ["@mrsmart00/react-native-unity", { "architectures": ["arm64-v8a", "x86_64"] }]
]
```

| Option | Default | Why you might change it |
|---|---|---|
| `architectures` | `["arm64-v8a"]` | The default means **x86_64 emulators cannot run your app**. Must match what Unity exported — shipping an ABI Unity did not build leaves the engine `.so` missing at runtime |
| `minSdkVersion` | `25` | Unity 6.3 refuses API 24 and exports `unityLibrary` at 25. Raise it if your Unity does |
| `gradleJvmArgs` | `-Xmx6144m -XX:MaxMetaspaceSize=2048m` | Linking `unityLibrary` alongside React Native's native build exceeds Gradle's defaults. Lower it on a small CI box at your own risk |
| `minifyRelease` | `true` | R8 is on so the ProGuard rule protecting the JNI bridge is actually exercised. See [Messages stop in one direction](#messages-stop-in-one-direction) |
| `overrideBackInvokedCallback` | `true` | Resolves a manifest-merger conflict on `android:enableOnBackInvokedCallback`. Turn off if your app never sets it |

Everything else the plugin writes is **required** for Unity as a Library to work
and is not configurable: `unityStreamingAssets`, `expo.useLegacyPackaging`, the
`unity.*` properties carried over from the export, the `:unityLibrary` Gradle
include, and the simulator architecture exclusions.

---

## Usage

### Unity side

The export copies in `UnityEmbedNative.cs` and the iOS native path. This package
provides **transport only** — the GameObject name, the receiving method, and
what any message means are yours to choose.

```csharp
public sealed class MyBridge : MonoBehaviour
{
    public const string ObjectName = "MyBridge";          // host addresses this
    public const string MessageMethod = "OnHostMessage";  // and calls this

    // Host → Unity. UnitySendMessage fixes the shape: one string, looked up by name.
    public void OnHostMessage(string payload) { /* dispatch it yourself */ }

    // Unity → host.
    void Reply(string json) => UnityEmbedNative.Send(json);
}
```

Create that GameObject with `DontDestroyOnLoad`, from a
`[RuntimeInitializeOnLoadMethod]` or your first scene.

### Host side

```tsx
import { UnityEmbedModule, UnityEmbedView } from '@mrsmart00/react-native-unity';

// Unity's surface. The parent must already have a size.
<UnityEmbedView style={StyleSheet.absoluteFill} />

// Host → Unity
UnityEmbedModule.send('MyBridge', 'OnHostMessage', JSON.stringify({ action: 'PING' }));

// Unity → host
UnityEmbedModule.addListener('onUnityMessage', ({ message }) => { /* ... */ });

// Pause on the way out, or Unity keeps burning CPU behind your UI
UnityEmbedModule.setActive(false);
```

> [!TIP]
> Do not call these from your screens. Put a facade in your app that owns the
> handshake, the outbound queue, and the pause/resume calls, and let screens talk
> to that. It keeps Unity's vocabulary out of your UI code and gives you one file
> to change if this package ever does something you disagree with.

#### About the handshake

`UnitySendMessage` has **no queue**. Anything sent before the player has booted
is dropped without an exception, a log line, or any other trace.

The reverse also drops: Unity's `Start()` can run before the native view has
registered as the receiver, so a single "I'm ready" message from Unity can
vanish. **Waiting for one specific hello therefore waits forever**, in a case
that really happens.

What works: poll. Send a probe every ~250ms and treat **any** inbound message as
proof the channel is live. Give up after ~10s with a loud error — polling forever
renders as "still starting up", which is indistinguishable from a dead player.

---

## Pitfalls

Embedding Unity fails in a particular way: **the build succeeds, nothing warns,
and one capability is silently dead.** Everything below was hit for real. Guards
against them carry the reasoning in comments — read those before deleting code
whose purpose is not obvious.

### Messages stop in one direction

| Cause | What you see |
|---|---|
| `UnityEmbedNativeCalls.mm` did not get compiled into UnityFramework | The app builds, launches, and renders perfectly, and **not one message ever arrives from Unity**. The host raises if `NSClassFromString` comes back nil — that check is the only real guard |
| R8 renamed or removed `UnityHostBridge` | Same silence. Unity looks the class up from a string, so R8 cannot see the reference. `consumer-rules.pro` keeps it, and `minifyRelease` defaults to on so the rule is actually tested |
| The C function name and the `DllImport` disagree | **Nothing checks this.** The DllImport is compiled out in the Editor, so the Editor cannot reveal it either |

### The player never starts, or never draws

| Cause | What you see |
|---|---|
| `ExpoView.shouldUseAndroidLayout` left at its default | React Native only lays out children it knows about, so Unity's view stays 0×0, its SurfaceView never gets a surface, and the engine never starts. **Black screen, no exception**; Unity's log stops after `Context Type: ActivityOrService` |
| `onWindowFocusChanged` never forwarded | Embedding means the Activity's callback belongs to React Native, so Unity is never told it may render. The player constructs fine and gets a real SurfaceView, then does nothing — **indistinguishable from the row above**, so check for the SurfaceView first |

```bash
adb shell dumpsys SurfaceFlinger --list | grep SurfaceView
```

### Crashes on launch, or on the second entry

| Cause | What you see |
|---|---|
| `Data` not moved into UnityFramework | `global-metadata.dat` cannot be opened and IL2CPP fails to initialise. Pairs with the host calling `setDataBundleId:` — one without the other fails the same way |
| Unity's lifecycle API called off the main thread | **Expo Modules runs `Function` bodies on the module's own queue.** The first pause/resume survives; **the second kills the process with SIGTRAP and writes no crash report.** The only clue is a Unity warning that goes to stderr, not `os_log` |

```bash
xcrun simctl launch --console-pty <device> <bundle-id>
```

### Stale engine keeps running

Re-export Unity, rebuild, and the **old** framework is still inside the `.app`.
Xcode runs `[CP] Copy XCFrameworks` but skips `[CP] Embed Pods Frameworks`, and
nothing warns. This is why the export command runs `pod install` itself.

To check what actually shipped, compare **Mach-O UUIDs — not sha256**. Xcode
re-signs the framework when it embeds it, so the bytes never match and a hash
check would cry wolf on every build until you stopped believing it.

```bash
dwarfdump --uuid "$(xcrun simctl get_app_container booted <bundle-id>)"/Frameworks/UnityFramework.framework/UnityFramework
```

### Only reproducible in Release

`EXCLUDED_ARCHS[sdk=iphonesimulator*]=x86_64` is set in **three** places — the
app project, the Podfile, and this podspec — because CocoaPods regenerates
`Pods.xcodeproj` after the app project is configured. Debug builds only the
active architecture, so this class of failure **cannot appear there**. Verify in
Release.

### Unity's managed stripping

Raising `ManagedStrippingLevel` can break **Android while iOS stays fine on the
same settings** — Unity's built-in GUISkin is reached through resources, which
the stripper cannot see. If you raise it, weigh binary size against runtime
failure and re-test both platforms.

---

## Developing this package

When linked into an app from outside its `node_modules` — a `file:` dependency,
a workspace, a local checkout — five layers break. **None of this affects people
who install it normally**, which is exactly why it is easy to ship broken.

| Layer | Fix |
|---|---|
| Shell | `BASH_SOURCE` points at the `.bin` symlink. Resolve it before deriving the package root |
| CocoaPods | **`prepare_command` cannot be relied on** — for a `:path` pod it does not run on later installs. Staging is done by the export command instead |
| TypeScript | `preserveSymlinks` in the app's tsconfig |
| Config plugin | Try a plain `require`, fall back to resolving from the app |
| Metro | Add the app's `node_modules` to `nodeModulesPaths`. **Do not add `disableHierarchicalLookup: true`** as the monorepo recipe suggests — nested dependencies npm did not hoist then stop resolving |

The package itself keeps the shape of a normal install; every workaround above
lives in the consuming app, so nothing developer-specific ships to users.

---

## Background

This package came out of a spike comparing Unity and Godot for embedding in
React Native, and the measurements behind its design decisions are recorded in
[ablaze-lion#3](https://github.com/MrSmart00/ablaze-lion/pull/3).

## License

MIT
