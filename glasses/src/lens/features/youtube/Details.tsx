import { ClockIcon, EyeIcon, ThumbsUpIcon } from "lucide-react";
import type { VideoItem } from "../../../shared/api.ts";
import { ageOf, compactCount, formatDuration } from "../../../shared/youtube.ts";

/**
 * Everything about the video playing, under the picture as a TV shows it:
 * title, channel, age, views, likes, length and the start of its description.
 */
export function Details({ video, now }: { video: VideoItem; now: number }) {
  const facts = [
    video.views != null ? { icon: <EyeIcon size={15} />, text: `${compactCount(video.views)} views` } : null,
    video.likes != null ? { icon: <ThumbsUpIcon size={15} />, text: compactCount(video.likes) } : null,
    video.seconds ? { icon: <ClockIcon size={15} />, text: formatDuration(video.seconds) } : null,
  ].filter((f) => f !== null);
  return (
    <section className="details" aria-label={`About ${video.title}`}>
      <p className="details-title">{video.title}</p>
      <p className="details-meta">
        <span className="details-channel">{video.channel}</span>
        {video.published ? <span>{ageOf(video.published, now)}</span> : null}
      </p>
      {facts.length ? (
        <p className="details-facts">
          {facts.map((f) => (
            <span key={f.text}>
              {f.icon}
              {f.text}
            </span>
          ))}
        </p>
      ) : null}
      {video.description ? <p className="details-about">{video.description}</p> : null}
    </section>
  );
}
