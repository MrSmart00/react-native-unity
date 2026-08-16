// Expo looks for this file when the app lists the package name in
// `app.json` → `plugins`. Everything the native side needs from the host build
// is configured from here, so a consuming app only writes:
//
//   "plugins": ["@mrsmart00/react-native-unity"]
module.exports = require('./plugin');
