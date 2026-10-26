import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { AuthScreen, WelcomeScreen } from "./Auth";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let host: HTMLDivElement;
let root: Root;
type Props = Parameters<typeof AuthScreen>[0];

async function render(overrides: Partial<Props> = {}) {
  const props: Props = { onSubmit: vi.fn(), onCancel: vi.fn(), busy: false, error: null, ...overrides };
  await act(async () => root.render(createElement(AuthScreen, props)));
  return props;
}

function input(name: string): HTMLInputElement {
  return host.querySelector<HTMLInputElement>(`#auth-${name}`)!;
}

function button(name: string): HTMLButtonElement {
  const result = Array.from(host.querySelectorAll("button")).find((node) => node.textContent?.replace("→", "").replace("←", "").trim() === name);
  if (!result) throw new Error(`Missing button: ${name}`);
  return result;
}

function submitButton(): HTMLButtonElement {
  return host.querySelector<HTMLButtonElement>('button[type="submit"]')!;
}

async function fill(name: string, value: string) {
  await act(async () => {
    const node = input(name);
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(node, value);
    node.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

async function submit(times = 1) {
  await act(async () => {
    for (let index = 0; index < times; index += 1) host.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
}

beforeEach(() => {
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});

afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
});

it("offers account and local connection with clear destination choices", async () => {
  const onChoose = vi.fn();
  await act(async () => root.render(createElement(WelcomeScreen, { onChoose, loopbackAvailable: true })));
  expect(host.querySelector("h1")?.textContent).toBe("Build with AI. Keep control.");
  expect(host.textContent).toContain("No account required.");
  await act(async () => button("Use this machine only").click());
  expect(onChoose).toHaveBeenCalledExactlyOnceWith("loopback");
  await act(async () => button("Sign in to your workspace").click());
  expect(onChoose).toHaveBeenLastCalledWith("cloud");
});

it("does not offer or imply local access on a hosted surface", async () => {
  await act(async () => root.render(createElement(WelcomeScreen, { onChoose: vi.fn(), loopbackAvailable: false })));
  expect(host.textContent).not.toContain("Use this machine only");
  expect(host.textContent).not.toContain("or stay on this machine");
});

it("uses labelled required native fields and native mode buttons", async () => {
  await render();
  expect(host.querySelector('label[for="auth-email"]')?.textContent?.trim()).toBe("Email");
  expect(host.querySelector('label[for="auth-password"]')?.textContent?.trim()).toBe("Password");
  expect(input("email").type).toBe("email");
  expect(input("email").required).toBe(true);
  expect(input("password").autocomplete).toBe("current-password");
  expect(input("password").required).toBe(true);
  expect(host.querySelector('[role="tab"]')).toBeNull();
  expect(button("Sign in").getAttribute("aria-pressed")).toBe("true");
  expect(submitButton().disabled).toBe(true);
});

it("keeps short existing passwords usable for sign-in and trims only identity fields", async () => {
  const { onSubmit } = await render();
  await fill("email", "  person@example.test  ");
  await fill("password", " short ");
  await submit();
  expect(onSubmit).toHaveBeenCalledExactlyOnceWith({ mode: "sign-in", email: "person@example.test", password: " short ", name: "" });
});

it("does not submit malformed emails or empty required fields", async () => {
  const { onSubmit } = await render();
  await fill("email", "not-an-address");
  await fill("password", "password-value");
  await submit();
  expect(onSubmit).not.toHaveBeenCalled();
  await fill("email", "valid@example.test");
  await fill("password", "");
  await submit();
  expect(onSubmit).not.toHaveBeenCalled();
});

it("guards duplicate same-turn submission and locks fields and navigation until completion", async () => {
  let finish!: () => void;
  const onSubmit = vi.fn(() => new Promise<void>((resolve) => { finish = resolve; }));
  const onModeChange = vi.fn();
  await render({ onSubmit, onModeChange });
  await fill("email", "person@example.test");
  await fill("password", "password-value");
  await submit(2);
  expect(onSubmit).toHaveBeenCalledTimes(1);
  expect(host.querySelector("fieldset")?.disabled).toBe(true);
  expect(button("Create account").disabled).toBe(true);
  expect(button("Back to connection options").disabled).toBe(true);
  expect(submitButton().textContent).toBe("Signing in…");
  expect(host.querySelector('[role="status"]')?.textContent).toContain("Connecting to your workspace");
  await act(async () => button("Create account").click());
  expect(onModeChange).not.toHaveBeenCalled();
  await act(async () => finish());
  expect(host.querySelector("fieldset")?.disabled).toBe(false);
  expect(submitButton().disabled).toBe(false);
});

it("uses the same Unicode character password minimum as the Rust service", async () => {
  const { onSubmit } = await render({ initialMode: "sign-up" });
  await fill("email", "person@example.test");
  await fill("name", "  Person  ");
  await fill("password", "😀".repeat(5));
  expect(input("password").getAttribute("aria-invalid")).toBe("true");
  expect(host.querySelector("#auth-password-hint")?.textContent).toContain("5 more needed");
  await submit();
  expect(onSubmit).not.toHaveBeenCalled();
  await fill("password", "😀".repeat(10));
  await submit();
  expect(onSubmit).toHaveBeenCalledExactlyOnceWith({ mode: "sign-up", email: "person@example.test", password: "😀".repeat(10), name: "Person" });
});

it("requires a name when creating an account and gives a persistent password hint", async () => {
  const { onSubmit } = await render({ initialMode: "sign-up" });
  expect(host.querySelector("#auth-password-hint")?.textContent).toContain("at least 10 characters");
  expect(input("password").autocomplete).toBe("new-password");
  await fill("email", "person@example.test");
  await fill("password", "password-value");
  await fill("name", "   ");
  await submit();
  expect(onSubmit).not.toHaveBeenCalled();
});

it("changes mode with cleared password and requests removal of stale server errors", async () => {
  const onModeChange = vi.fn();
  await render({ onModeChange });
  await fill("email", "person@example.test");
  await fill("password", "old-password");
  await act(async () => button("Show").click());
  await act(async () => button("Create account").click());
  expect(onModeChange).toHaveBeenCalledTimes(1);
  expect(host.querySelector("h2")?.textContent).toBe("Create your workspace");
  expect(input("password").value).toBe("");
  expect(input("password").type).toBe("password");
  expect(input("email").value).toBe("person@example.test");
});

it("shows and hides the entered password without submitting the form", async () => {
  const { onSubmit } = await render();
  await fill("password", "password-value");
  await act(async () => button("Show").click());
  expect(input("password").type).toBe("text");
  expect(host.querySelector('[aria-label="Hide password"]')?.getAttribute("aria-pressed")).toBe("true");
  await act(async () => button("Hide").click());
  expect(input("password").type).toBe("password");
  expect(input("password").value).toBe("password-value");
  expect(onSubmit).not.toHaveBeenCalled();
});

it("keeps user input and displays rejected submission errors, then allows a deliberate retry", async () => {
  const onSubmit = vi.fn().mockRejectedValueOnce(new Error("Workspace server is unavailable")).mockResolvedValueOnce(undefined);
  await render({ onSubmit });
  await fill("email", "person@example.test");
  await fill("password", "password-value");
  await submit();
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("Workspace server is unavailable");
  expect(input("email").value).toBe("person@example.test");
  expect(input("password").value).toBe("password-value");
  expect(submitButton().disabled).toBe(false);
  expect(onSubmit).toHaveBeenCalledTimes(1);
  await submit();
  expect(onSubmit).toHaveBeenCalledTimes(2);
  expect(host.querySelector('[role="alert"]')).toBeNull();
});

it("renders parent errors and busy state without permitting account or server edits", async () => {
  await render({ busy: true, error: "Please check your workspace server.", serviceUrl: "http://127.0.0.1:7844" });
  expect(host.querySelector('[role="alert"]')?.textContent).toBe("Please check your workspace server.");
  expect(submitButton().disabled).toBe(true);
  expect(host.querySelector("fieldset")?.disabled).toBe(true);
  expect(button("Create account").disabled).toBe(true);
  expect(input("server-url").readOnly).toBe(true);
});

it("exposes the credential destination with a labelled editable server field", async () => {
  const onServiceUrlChange = vi.fn();
  await render({ serviceUrl: "http://127.0.0.1:7844", onServiceUrlChange });
  expect(host.querySelector("summary")?.textContent).toBe("Workspace server");
  expect(host.querySelector('label[for="auth-server-url"]')?.textContent).toBe("Server address");
  expect(host.textContent).toContain("Your email and password are sent to this server.");
  expect(input("server-url").type).toBe("url");
  await fill("server-url", "https://workspace.example.test");
  expect(onServiceUrlChange).toHaveBeenCalledWith("https://workspace.example.test");
});

it("only renders Back when cancellation is supported", async () => {
  const { onCancel } = await render();
  await act(async () => button("Back to connection options").click());
  expect(onCancel).toHaveBeenCalledTimes(1);
  await render({ onCancel: null });
  expect(host.textContent).not.toContain("Back to connection options");
});
