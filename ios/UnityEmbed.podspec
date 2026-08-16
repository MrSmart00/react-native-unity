# Where the consuming app keeps its Unity export.
#
# ⚠️ Anchored on the app being installed into, NOT on where this package sits.
#
# The obvious `../../../unity/builds/ios` counts directory levels up out of
# node_modules, which is only correct when the package was installed the plain
# way — it breaks under npm workspaces, `file:` links, pnpm, and anything else
# that changes the nesting. `installation_root` is the app's ios/ directory
# whatever the layout, so its parent is the app.
unless File.directory?(File.join(__dir__, 'vendor', 'UnityFramework.xcframework'))
  raise <<~MSG
    [@mrsmart00/react-native-unity] ios/vendor/UnityFramework.xcframework is missing.

    Run `npx react-native-unity-export ios` from the app directory before
    `npx expo prebuild` / `pod install`. That builds the app's Unity project and
    stages the framework here.

    This stops rather than warns on purpose: a pod that quietly installs without
    the framework produces an app that builds and launches with no game in it.
  MSG
end

Pod::Spec.new do |s|
  s.name           = 'UnityEmbed'
  s.version        = '0.1.0'
  s.summary        = 'Hosts a Unity as a Library player inside a React Native app'
  s.description    = s.summary
  s.author         = 'MrSmart00'
  s.license        = { :type => 'MIT', :file => '../LICENSE' }
  s.homepage       = 'https://github.com/MrSmart00/react-native-unity'
  s.platforms      = { :ios => '16.4' }
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # ⚠️ NOT the template's "**/*" glob.
  #
  # `vendor/UnityFramework.xcframework` is created below, under this directory,
  # and a recursive glob walks into it and hands CocoaPods every header Unity
  # ships. The build then fails somewhere inside the engine's own headers, which
  # reads as "our code is broken" rather than "the glob is too wide". Keep this
  # non-recursive; all of this pod's sources are flat.
  s.source_files = '*.{h,m,mm,swift}'

  # The app owns its Unity build — a shared package must not carry one game's
  # engine — but CocoaPods resolves `vendored_frameworks` against the pod root
  # and will not follow a path outside it. So the framework is *staged* here,
  # into this pod, from the app's unity/builds/ios/.
  #
  # ⚠️ `react-native-unity-export` does that staging, NOT a podspec `prepare_command`.
  # CocoaPods runs prepare_command when it downloads a pod's source; for a pod
  # referenced by :path — which is every npm-installed Expo module — it does not
  # run on subsequent installs. Relying on it produced a pod with no vendor/
  # directory at all.
  #
  # The same script then runs `pod install`, which is what actually gets the new
  # framework into the .app: re-exporting without it leaves the OLD one there,
  # silently, because Xcode runs `[CP] Copy XCFrameworks` but skips
  # `[CP] Embed Pods Frameworks`.
  s.vendored_frameworks = 'vendor/UnityFramework.xcframework'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Unity's simulator slice is arm64-only (the project's build script sets
    # simulatorSdkArchitecture = ARM64, because Unity's x86_64 default cannot run
    # on an Apple Silicon Mac at all). The config plugin sets this on the app
    # project and in the Podfile too; all three are needed because CocoaPods
    # regenerates Pods.xcodeproj. Only reachable in a Release build — Debug
    # builds the active architecture only.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'x86_64',
  }
end
