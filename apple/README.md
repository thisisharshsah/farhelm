# Companion

A native macOS conversation copilot. It listens to both sides of a conversation (your mic and system audio), transcribes locally with Parakeet, and drafts what you should say next using details you provide. It can also read your screen and answer the question shown there. Everything lives in a glass overlay pinned below the camera, plus a menu bar control.

## Features

- Live transcription, fully on-device (Parakeet v3 via FluidAudio, CoreML on the Neural Engine)
- Two streams: mic = You, system audio = Them (Zoom, Meet, any app). Same-speaker lines merge into paragraphs, filler-only sounds are dropped, and long speech is cut at a pause. Settings > Behavior has an English-only model (Parakeet v2) that is more accurate when the conversation is in English
- Transcript polish (on by default, Settings > Behavior > Assist): once a speaker's turn settles, the model re-reads it in context and rewrites it for readability, fixing misheard words using your details and attached files as vocabulary. It may not add, drop or answer anything. Polished lines carry a wand; click it to see what was originally heard. The same pass re-checks who said each mic line from context (who asked, who answered, what you would know) and corrects a clearly wrong label, marked with a swap icon; system-audio lines are always Them and never relabeled. Replies are drafted from the polished text
- Context that lasts: before transcript lines leave the recent window (30 lines) they are folded into running notes that travel with every request, so a long conversation keeps its beginning. The notes are saved with the conversation. The Notes chip opens them at any time, with a button to summarize everything up to now on demand. Automatic replies and screen answers also see the answers already given, so they stay consistent and don't repeat themselves
- No repeated work: a question that was already answered (asked again, or the same lines coming back relabeled or rewritten) reuses the answer in the thread instead of generating it again; Recheck only goes through lines it has not checked yet (pressing it with nothing new redoes everything); the automatic write-up is skipped when the transcript has not changed
- Call wrap-up: the notes below are also saved as a Markdown file per conversation in Application Support/Companion/Wrap-ups (the folder button in Notes opens it), with key points, decisions, action items, follow-ups and open questions
- Notes for later: when you stop listening (and whenever you press the wand in the Notes view) the conversation is written up as structured notes: a short summary, a section per topic, decisions, action items and open questions. They are saved with the conversation, refreshed after a recheck, and the save button exports the notes plus the cleaned transcript as a Markdown file
- Guided voice setup: read five short sentences aloud, one at a time, and it advances as it hears you
- Voice separation on the mic (optional): record your voice once, then in-person talks and speakerphone calls work too; your voice stays You, every other voice becomes P1, P2, ... and triggers suggestions. Three FluidAudio models work together. Live, the streaming Sortformer diarizer follows the continuous mic stream (primed with your recording), and each finished utterance also gets a voiceprint (WeSpeaker embedding) that is compared with your own voice and the voices heard so far: it overrules the diarizer when the voice clearly says otherwise and folds a voice the diarizer split in two back into one person. On Recheck, the offline pyannote pipeline (segmentation, embeddings, VBx clustering) re-labels the whole recorded session at once, which is the most accurate, and the live labels then follow its naming. Mic audio for this is kept in memory only (up to 30 minutes). Phone calls taken on the Mac (FaceTime, iPhone call relay) already arrive as system audio
- Reply suggestions streamed from your Farhelm gateway (local models with routing, cache and one ledger), Claude, OpenAI, or Ollama, switchable anytime
- Screen answers: one hotkey takes a picture of what you are looking at and answers the question shown. It zooms in on the window under the mouse pointer and captures it at full resolution, instead of the whole monitor, so small text and diagrams keep their detail. The window itself is captured, so other windows overlapping it are left out. With Claude or OpenAI as the engine the picture itself is sent along with the OCR text (Apple Vision, on-device), so diagrams, charts and figures are understood; Farhelm and Ollama get the text only. Optional auto-watch mode
- Screen watcher: with Screen on, Companion glances at the screen every few seconds (3 by default; 2, 3, 5 or 10 in Settings) with a tiny capture, reads it only when it changed and then held still, and answers only a question it has not answered yet; after a minute without change it slows to every 10 seconds
- Agent, from the chat: there is one chat box. A question is answered; a message that asks for something to be done on the Mac ("deploy the frontend", "what changed in this repo since yesterday", "write a prompt about the settings window in the Claude chat and send it") goes to the agent, by its wording or because the model hands it over (so "can you do it" about something on screen works). It works like a coding agent, in rounds: it proposes the next step, you allow it, it runs, and the result goes back to the model, until the task is done or it needs you
  - Tools: RUN a shell command and read its output (in your login shell, starting in the working folder from Settings; `cd` carries over), OPEN an app, CLICK a button, checkbox, link or menu item by its label (through the macOS Accessibility API; menu paths like `File > Export…` work), TYPE into the app in front, press a KEY or shortcut, WAIT. It clicks by label only, never by position
  - Self-check: each step's result is verified and recorded. An opened app must come to the front (one retry), a click names the control that was pressed (one retry if it was not found), typed text is looked for on screen afterwards (never retyped). A step that could not be confirmed is marked so in the chat and the model is told not to assume it worked
  - Screen in one step: every round the agent is given the app in front, its window title, the page address when it is a browser (asked from the browser; macOS asks once to allow it) and the window's text, so it never has to run osascript or screencapture to look. Screen answers get the same header
  - Consistency: what the agent has done, with results, and what is still waiting for approval is given to every other prompt as fact, so a reply never contradicts it. The follow-up after a task adds only what the report left out, plus next steps
  - Permissions: every step that changes something is shown first, with Allow, Always allow and Deny. With "Run read-only commands without asking" on (Settings > Behavior > Agent, on by default), commands that only read (ls, cat, grep, git status, git diff, osascript queries, screencapture to /tmp ...) run without asking; writing, deleting, sending and typing always ask. Always allow remembers the program (or program and subcommand, such as `git commit`); the list is in Settings > Behavior > Agent and each entry can be removed. A command that redirects output or uses a subshell is always asked about. Deny stops the task
  - The task, each command with the end of its output, and the outcome appear in the chat. Afterwards it says how it went and offers up to three next steps as buttons
  - Voice (on by default, Settings > Behavior > Agent): "Companion, ..." gives it a task, and a short "allow" or "deny" answers its question. Stop ends it at any point; a command is ended after 2 minutes, and a task after 40 steps
- Glass UI: a pulsing circle under the camera (click to expand, drag to move; position is remembered, the panel follows) and a panel with the live transcript plus two cards side by side: speech reply and screen answer, each streaming independently. Background style is Frosted glass or Clear with a darkness slider; text keeps full contrast at any transparency. The panel resizes from any edge (size remembered, cards grow with it) and follows the circle until you drag the panel yourself; from then on it stays where you put it, and Reset Overlay Position re-attaches it. Click-through mode (Cmd+Shift+T) lets you click and select behind the panel; menu bar > Reset Overlay Position brings everything back under the camera
- One conversation view: the transcript and the answers live in a single timeline, in the order things happened. What was heard is shown as compact lines (speaker badge plus text), what you typed or captured as a small note, and each answer as a card right after what it answers. Only the newest Reply and the newest Screen answer stay open; older answers fold to one line and open again on click. All / Reply / Screen chips filter it; each answer has copy, regenerate, reuse-prompt and delete on hover
- Fewer replies: by default a short remark that is not a question ("Okay.", "Simplify.") gets no automatic reply; anything of six words or more, and any question or request, does. Settings > Behavior > Assist turns this off; the bolt button always drafts one. Only what the others say triggers a reply, never lines labeled You
- Times and matching: every line, typed note and answer shows its clock time. After Recheck has corrected the transcript it goes back over the suggested replies and marks each Matched or No match (does it answer something that was really asked?); the eraser removes the replies that match nothing along with the ones you did not say
- Used or not: a suggested reply is tagged Used, Partly used or Not used, judged by how much of it you went on to say aloud. The eraser button removes the automatic replies you did not say, so the saved conversation reads as it actually went, and passed-over suggestions are no longer fed back to the model as context
- Header mode switches: the sparkles icon turns the Reply thread on or off (drafting when they finish speaking) and the viewfinder icon turns the Screen thread on or off (answering new questions that appear on screen). The timeline header has a bolt button to draft a reply now and a capture button to answer the screen now
- Recheck the transcript: the Recheck button on the transcript (also in the menu) goes through the last 40 lines one at a time, from the newest back to the oldest, and redoes each against the lines around it: who said it, whether it holds two people's speech (then it is split), and how it should read (misheard words fixed, grammar and punctuation cleaned, written so it is easy to understand, meaning and facts unchanged). Each fix appears as soon as it is found, the line being checked is highlighted, and the run can be stopped at any point. The wand on a rewritten line shows what was originally heard, and Undo puts the whole transcript back. For a single wrong label, click the speaker badge to hand that line to the next speaker (You, Them, P1, P2, ...)
- Type to it: the input bar at the bottom sends a typed message with the transcript and earlier turns as context; the viewfinder toggle attaches a screen capture. The model switcher sits in the input bar (engine, then the Farhelm model or Auto, or the Claude model: the list is loaded from the Anthropic API for your key)
- Retrieval instead of truncation: your details, attached files and memories are cut into passages, and when they are too long to send whole, only the passages relevant to what is being asked go to the model (keyword match plus Apple's on-device sentence embeddings; this step never leaves the Mac). The opening of My Details is always sent. Each answer shows which sources it drew on
- Memory across conversations: when a conversation is written up, up to six facts worth knowing later are saved (who you spoke with, what you were asked and how you answered, commitments and dates) and the relevant ones are fed into later conversations. Settings > Memory shows every item, with delete and Forget everything, and the switch to turn it off. Stored only on this Mac (Application Support/Companion/memory.json)
- Prompt caching with Claude: the instructions and the always-sent part of your details are marked cacheable, so repeat requests within five minutes are processed faster and cheaper
- Context sized to the engine: every limit on prompt size comes from one place (`LLM/ContextBudget.swift`) and scales with the selected engine's context window and with how urgent the task is. Live replies stay small so they start fast (about 6k tokens on a local model, 10k hosted); typed and screen questions get more (14k local, 40k hosted) and longer answers; notes, recheck and reply verification use most of the window (up to 150k with Claude). For Farhelm and Ollama, set the window the model is loaded with in Settings > Providers (default 32k); Ollama is told to use it. Up to 1,500 transcript lines are kept per conversation
- Attach files: the paperclip in the input bar (or dropping files on it) adds PDFs, Word/RTF/HTML, text, code or images (via OCR) to the conversation; their text is context for every answer
- One answer per question: an automatic reply covers everything they say until you speak, and is refreshed in place only when the question materially changes. When they add to a question that is already being answered, the new answer builds on the text already written (even a half-generated one) and the words on screen stay put until the answer actually differs. While the question still sounds unfinished the answer is tagged Draft; it is confirmed when the question ends with a question mark or a finished sentence, or after they pause. A screen that hasn't changed is not answered again; the existing turn is updated instead
- Conversations are saved automatically (Application Support/Companion/conversations, screenshots included), and can be reopened to continue or deleted from the history view; New Conversation is Cmd+Shift+N in the menu
- Read-along: as you speak the newest reply or screen answer, the turn dims what you've already said and scrolls itself, so you never scroll mid-call; while an answer streams in, the thread follows the stream too
- Invisible to screen sharing and recordings (sharingType = .none, toggleable)
- Non-activating windows: clicking Companion never steals focus from your call

## Using it

- Window buttons: the red, yellow and green dots at the top left close the panel (the circle or Cmd+Shift+Space brings it back), minimize it to a small strip showing just the newest answer and the input, and enlarge it to fill most of the screen (click again to go back)
- Listen is the one labeled button in the header. The line under the app name says what Companion is doing, or why it did not draft a reply just now (a short remark, the same question as before, replies turned off)
- Modes: the first chip sets what kind of conversation this is. Interview answers in the first person from your own details with a concrete example and writes the notes as questions asked, what went well and what to improve. Class explains what was just covered and writes study notes. Work call keeps to facts and commitments. Everyday is the plain default
- Reply on/off and Screen on/off are labeled chips next to the mode
- History has a search box that looks through everything said, answered and noted in every saved conversation
- Setup checklist: until the microphone and an AI model are set up, the panel shows what is missing with the button that fixes each item; Hide dismisses it and a Finish setup chip brings it back

## Requirements

- macOS 14+ on Apple Silicon
- Xcode 16+ or Command Line Tools with Swift 6 (`xcode-select --install`)
- First launch downloads the Parakeet model (about 1 GB, cached afterwards)
- For local models: a running Farhelm runner (`farhelm clients add companion` once, key goes in Settings; default gateway http://127.0.0.1:7842/p/companion) or [Ollama](https://ollama.com). For API providers: an Anthropic or OpenAI key.

## Build and run

```bash
cd ~/Project/companion
bash build.sh
```

This builds a release binary, bundles `dist/Companion.app`, ad-hoc signs it and opens it. Other commands: `bash build.sh app` (build only), `bash build.sh clean`. Always run the bundled app, not `swift run` (permissions need the app bundle).

## First-run setup

1. Click the circle under your camera or the waveform menu bar icon.
2. Menu bar > Settings > Providers: pick an engine and paste a key (stored in Keychain), or point it at Ollama.
3. Settings > My Details: paste who you are, your product, talking points. Extra `.md`/`.txt` files can go in the context folder.
4. Start Listening. Grant Microphone when prompted. For system audio and screen answers, grant Screen Recording under System Settings > Privacy & Security, then relaunch.

## Hotkeys

| Keys | Action |
|---|---|
| Cmd+Shift+Space | Show or hide the panel |
| Cmd+Shift+Return | Suggest a reply now |
| Cmd+Shift+A | Answer the question on screen |
| Cmd+Shift+K | Ask from anywhere: opens the panel with the cursor in the input box (letter configurable in Settings > Behavior) |
| Cmd+Shift+T | Click-through: panel ignores the mouse so you can work behind it |
| Cmd+Shift+L | Start or stop listening (via menu) |

## How it works

```
Mic (AVAudioEngine)        System audio (ScreenCaptureKit)
        │                             │
   AudioResampler (16 kHz mono) ──────┤
        │                             │
   SpeechChunker (energy VAD, partials + finals)
        │
   Transcriber (FluidAudio Parakeet v3, actor)
        │
   AppState transcript (You / Them)
        │                      Screen (SCScreenshotManager + Vision OCR)
        └──────► SuggestionEngine ◄───┘
                     │
        Claude / OpenAI / Ollama (streaming)
                     │
            Glass overlay suggestion card
```

- `Sources/Companion/UI/Theme.swift` holds `Theme.iconSymbol`, the placeholder icon in the circle. Swap that one constant when the final icon is decided.
- Companion's own windows are excluded from its screen captures, so screen answers never read Companion itself.

## Notes and limits

- Use headphones on calls. With speakers, the other side leaks into your mic and can show up as You.
- Multi-display: choose which monitor screen answers read in Settings > Behavior > Screen or in the menu bar (Monitor to Read). Automatic reads the monitor the mouse pointer is on. System audio is captured for the whole Mac regardless of monitor.
- Recording calls may require consent where you live; check before using it on real calls.
- Only `Transcriber.swift` touches the FluidAudio API. If a future FluidAudio release changes names, fix that one file against their README quickstart.

## Troubleshooting

- Permissions keep being asked: the app must be signed with a stable identity. build.sh picks your Apple Development or "Companion Dev" certificate automatically; with no certificate it falls back to ad-hoc signing, and macOS treats every rebuild as a new app. After switching to a real certificate, reset the stale grants once and re-grant: `tccutil reset ScreenCapture com.harshsah.companion && tccutil reset Microphone com.harshsah.companion`. Separately, macOS re-confirms screen recording after app updates and about monthly ("Continue to Allow"); that one is OS policy and is one click.
- No Them text: Screen Recording permission missing, or the call app plays through a device ScreenCaptureKit can't tap. Grant permission and relaunch.
- "Cannot reach Ollama": run `ollama serve`, then `ollama pull <model>`.
- Model download stuck: first run needs network access to huggingface.co.
