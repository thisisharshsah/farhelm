import { ExternalLinkIcon, MessageSquareTextIcon } from "lucide-react";

interface CompanionProps {
  link: string;
}

/**
 * Companion's own glasses page (`/glass`) is served by the Companion app on
 * the Mac and paired with its code. This page only opens it; Back returns
 * here through history.
 */
export function Companion({ link }: CompanionProps) {
  return (
    <section className="app-page fixed" aria-label="Companion">
      <div className="center">
        <MessageSquareTextIcon size={64} className="hero-glyph tint-companion" aria-hidden="true" />
        <p>
          {link
            ? "The latest reply, chats and projects from Companion on your Mac."
            : "Not linked yet. On your phone, open Apps and paste the glasses link Companion shows."}
        </p>
      </div>
      {link ? (
        <button className="btn primary" data-primary onClick={() => location.assign(link)}>
          <ExternalLinkIcon size={26} />
          Open Companion
        </button>
      ) : null}
    </section>
  );
}
