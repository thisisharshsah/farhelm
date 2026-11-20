import { EyeIcon, ThumbsUpIcon } from "lucide-react";
import type { VideoItem } from "../../../shared/api.ts";
import { ageOf, compactCount, formatDuration, thumbnailOf } from "../../../shared/youtube.ts";

interface VideoCardProps {
  video: VideoItem;
  /** For the video's age ("3 days ago"). */
  now: number;
  /** Shown on the thumbnail, for "Hey Meta, play number two". */
  index?: number;
  /** How much was watched, 0 to 1: a bar along the thumbnail. */
  watched?: number;
  /** Where focus lands when the app is entered. */
  primary?: boolean;
  onClick: () => void;
}

/**
 * One video in a row, as YouTube on a TV draws it: the picture with its
 * length, the title, the channel and age, then views and likes. With focus
 * the picture grows and its glass rim lights. The details lines keep their
 * height while they load, so rows never jump.
 */
export function VideoCard({ video, now, index, watched, primary, onClick }: VideoCardProps) {
  return (
    <button className="video-card" data-video={video.id} data-primary={primary || undefined} onClick={onClick}>
      <span className="thumb">
        <img src={thumbnailOf(video.id)} alt="" loading="lazy" decoding="async" />
        {index ? <span className="num">{index}</span> : null}
        {video.seconds ? <span className="length">{formatDuration(video.seconds)}</span> : null}
        {watched !== undefined ? (
          <span className="watched" aria-hidden="true">
            <span style={{ width: `${watched * 100}%` }} />
          </span>
        ) : null}
      </span>
      <span className="video-info">
        <span className="card-title">{video.title}</span>
        <span className="card-meta">
          <span className="card-channel">{video.channel}</span>
          {video.published ? <span className="card-age">{ageOf(video.published, now)}</span> : null}
        </span>
        <span className="card-facts">
          {video.views != null ? (
            <span>
              <EyeIcon size={13} aria-hidden="true" />
              {compactCount(video.views)} views
            </span>
          ) : null}
          {video.likes != null ? (
            <span>
              <ThumbsUpIcon size={13} aria-hidden="true" />
              {compactCount(video.likes)}
            </span>
          ) : null}
        </span>
      </span>
    </button>
  );
}
