import type { ExpoConfig } from "expo/config";

/**
 * Expo config.
 *
 * The watchOS target is *not* an Expo module — watchOS has no React Native
 * renderer, so the watch app is native SwiftUI added to the generated Xcode
 * project (see `watch/README.md`). Prebuild generates `ios/`; the watch target
 * is checked in beside it and attached by the config plugin.
 */
const config: ExpoConfig = {
  name: "RelayForge",
  slug: "relayforge",
  version: "0.1.0",
  orientation: "portrait",
  userInterfaceStyle: "automatic",
  scheme: "relayforge",
  ios: {
    bundleIdentifier: "dev.relayforge.app",
    supportsTablet: false,
    infoPlist: {
      // The runner is reached over plain HTTP on the local network during
      // pairing — the one hop that happens before there is a shared key.
      // Everything after it is end-to-end encrypted over the relay.
      NSAppTransportSecurity: { NSAllowsLocalNetworking: true },
      NSLocalNetworkUsageDescription:
        "RelayForge pairs with the runner on your own network. After pairing it talks over the relay instead.",
    },
  },
  android: {
    package: "dev.relayforge.app",
  },
  plugins: [
    "expo-secure-store",
    [
      "expo-build-properties",
      {
        // Same reasoning as the iOS entry above: pairing is one plain-HTTP hop
        // to a runner on the local network, before there is a key to encrypt
        // with. Everything after it goes over the relay, sealed.
        android: { usesCleartextTraffic: true },
      },
    ],
  ],
};

export default config;
