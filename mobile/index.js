/**
 * Entry point. The import order here is load-bearing.
 *
 * `react-native-get-random-values` installs `crypto.getRandomValues`, which
 * Hermes does not provide. TweetNaCl looks for it at *module load* and throws
 * "no PRNG" if it is absent — so this has to run before anything reaches
 * `@relayforge/client-core`. It throwing is the good outcome: the alternative
 * would be a key generated from a predictable source, which is indistinguishable
 * from a working app right up until it isn't.
 */
import "react-native-get-random-values";

import { registerRootComponent } from "expo";
import App from "./src/App";

registerRootComponent(App);
