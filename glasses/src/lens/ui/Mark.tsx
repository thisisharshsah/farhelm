/** The Lens mark: a lens ring with a highlight, on the brand gradient. Same drawing as the app icon. */
export function Mark({ size = 56 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" aria-hidden="true" className="mark">
      <defs>
        <linearGradient id="lens-mark-glasses" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#9b7bff" />
          <stop offset="1" stopColor="#5b3fc4" />
        </linearGradient>
      </defs>
      <rect width="32" height="32" rx="8" fill="url(#lens-mark-glasses)" />
      <circle cx="16" cy="16" r="7.5" fill="none" stroke="#fff" strokeWidth="2.4" />
      <circle cx="19.2" cy="12.8" r="1.7" fill="#fff" />
    </svg>
  );
}
