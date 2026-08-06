/**
 * What happens when the runner is not there.
 *
 * The success path is exercised everywhere else. This covers the failure that
 * actually cost an afternoon: a runner at an address nothing is listening on.
 * A TCP connect to a dead host on your own subnet does not fail fast — it hangs
 * for the better part of a minute — and every screen renders a spinner while it
 * does. "Stuck on loading" and "wrong address" look identical from the outside,
 * so the request layer has to draw the distinction itself.
 */

import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError, createRunnerApi } from "./index.ts";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("a runner that does not answer", () => {
  it("gives up rather than hanging, and says what it tried", async () => {
    vi.useFakeTimers();
    // A fetch that never settles — a dead host, not a refused connection.
    vi.stubGlobal(
      "fetch",
      (_url: string, init?: RequestInit) =>
        new Promise((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () =>
            reject(Object.assign(new Error("aborted"), { name: "AbortError" })),
          );
        }),
    );

    const api = createRunnerApi("http://192.168.1.10:7842");
    const pending = api.fleet();
    const assertion = expect(pending).rejects.toThrow(/no answer from/);

    await vi.advanceTimersByTimeAsync(11_000);
    await assertion;
  });

  it("names the address, so a typo is visible without a debugger", async () => {
    vi.useFakeTimers();
    vi.stubGlobal(
      "fetch",
      (_url: string, init?: RequestInit) =>
        new Promise((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () =>
            reject(Object.assign(new Error("aborted"), { name: "AbortError" })),
          );
        }),
    );

    const api = createRunnerApi("http://192.168.1.10:7842");
    const pending = api.fleet().catch((cause: unknown) => cause);
    await vi.advanceTimersByTimeAsync(11_000);

    const error = (await pending) as ApiError;
    expect(error).toBeInstanceOf(ApiError);
    expect(error.message).toContain("http://192.168.1.10:7842");
    // Status 0 is "never reached a server" — distinct from any HTTP failure.
    expect(error.status).toBe(0);
  });

  it("reports a refused connection as itself, not as a timeout", async () => {
    // A refused connection already fails fast; mislabelling it as a timeout
    // would send someone hunting for a slow runner that is simply not running.
    vi.stubGlobal("fetch", () =>
      Promise.reject(new TypeError("Network request failed")),
    );

    await expect(createRunnerApi("http://127.0.0.1:7842").fleet()).rejects.toThrow(
      /Network request failed/,
    );
  });

  it("still surfaces the runner's own error body on an HTTP failure", async () => {
    vi.stubGlobal("fetch", () =>
      Promise.resolve(
        new Response(JSON.stringify({ error: "session not found" }), {
          status: 404,
        }),
      ),
    );

    // `.then` with both branches, so the resolved type is `ApiError` rather
    // than a union with the success shape — and a call that wrongly *succeeds*
    // fails the test loudly instead of silently skipping the assertions.
    const error = await createRunnerApi("")
      .session("nope")
      .then(
        () => {
          throw new Error("expected the request to reject");
        },
        (cause: unknown) => cause as ApiError,
      );

    expect(error.status).toBe(404);
    expect(error.message).toBe("session not found");
  });
});
