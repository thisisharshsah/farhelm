import { createContext, useContext, type ReactNode } from "react";
import { CACHE_PREFIX } from "../../client/account.ts";
import { useChat, type Chat } from "../../client/chat.ts";
import type { Me } from "../../shared/api.ts";

const ChatContext = createContext<Chat | null>(null);

/** One live chat for the whole console, so Home and Chat show the same conversation. */
export function ChatProvider({ me, children }: { me: Me; children: ReactNode }) {
  const chat = useChat({ cacheKey: `${CACHE_PREFIX}${me.user.id}:chat`, keep: 60 });
  return <ChatContext.Provider value={chat}>{children}</ChatContext.Provider>;
}

export function useLensChat(): Chat {
  const chat = useContext(ChatContext);
  if (!chat) throw new Error("useLensChat needs a ChatProvider");
  return chat;
}
