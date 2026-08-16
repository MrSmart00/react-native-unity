const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');

/**
 * `expo/config-plugins`, resolved from the app rather than from here.
 *
 * A plain top-level require works when this package is installed the normal way,
 * inside the app's node_modules. It fails when the package is linked in from
 * outside it — a `file:` dependency, a workspace, a local checkout — because
 * Node then looks for `expo` next to the package's real path, where it is not
 * installed. That is exactly how this package is consumed while being developed.
 *
 * A config plugin always runs inside an app that has expo, so anchoring on the
 * app is the more truthful resolution in both layouts.
 */
function configPlugins(projectRoot) {
  try {
    return require('expo/config-plugins');
  } catch {
    return createRequire(path.join(projectRoot, 'package.json'))('expo/config-plugins');
  }
}

/**
 * Defaults for the settings an app is allowed to override.
 *
 * The split matters: some of what this plugin writes is required for Unity as a
 * Library to work at all, and some of it is just a sensible policy. Only the
 * policy is configurable — forcing the requirements is the whole point of
 * shipping a plugin rather than a page of setup instructions.
 *
 * Required, and therefore NOT options:
 *   unityStreamingAssets           unityLibrary reads it at configuration time
 *   expo.useLegacyPackaging        Unity loads its .so by path, not from the APK
 *   unity.* (merged from export)   without them :unityLibrary:buildIl2Cpp dies
 *   include ':unityLibrary'        the module would not resolve
 *   EXCLUDED_ARCHS (three places)  Unity's simulator slice is arm64-only
 */
const DEFAULTS = {
  /**
   * ABIs the app builds. Must match what Unity exported: shipping an ABI Unity
   * did not build means the engine .so is simply missing at runtime.
   *
   * ⚠️ The default excludes x86_64, so x86_64 emulators cannot run the app. That
   * is a real cost, which is why it is an option rather than a fact of life.
   */
  architectures: ['arm64-v8a'],

  /**
   * Unity 6.3 refuses API 24 ("obsolete, will become an error") and exports
   * unityLibrary at 25. A library requiring a higher minSdk than the app fails
   * manifest merging, so the app has to move too. Raise it if your Unity does.
   */
  minSdkVersion: 25,

  /**
   * Linking unityLibrary alongside React Native's own native build blows past
   * Gradle's defaults. The failure is the unhelpful "What went wrong: Metaspace"
   * with no indication of which module caused it. Lower it on a small CI box at
   * your own risk.
   */
  gradleJvmArgs: '-Xmx6144m -XX:MaxMetaspaceSize=2048m',

  /**
   * R8 on in Release, deliberately.
   *
   * Unity reaches `UnityHostBridge` by name over JNI, so R8 cannot see the
   * reference and would rename or drop the class. This package ships a consumer
   * ProGuard rule keeping it — but a rule that never runs is a rule nobody knows
   * is wrong. Leaving minification off means shipping an untested path and
   * finding out in a store build, where the symptom is "Unity stopped talking"
   * with no error anywhere.
   */
  minifyRelease: true,

  /**
   * Let the app's `android:enableOnBackInvokedCallback` win over unityLibrary's.
   *
   * Unity exports its manifest with the attribute set to true. If the app sets
   * it too — Expo does when `predictiveBackGestureEnabled` is configured — the
   * merger treats the disagreement as a hard error. Turn this off if your app
   * never sets the attribute.
   */
  overrideBackInvokedCallback: true,
};

/**
 * Every build-side setting the Unity embedding needs on top of a stock Expo
 * prebuild. Shipped with the package so a consuming app only writes:
 *
 *   "plugins": ["@mrsmart00/react-native-unity"]
 *
 * ...or, to override a default:
 *
 *   "plugins": [["@mrsmart00/react-native-unity", { "architectures": ["arm64-v8a", "x86_64"] }]]
 *
 * All paths below are resolved against the *app* — the exported Unity artefacts
 * belong to the app, not to this package, because they are that app's game.
 *
 * Lives in a plugin rather than in android/ by hand because `expo prebuild
 * --clean` regenerates the native projects and would drop anything edited there.
 *
 * Everything here is load-bearing and most of it fails in a way that does not
 * look like its cause. See the package README before removing any of it.
 */
module.exports = function withUnityBuild(config, options = {}) {
  const opts = { ...DEFAULTS, ...options };

  const {
    withAndroidManifest,
    withDangerousMod,
    withGradleProperties,
    withSettingsGradle,
    withXcodeProject,
  } = configPlugins(config._internal?.projectRoot ?? process.cwd());

  let result = withGradleProperties(config, (cfg) => {
    const set = (key, value) => {
      const existing = cfg.modResults.find((item) => item.type === 'property' && item.key === key);
      if (existing) existing.value = value;
      else cfg.modResults.push({ type: 'property', key, value });
    };

    // Configurable — see DEFAULTS for what each one costs.
    set('org.gradle.jvmargs', opts.gradleJvmArgs);
    set('reactNativeArchitectures', opts.architectures.join(','));
    set('android.minSdkVersion', String(opts.minSdkVersion));

    // unityLibrary/build.gradle reads unity.* properties — NDK path, ABI
    // filters, SDK levels — that Unity writes into the gradle.properties at the
    // root of its export. We only vendor the unityLibrary and shared modules, so
    // those properties have to be carried over or the IL2CPP task dies with
    // "Could not get unknown property 'unity.androidNdkPath'".
    //
    // react-native-unity-export extracts them to unity.properties next to the
    // module. Not committed: several are absolute paths into this machine's
    // Unity installation.
    for (const [key, value] of Object.entries(readUnityProperties(cfg.modRequest.projectRoot))) {
      set(key, value);
    }

    // unityLibrary's manifest declares android:extractNativeLibs="true" — Unity
    // loads libunity.so and libil2cpp.so by path and needs them on disk, not
    // mapped out of the APK. Without legacy packaging the merger only warns and
    // the app builds, so this would surface as a runtime load failure.
    set('expo.useLegacyPackaging', 'true');

    // Configurable — see DEFAULTS.
    set('android.enableMinifyInReleaseBuilds', String(opts.minifyRelease));

    // unityLibrary's build.gradle computes its `noCompress` list from this:
    //   androidResources { noCompress = [...] + unityStreamingAssets.tokenize(', ') }
    // Undefined, the module fails at configuration time.
    set('unityStreamingAssets', '.unity3d');

    return cfg;
  });

  result = withExcludedSimulatorArch(result, withXcodeProject);
  result = withPodfileExcludedArch(result, withDangerousMod);
  if (opts.overrideBackInvokedCallback) {
    result = withBackInvokedCallbackOverride(result, withAndroidManifest);
  }
  result = withUnityLibraryModule(result, withSettingsGradle);
  return result;
};

/**
 * Puts the exported Unity module on the Gradle build.
 *
 * Nothing is copied — Gradle just records the path — so re-exporting Unity is
 * picked up by the next build with no further step. This package's android/
 * module then depends on `:unityLibrary`, and throws a readable error if this
 * is missing.
 *
 * `shared/` next to it needs no `include`: unityLibrary/build.gradle reaches it
 * with a relative `apply from:`. It does need to be *present*, which is
 * the export script's job.
 */
function withUnityLibraryModule(config, withSettingsGradle) {
  return withSettingsGradle(config, (cfg) => {
    if (cfg.modResults.contents.includes("':unityLibrary'")) return cfg;
    cfg.modResults.contents += `
include ':unityLibrary'
project(':unityLibrary').projectDir = new File(rootDir, '../unity/builds/android/unityLibrary')
`;
    return cfg;
  });
}

/**
 * Lets the app's `android:enableOnBackInvokedCallback` win over unityLibrary's.
 *
 * app.json sets predictiveBackGestureEnabled: false; Unity exports its manifest
 * with the attribute set to true. The merger treats that as a hard error:
 *
 *   Attribute application@enableOnBackInvokedCallback value=(false)
 *   is also present at [:unityLibrary] value=(true).
 *
 * Overriding here rather than stripping it from the exported manifest keeps the
 * decision on the host side, where it belongs — the app owns its back
 * behaviour, and the exported module is an artefact we should not be editing
 * more than necessary.
 */
function withBackInvokedCallbackOverride(config, withAndroidManifest) {
  return withAndroidManifest(config, (cfg) => {
    const manifest = cfg.modResults.manifest;
    manifest.$['xmlns:tools'] ??= 'http://schemas.android.com/tools';
    const application = manifest.application?.[0];
    if (!application) throw new Error('no <application> in AndroidManifest');
    application.$['tools:replace'] = [application.$['tools:replace'], 'android:enableOnBackInvokedCallback']
      .filter(Boolean)
      .join(',');
    return cfg;
  });
}

function readUnityProperties(projectRoot) {
  const file = path.join(projectRoot, 'unity', 'builds', 'android', 'unity.properties');
  if (!fs.existsSync(file)) {
    // Not fatal: `expo prebuild` legitimately runs before the first export (and
    // on the iOS-only path). The Android build is what fails, loudly, if this
    // never gets written.
    console.warn(
      '[react-native-unity] unity/builds/android/unity.properties not found — ' +
        'run `npx react-native-unity-export android` before building for Android.',
    );
    return {};
  }
  return Object.fromEntries(
    fs
      .readFileSync(file, 'utf8')
      .split('\n')
      .filter((line) => line.includes('='))
      .map((line) => {
        const at = line.indexOf('=');
        return [line.slice(0, at).trim(), line.slice(at + 1).trim()];
      }),
  );
}

/**
 * The same x86_64 exclusion, but for the Pods project.
 *
 * withExcludedSimulatorArch below only reaches the app project. CocoaPods
 * generates Pods.xcodeproj afterwards with its own settings, so the pod that
 * links UnityFramework was still being built for `arm64 x86_64` and failed with:
 *
 *   [CP] UnityFramework.xcframework: Unable to find matching slice in
 *   'ios-arm64 ios-arm64-simulator' for the current build architectures
 *   (arm64 x86_64) and platform (-iphonesimulator).
 *
 * ...followed by a misleading `'UnityFramework/UnityFramework.h' file not found`,
 * because the framework was never copied. Debug hides all of this: it builds the
 * active architecture only. **This bug is only reachable in a Release build**,
 * which is why the scaffold has a Release verification step of its own.
 */
function withPodfileExcludedArch(config, withDangerousMod) {
  return withDangerousMod(config, [
    'ios',
    (cfg) => {
      const podfile = path.join(cfg.modRequest.platformProjectRoot, 'Podfile');
      const contents = fs.readFileSync(podfile, 'utf8');
      const marker = 'EXCLUDED_ARCHS[sdk=iphonesimulator*]';
      if (contents.includes(marker)) return cfg;

      const anchor = '    react_native_post_install(';
      if (!contents.includes(anchor)) {
        throw new Error(
          '[react-native-unity] could not find react_native_post_install in the Podfile.\n' +
            'This plugin patches the Podfile by locating that call, so a change to ' +
            "Expo's template breaks it. Your Expo version is probably newer than this " +
            'package has been tested with — please open an issue at ' +
            'https://github.com/MrSmart00/react-native-unity/issues',
        );
      }

      const patch = `    installer.pods_project.targets.each do |target|
      target.build_configurations.each do |config|
        config.build_settings['${marker}'] = 'x86_64'
      end
    end
    installer.pods_project.build_configurations.each do |config|
      config.build_settings['${marker}'] = 'x86_64'
    end
${anchor}`;

      fs.writeFileSync(podfile, contents.replace(anchor, patch));
      return cfg;
    },
  ]);
}

/**
 * UnityFramework.xcframework's simulator slice is arm64-only here — see
 * BuildScript.BuildIOS, which sets simulatorSdkArchitecture to ARM64 because
 * Unity's default of X86_64 cannot run on an Apple Silicon Mac at all. A Release
 * build for the simulator otherwise tries every architecture and dies with
 * `ld: symbol(s) not found for architecture x86_64`.
 *
 * This stays invisible until the first Release build, because Debug only builds
 * the active architecture.
 */
function withExcludedSimulatorArch(config, withXcodeProject) {
  return withXcodeProject(config, (cfg) => {
    const configurations = cfg.modResults.pbxXCBuildConfigurationSection();
    for (const key of Object.keys(configurations)) {
      const buildSettings = configurations[key]?.buildSettings;
      if (!buildSettings) continue;
      buildSettings['"EXCLUDED_ARCHS[sdk=iphonesimulator*]"'] = 'x86_64';
    }
    return cfg;
  });
}
