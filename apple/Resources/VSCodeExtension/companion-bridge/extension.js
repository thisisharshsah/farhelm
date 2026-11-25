// Companion's bridge into VS Code (code-server inside Companion).
//
// Companion writes requests as JSON files into an inbox folder; this
// extension carries each out in VS Code and writes the outcome into an
// outbox folder. Files, not a socket: nothing listens on a port, and only
// Companion (the same user) can write there.
//
//   { "id": "...", "type": "terminal", "name": "Agent", "command": "ssh ..." }
//       Opens a VS Code terminal running the command.
//   { "id": "...", "type": "readTerminal", "name": "Agent" }
//       Answers with the terminal's recent output (shell integration).
//   { "id": "...", "type": "review", "path": "/abs/file", "before": "/abs/copy", "title": "..." }
//       Shows the agent's change as VS Code's diff, with Keep and Undo.

const vscode = require("vscode");
const fs = require("fs");
const path = require("path");

const ROOT = process.env.COMPANION_BRIDGE_DIR;
const outputs = new Map(); // terminal name -> recent output text

function answer(id, body) {
  if (!ROOT || !id) return;
  const file = path.join(ROOT, "outbox", id + ".json");
  fs.writeFileSync(file + ".tmp", JSON.stringify(body));
  fs.renameSync(file + ".tmp", file); // whole files only, never half written
}

function terminalNamed(name) {
  return vscode.window.terminals.find((t) => t.name === name);
}

async function handle(request) {
  switch (request.type) {
    case "terminal": {
      const name = request.name || "Agent";
      const terminal = terminalNamed(name) || vscode.window.createTerminal({ name });
      terminal.show(true);
      terminal.sendText(request.command, true);
      answer(request.id, { ok: true });
      break;
    }
    case "readTerminal": {
      const name = request.name || "Agent";
      const text = (outputs.get(name) || "").split("\n").slice(-40).join("\n");
      answer(request.id, { ok: !!terminalNamed(name), text });
      break;
    }
    case "review": {
      const after = vscode.Uri.file(request.path);
      const before = vscode.Uri.file(request.before);
      await vscode.commands.executeCommand("vscode.diff", before, after,
        request.title || ("Agent's change: " + path.basename(request.path)));
      const choice = await vscode.window.showInformationMessage(
        "The agent changed " + path.basename(request.path) + ".", "Keep", "Undo");
      if (choice === "Undo") fs.copyFileSync(request.before, request.path);
      answer(request.id, { ok: true, choice: choice || "Keep" });
      break;
    }
    default:
      answer(request.id, { ok: false, error: "Unknown request " + request.type });
  }
}

function drain(inbox) {
  let names = [];
  try { names = fs.readdirSync(inbox).filter((n) => n.endsWith(".json")).sort(); } catch (e) { return; }
  for (const name of names) {
    const file = path.join(inbox, name);
    let request;
    try { request = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { continue; }
    try { fs.unlinkSync(file); } catch (e) {}
    handle(request).catch((error) => answer(request.id, { ok: false, error: String(error) }));
  }
}

function activate(context) {
  if (!ROOT) return;
  const inbox = path.join(ROOT, "inbox");
  fs.mkdirSync(inbox, { recursive: true });
  fs.mkdirSync(path.join(ROOT, "outbox"), { recursive: true });

  // What each terminal printed, kept for readTerminal.
  if (vscode.window.onDidStartTerminalShellExecution) {
    context.subscriptions.push(vscode.window.onDidStartTerminalShellExecution(async (event) => {
      const name = event.terminal.name;
      for await (const chunk of event.execution.read()) {
        const kept = ((outputs.get(name) || "") + chunk).slice(-20000);
        outputs.set(name, kept.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, ""));
      }
    }));
  }

  const watcher = fs.watch(inbox, () => drain(inbox));
  context.subscriptions.push({ dispose: () => watcher.close() });
  drain(inbox);
}

function deactivate() {}

module.exports = { activate, deactivate };
