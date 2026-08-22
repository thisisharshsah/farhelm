/**
 * The keys these clients used to store things under.
 *
 * Everything was `forge-` something before the product settled on one name. A
 * browser or a phone that has already paired is holding a device secret under
 * the old key, and that secret is the whole pairing: if a release simply stops
 * looking for it, the device silently becomes a stranger and has to be paired
 * again. Nobody would call that a rename.
 *
 * So a read misses on the new key, tries the old one, and — having found it —
 * writes it forward and drops the old copy. The move happens once, on the first
 * read after the upgrade, and after that there is nothing legacy left on the
 * device.
 *
 * The mirror of `farhelm_app::legacy` on the Rust side, with the same rule: the
 * new key always wins, so a device holding both is never quietly switched back.
 */

/** A store this helper can migrate: the get/set/remove trio every backend has. */
export interface KeyValueBackend {
  get(key: string): Promise<string | null>;
  set(key: string, value: string): Promise<void>;
  remove(key: string): Promise<void>;
}

/**
 * Read `key`, falling back to `legacyKey` and moving the value across.
 *
 * The write-forward is best-effort: a backend that refuses the write (a full
 * quota, a locked keystore) still returns the value, because failing to tidy up
 * is not a reason to tell the caller they are unpaired.
 */
export async function getMigrating(
  backend: KeyValueBackend,
  key: string,
  legacyKey: string,
): Promise<string | null> {
  const current = await backend.get(key);
  if (current !== null && current !== undefined) return current;

  const legacy = await backend.get(legacyKey);
  if (legacy === null || legacy === undefined) return null;

  try {
    await backend.set(key, legacy);
    await backend.remove(legacyKey);
  } catch {
    // Reading is what the caller asked for; relocating was our idea.
  }
  return legacy;
}

/**
 * The synchronous form, for `localStorage`-backed preferences.
 *
 * Preferences are not pairings — losing one costs a theme, not a device. It is
 * still worth carrying across, because a settings screen that resets itself on
 * upgrade reads as a bug whatever it actually cost.
 */
export function getMigratingSync(key: string, legacyKey: string): string | null {
  try {
    const current = localStorage.getItem(key);
    if (current !== null) return current;

    const legacy = localStorage.getItem(legacyKey);
    if (legacy === null) return null;

    localStorage.setItem(key, legacy);
    localStorage.removeItem(legacyKey);
    return legacy;
  } catch {
    // Private mode, or storage disabled outright. A missing preference is a
    // default; a thrown one is a blank screen.
    return null;
  }
}
