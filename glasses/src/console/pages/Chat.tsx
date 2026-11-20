import { useState } from "react";
import type { PageProps } from "../App.tsx";
import { useLensChat } from "../chat/ChatContext.tsx";
import { Composer } from "../chat/Composer.tsx";
import { Feed } from "../chat/Feed.tsx";
import { Button, Empty, ErrorNote, PageHeader, useAction } from "../ui.tsx";

export function ChatPage(_: PageProps) {
  const chat = useLensChat();
  // Clearing removes the chat on every device, so it takes two taps.
  const [armed, setArmed] = useState(false);
  const clear = useAction(async () => {
    await chat.clear();
    setArmed(false);
  });
  const talked = chat.items.length > 0 || chat.pending.length > 0;

  return (
    <>
      <PageHeader title="Chat" description="Ask here or on your glasses. The glasses show the result." />
      <Composer />
      {talked ? (
        <Feed />
      ) : (
        <div className="glass card">
          <Empty icon="sparkles" title="Nothing yet">
            Search YouTube, save a note, start a timer or open an app. Tap a suggestion above to try one.
          </Empty>
        </div>
      )}
      {chat.items.length ? (
        <div className="center-row">
          <Button
            variant={armed ? "danger" : "ghost"}
            icon="trash"
            busy={clear.busy}
            onClick={() => (armed ? void clear.run() : setArmed(true))}
            onBlur={() => setArmed(false)}
          >
            {armed ? "Clear on every device" : "Clear chat"}
          </Button>
        </div>
      ) : null}
      <ErrorNote message={clear.error} />
    </>
  );
}
