import type { JSX } from 'react'

const paths: Record<string, JSX.Element> = {
  home: <path d="M3 10.5 12 3l9 7.5V21h-6v-6H9v6H3z" />,
  homeLine: <path d="M3 10.5 12 3l9 7.5V21h-6.5v-6h-5v6H3z" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round" />,
  search: <g fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"><circle cx="10.5" cy="10.5" r="6.5" /><path d="m15.5 15.5 5 5" /></g>,
  library: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M4 3v18M9 3v18" /><path d="m14 3.5 6 17" /></g>,
  plus: <path d="M12 4v16M4 12h16" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />,
  heart: <path d="M12 20.5s-7.5-4.6-9.2-9.4C1.6 7.6 3.8 4 7.4 4c2 0 3.5 1.1 4.6 2.6C13.1 5.1 14.6 4 16.6 4c3.6 0 5.8 3.6 4.6 7.1-1.7 4.8-9.2 9.4-9.2 9.4z" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round" />,
  heartFill: <path d="M12 20.5s-7.5-4.6-9.2-9.4C1.6 7.6 3.8 4 7.4 4c2 0 3.5 1.1 4.6 2.6C13.1 5.1 14.6 4 16.6 4c3.6 0 5.8 3.6 4.6 7.1-1.7 4.8-9.2 9.4-9.2 9.4z" />,
  play: <path d="M7 4.5v15a1 1 0 0 0 1.5.9l12-7.5a1 1 0 0 0 0-1.8l-12-7.5A1 1 0 0 0 7 4.5z" />,
  pause: <g><rect x="5.5" y="4" width="4.5" height="16" rx="1.2" /><rect x="14" y="4" width="4.5" height="16" rx="1.2" /></g>,
  next: <g><path d="M4 5.2v13.6a.9.9 0 0 0 1.4.7l9.6-6.8a.9.9 0 0 0 0-1.4L5.4 4.5A.9.9 0 0 0 4 5.2z" /><rect x="17" y="4.5" width="3" height="15" rx="1" /></g>,
  prev: <g><path d="M20 5.2v13.6a.9.9 0 0 1-1.4.7L9 12.7a.9.9 0 0 1 0-1.4l9.6-6.8a.9.9 0 0 1 1.4.7z" /><rect x="4" y="4.5" width="3" height="15" rx="1" /></g>,
  shuffle: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M3 7h3.5c2 0 3.3 1 4.5 2.8l2 3.4C14.2 15 15.5 16 17.5 16H21" /><path d="M3 16h3.5c1.4 0 2.4-.5 3.3-1.4M14.2 8.4c.9-.9 1.9-1.4 3.3-1.4H21" /><path d="m18 4 3 3-3 3M18 13l3 3-3 3" /></g>,
  repeat: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M4 11V9a3 3 0 0 1 3-3h13" /><path d="m17 3 3 3-3 3" /><path d="M20 13v2a3 3 0 0 1-3 3H4" /><path d="m7 21-3-3 3-3" /></g>,
  lyrics: <g><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3h11A2.5 2.5 0 0 1 20 5.5v8a2.5 2.5 0 0 1-2.5 2.5H11l-4.6 3.8A.9.9 0 0 1 5 19.1V16h0a1 1 0 0 1-1-1z" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round" /><path d="M8.5 8h7M8.5 11.5h4.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /></g>,
  queue: <g stroke="currentColor" strokeWidth="2" strokeLinecap="round" fill="none"><path d="M4 6h12M4 11h12M4 16h7" /><path d="M15 15.5v-2.5l5 3-5 3z" fill="currentColor" /></g>,
  volume: <g><path d="M3.5 9.2v5.6c0 .5.4.9.9.9H8l4.5 3.7a.6.6 0 0 0 1-.5V5.1a.6.6 0 0 0-1-.5L8 8.3H4.4a.9.9 0 0 0-.9.9z" /><path d="M16.5 8.5a5 5 0 0 1 0 7M19 6a8.5 8.5 0 0 1 0 12" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /></g>,
  volumeLow: <g><path d="M3.5 9.2v5.6c0 .5.4.9.9.9H8l4.5 3.7a.6.6 0 0 0 1-.5V5.1a.6.6 0 0 0-1-.5L8 8.3H4.4a.9.9 0 0 0-.9.9z" /><path d="M16.5 8.5a5 5 0 0 1 0 7" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /></g>,
  mute: <g><path d="M3.5 9.2v5.6c0 .5.4.9.9.9H8l4.5 3.7a.6.6 0 0 0 1-.5V5.1a.6.6 0 0 0-1-.5L8 8.3H4.4a.9.9 0 0 0-.9.9z" /><path d="m17 9.5 5 5M22 9.5l-5 5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" /></g>,
  back: <path d="m14.5 5-7 7 7 7" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" />,
  forward: <path d="m9.5 5 7 7-7 7" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" />,
  down: <path d="m5 9 7 7 7-7" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" />,
  more: <g><circle cx="5" cy="12" r="2" /><circle cx="12" cy="12" r="2" /><circle cx="19" cy="12" r="2" /></g>,
  bell: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"><path d="M6 10a6 6 0 0 1 12 0v4.5l1.8 2.7a.5.5 0 0 1-.4.8H4.6a.5.5 0 0 1-.4-.8L6 14.5z" /><path d="M10 20.5a2.2 2.2 0 0 0 4 0" strokeLinecap="round" /></g>,
  gear: <g fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="12" r="3.2" /><path d="M12 2.8v2.4M12 18.8v2.4M2.8 12h2.4M18.8 12h2.4M5.5 5.5l1.7 1.7M16.8 16.8l1.7 1.7M5.5 18.5l1.7-1.7M16.8 7.2l1.7-1.7" strokeLinecap="round" /></g>,
  close: <path d="M6 6l12 12M18 6 6 18" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" />,
  check: <path d="m5 12.5 4.5 4.5L19 7.5" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" />,
  note: <path d="M9 17.5V5.8a1 1 0 0 1 .8-1l9-1.8a1 1 0 0 1 1.2 1V15.5M9 17.5a3 3 0 1 1-3-3 3 3 0 0 1 3 3zm11-2a3 3 0 1 1-3-3 3 3 0 0 1 3 3zM9 9l11-2.2" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />,
  mic: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="15" cy="8" r="4.5" /><path d="m12 11-7.5 8.5 1 1L14 13" /></g>,
  album: <g fill="none" stroke="currentColor" strokeWidth="2"><rect x="3" y="3" width="18" height="18" rx="3" /><circle cx="12" cy="12" r="4" /><circle cx="12" cy="12" r=".6" fill="currentColor" /></g>,
  clock: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="8.5" /><path d="M12 7.5V12l3 2" /></g>,
  phone: <g fill="none" stroke="currentColor" strokeWidth="2"><rect x="6.5" y="2.5" width="11" height="19" rx="2.5" /><path d="M10.5 18.5h3" strokeLinecap="round" /></g>,
  sync: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M20 12a8 8 0 0 1-14.3 4.9M4 12A8 8 0 0 1 18.3 7.1" /><path d="M18.5 3v4.3h-4.3M5.5 21v-4.3h4.3" /></g>,
  expand: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M14 4h6v6M10 20H4v-6M20 4l-6.5 6.5M4 20l6.5-6.5" /></g>,
  trash: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M4 7h16M9 7V4.5h6V7M6.5 7l1 13h9l1-13" /></g>,
  edit: <path d="M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16z" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round" />,
  info: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="9" /><path d="M12 11v5.5M12 7.5v.2" /></g>,
  link: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M10 14a4.5 4.5 0 0 0 6.4 0l3-3a4.5 4.5 0 0 0-6.4-6.4l-1 1" /><path d="M14 10a4.5 4.5 0 0 0-6.4 0l-3 3a4.5 4.5 0 0 0 6.4 6.4l1-1" /></g>,
  radio: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="12" r="2.5" /><path d="M7.8 7.8a6 6 0 0 0 0 8.4M16.2 7.8a6 6 0 0 1 0 8.4M5 5a10 10 0 0 0 0 14M19 5a10 10 0 0 1 0 14" /></g>,
  list: <g stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M8 6h12M8 12h12M8 18h12" /><circle cx="4" cy="6" r=".8" /><circle cx="4" cy="12" r=".8" /><circle cx="4" cy="18" r=".8" /></g>,
  grid: <g fill="none" stroke="currentColor" strokeWidth="2"><rect x="3.5" y="3.5" width="7" height="7" rx="1.5" /><rect x="13.5" y="3.5" width="7" height="7" rx="1.5" /><rect x="3.5" y="13.5" width="7" height="7" rx="1.5" /><rect x="13.5" y="13.5" width="7" height="7" rx="1.5" /></g>,
  person: <g fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="8" r="4" /><path d="M4 20.5a8 8 0 0 1 16 0" strokeLinecap="round" /></g>,
  sparkle: <path d="M12 3c.6 4.2 2.8 6.4 7 7-4.2.6-6.4 2.8-7 7-.6-4.2-2.8-6.4-7-7 4.2-.6 6.4-2.8 7-7z" />,
  copy: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"><rect x="8" y="8" width="12" height="12" rx="2.5" /><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2" /></g>,
  external: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M14 4h6v6M20 4l-9 9" /><path d="M18 14v4.5A1.5 1.5 0 0 1 16.5 20h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10" /></g>,
  minimize: <path d="m5 9 7 7 7-7" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" />
}

export function Icon({ name, size = 20, className }: { name: keyof typeof paths | string; size?: number; className?: string }): JSX.Element {
  return (
    <svg className={className} width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      {paths[name] ?? paths.note}
    </svg>
  )
}

/** Drift's logo: four bars. */
export function Logo({ size = 20 }: { size?: number }): JSX.Element {
  return (
    <svg width={size} height={(size * 16) / 20} viewBox="0 0 20 16" aria-hidden="true">
      <rect x="0" y="6" width="3" height="10" rx="1.5" fill="var(--accent)" />
      <rect x="5.5" y="1" width="3" height="15" rx="1.5" fill="var(--accent)" />
      <rect x="11" y="4" width="3" height="12" rx="1.5" fill="var(--accent)" />
      <rect x="16.5" y="0" width="3" height="16" rx="1.5" fill="var(--accent)" />
    </svg>
  )
}
