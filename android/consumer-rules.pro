# Unity reaches this class by name over JNI:
#
#   new AndroidJavaClass("expo.modules.unityembed.UnityHostBridge")
#       .CallStatic("sendMessageToHost", message);
#
# Both strings are resolved at runtime, so R8 has no reference to follow and will
# rename or remove the class in a minified Release build. Nothing fails loudly
# when it does: the app builds, launches, renders the game, and never receives
# another message from Unity.
-keep class expo.modules.unityembed.UnityHostBridge { *; }
