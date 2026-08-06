/** Anything that went wrong handling a key, an envelope, or a pairing code. */
export class CryptoError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CryptoError";
  }
}
