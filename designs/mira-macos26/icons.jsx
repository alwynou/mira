/* SF-Symbols-style monoline UI icons. Functional, not decorative. */
const Ico = ({ d, size = 16, sw = 1.6, fill = "none", children, style }) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill={fill}
    stroke="currentColor"
    strokeWidth={sw}
    strokeLinecap="round"
    strokeLinejoin="round"
    style={{ flex: "none", display: "block", ...style }}
    aria-hidden="true"
  >
    {d ? <path d={d} /> : children}
  </svg>
);

const I = {
  sidebar: (p) => (
    <Ico {...p}>
      <rect x="3" y="4.5" width="18" height="15" rx="3.2" />
      <line x1="9.2" y1="4.5" x2="9.2" y2="19.5" />
    </Ico>
  ),
  search: (p) => (
    <Ico {...p}>
      <circle cx="11" cy="11" r="6.2" />
      <line x1="20" y1="20" x2="15.6" y2="15.6" />
    </Ico>
  ),
  compose: (p) => (
    <Ico {...p}>
      <path d="M4 20h16" />
      <path d="M14.5 5.2l4.3 4.3M6 15.4l9.1-9.1a2 2 0 0 1 2.8 0l1.6 1.6a2 2 0 0 1 0 2.8L10.4 20H6z" />
    </Ico>
  ),
  inbox: (p) => (
    <Ico {...p}>
      <path d="M4 13.5 6 5.5a2 2 0 0 1 1.95-1.5h8.1A2 2 0 0 1 18 5.5l2 8" />
      <path d="M4 13.5h4l1.2 2.2h5.6L16 13.5h4v3.9A2.6 2.6 0 0 1 17.4 20H6.6A2.6 2.6 0 0 1 4 17.4z" />
    </Ico>
  ),
  folder: (p) => (
    <Ico {...p}>
      <path d="M3.5 7.4a2 2 0 0 1 2-2h3.2l1.8 2h8a2 2 0 0 1 2 2v6.8a2 2 0 0 1-2 2H5.5a2 2 0 0 1-2-2z" />
    </Ico>
  ),
  chat: (p) => (
    <Ico {...p}>
      <path d="M20 12a7.5 7.5 0 0 1-10.8 6.7L4 20l1.3-4.1A7.5 7.5 0 1 1 20 12z" />
    </Ico>
  ),
  memory: (p) => (
    <Ico {...p}>
      <path d="M9.5 4.2a3 3 0 0 0-3 3 3 3 0 0 0-1.6 5.4A3 3 0 0 0 6.7 18a3 3 0 0 0 5.3 1V4.6a3 3 0 0 0-2.5-.4z" />
      <path d="M14.5 4.2a3 3 0 0 1 3 3 3 3 0 0 1 1.6 5.4A3 3 0 0 1 17.3 18a3 3 0 0 1-5.3 1" />
    </Ico>
  ),
  knowledge: (p) => (
    <Ico {...p}>
      <path d="M12 6.2C10.4 5 8 4.6 5.5 5.1A1 1 0 0 0 4.7 6v11a1 1 0 0 0 1.2 1c2.2-.4 4.4-.1 6.1 1 1.7-1.1 3.9-1.4 6.1-1a1 1 0 0 0 1.2-1V6a1 1 0 0 0-.8-1C16 4.6 13.6 5 12 6.2z" />
      <line x1="12" y1="6.2" x2="12" y2="19" />
    </Ico>
  ),
  tasks: (p) => (
    <Ico {...p}>
      <rect x="4.5" y="4.5" width="15" height="15" rx="4" />
      <path d="M8.4 12.2l2.4 2.4 4.8-5" />
    </Ico>
  ),
  gear: ({ size = 16, style } = {}) => (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      style={{ flex: "none", display: "block", ...style }}
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="3.1" />
      <path d="M19.4 12c0-.5-.05-1-.13-1.47l1.86-1.4-1.8-3.12-2.2.9a7.3 7.3 0 0 0-2.55-1.48L14.1 3h-3.6l-.28 2.35c-.93.32-1.79.82-2.55 1.47l-2.2-.9-1.8 3.12 1.86 1.4a7.5 7.5 0 0 0 0 2.94l-1.86 1.4 1.8 3.12 2.2-.9c.76.65 1.62 1.15 2.55 1.47L10.5 21h3.6l.28-2.35a7.3 7.3 0 0 0 2.55-1.47l2.2.9 1.8-3.12-1.86-1.4c.08-.48.13-.97.13-1.46z" />
    </svg>
  ),
  caret: (p) => <Ico {...p} d="M9 6l6 6-6 6" />,
  chevDown: (p) => <Ico {...p} d="M6 9.5l6 6 6-6" />,
  plus: (p) => <Ico {...p} d="M12 5v14M5 12h14" />,
  arrowUp: (p) => <Ico {...p} sw={2} d="M12 19V6M6 11.5 12 5.5l6 6" />,
  stop: (p) => (
    <Ico {...p}>
      <rect x="7" y="7" width="10" height="10" rx="2.4" fill="currentColor" stroke="none" />
    </Ico>
  ),
  sparkle: (p) => (
    <Ico {...p}>
      <path d="M12 4.2c.5 2.9 1.9 4.3 4.8 4.8-2.9.5-4.3 1.9-4.8 4.8-.5-2.9-1.9-4.3-4.8-4.8 2.9-.5 4.3-1.9 4.8-4.8z" />
      <path d="M18.4 14.2c.25 1.5 1 2.2 2.5 2.5-1.5.3-2.25 1-2.5 2.5-.25-1.5-1-2.2-2.5-2.5 1.5-.3 2.25-1 2.5-2.5z" />
    </Ico>
  ),
  info: (p) => (
    <Ico {...p}>
      <circle cx="12" cy="12" r="8.2" />
      <line x1="12" y1="11" x2="12" y2="16.4" />
      <circle cx="12" cy="8" r="0.6" fill="currentColor" />
    </Ico>
  ),
  panelRight: (p) => (
    <Ico {...p}>
      <rect x="3" y="4.5" width="18" height="15" rx="3.2" />
      <line x1="15" y1="4.5" x2="15" y2="19.5" />
    </Ico>
  ),
  link: (p) => (
    <Ico {...p}>
      <path d="M10 13.8a3.5 3.5 0 0 0 5 0l2.6-2.6a3.5 3.5 0 1 0-5-5l-1 1" />
      <path d="M14 10.2a3.5 3.5 0 0 0-5 0l-2.6 2.6a3.5 3.5 0 1 0 5 5l1-1" />
    </Ico>
  ),
  clock: (p) => (
    <Ico {...p}>
      <circle cx="12" cy="12" r="8.2" />
      <path d="M12 7.6V12l3 1.8" />
    </Ico>
  ),
  check: (p) => <Ico {...p} sw={1.9} d="M5 12.5l4.2 4.3L19 7" />,
  dots: (p) => (
    <Ico {...p}>
      <circle cx="6" cy="12" r="1.4" fill="currentColor" stroke="none" />
      <circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none" />
      <circle cx="18" cy="12" r="1.4" fill="currentColor" stroke="none" />
    </Ico>
  ),
  x: (p) => <Ico {...p} d="M6 6l12 12M18 6 6 18" />,
  cloud: (p) => (
    <Ico {...p}>
      <path d="M7.2 18a4 4 0 0 1-.5-7.97 5 5 0 0 1 9.6-1.2A3.8 3.8 0 0 1 17.5 18z" />
    </Ico>
  ),
  key: (p) => (
    <Ico {...p}>
      <circle cx="8" cy="14" r="3.4" />
      <path d="M10.4 11.6 20 4.5M17 6.6l1.8 1.8M14.5 8.6l1.6 1.6" />
    </Ico>
  ),
  shield: (p) => (
    <Ico {...p}>
      <path d="M12 3.6 5.5 6v5.1c0 4 2.7 7.3 6.5 8.6 3.8-1.3 6.5-4.6 6.5-8.6V6z" />
      <path d="M9.2 12.2 11 14l3.8-4" />
    </Ico>
  ),
  doc: (p) => (
    <Ico {...p}>
      <path d="M7 3.6h6.5L18 8v11.4a1.4 1.4 0 0 1-1.4 1.4H7A1.4 1.4 0 0 1 5.6 19.4V5A1.4 1.4 0 0 1 7 3.6z" />
      <path d="M13 3.6V8h5" />
    </Ico>
  ),
  upload: (p) => (
    <Ico {...p}>
      <path d="M12 15.5V4.8M8 8.5 12 4.5l4 4" />
      <path d="M5 15v3.4A1.6 1.6 0 0 0 6.6 20h10.8A1.6 1.6 0 0 0 19 18.4V15" />
    </Ico>
  ),
  trash: (p) => (
    <Ico {...p}>
      <path d="M5 7h14M9.5 7V5.6A1.6 1.6 0 0 1 11.1 4h1.8A1.6 1.6 0 0 1 14.5 5.6V7M7 7l.9 11.3A1.6 1.6 0 0 0 9.5 20h5a1.6 1.6 0 0 0 1.6-1.7L17 7" />
    </Ico>
  ),
  pencil: (p) => <Ico {...p} d="M4 20l.9-3.6L15.4 5.9a2 2 0 0 1 2.8 0l1.4 1.4a2 2 0 0 1 0 2.8L9 20.7 4 20z" />,
  archive: (p) => (
    <Ico {...p}>
      <rect x="4" y="5" width="16" height="4" rx="1.4" />
      <path d="M5.4 9v8.6A1.4 1.4 0 0 0 6.8 19h10.4a1.4 1.4 0 0 0 1.4-1.4V9M10 12.6h4" />
    </Ico>
  ),
  restore: (p) => (
    <Ico {...p}>
      <path d="M5 8.5A8 8 0 1 1 4.2 13" />
      <path d="M4.4 4.5V8.6H8.5" />
    </Ico>
  ),
  bell: (p) => (
    <Ico {...p}>
      <path d="M6.5 16.5V11a5.5 5.5 0 0 1 11 0v5.5l1.4 2H5.1z" />
      <path d="M10 19.5a2 2 0 0 0 4 0" />
    </Ico>
  ),
  calendar: (p) => (
    <Ico {...p}>
      <rect x="4" y="5.2" width="16" height="15" rx="2.6" />
      <path d="M4 9.4h16M8.5 3.4v3.4M15.5 3.4v3.4" />
    </Ico>
  ),
  wrench: (p) => (
    <Ico {...p}>
      <path d="M15.5 4.2a4.4 4.4 0 0 0-5.3 5.6l-6 6a1.8 1.8 0 0 0 2.5 2.5l6-6a4.4 4.4 0 0 0 5.6-5.3l-2.6 2.6-2.1-.5-.5-2.1z" />
    </Ico>
  ),
  chevRight: (p) => <Ico {...p} d="M9 6l6 6-6 6" />,
  moon: (p) => <Ico {...p} d="M19 14.4A7.5 7.5 0 0 1 9.6 5 7.5 7.5 0 1 0 19 14.4z" />,
  sun: (p) => (
    <Ico {...p}>
      <circle cx="12" cy="12" r="3.8" />
      <path d="M12 3v2.2M12 18.8V21M3 12h2.2M18.8 12H21M5.6 5.6l1.6 1.6M16.8 16.8l1.6 1.6M18.4 5.6l-1.6 1.6M7.2 16.8l-1.6 1.6" />
    </Ico>
  ),
  dot: (p) => <Ico {...p}><circle cx="12" cy="12" r="4" fill="currentColor" stroke="none" /></Ico>,
  quote: (p) => (
    <Ico {...p}>
      <path d="M9 7.5C6.5 8.4 5 10.6 5 13.4V16h4v-4.6H7c0-1.3.8-2.4 2-2.9zM19 7.5c-2.5.9-4 3.1-4 5.9V16h4v-4.6h-2c0-1.3.8-2.4 2-2.9z" fill="currentColor" stroke="none" />
    </Ico>
  ),
  scope: (p) => (
    <Ico {...p}>
      <circle cx="12" cy="12" r="7.6" />
      <circle cx="12" cy="12" r="2.4" />
    </Ico>
  ),
  play: (p) => <Ico {...p}><path d="M8 5.5v13l11-6.5z" fill="currentColor" stroke="none" strokeLinejoin="round" /></Ico>,
  refresh: (p) => (
    <Ico {...p}>
      <path d="M19.5 11a7.5 7.5 0 1 0-1 5" />
      <path d="M19.9 5v4h-4" />
    </Ico>
  ),
  eye: (p) => (
    <Ico {...p}>
      <path d="M2.8 12S6 6 12 6s9.2 6 9.2 6-3.2 6-9.2 6-9.2-6-9.2-6z" />
      <circle cx="12" cy="12" r="2.6" />
    </Ico>
  ),
  mic: (p) => (
    <Ico {...p}>
      <rect x="9" y="3.4" width="6" height="10.8" rx="3" />
      <path d="M5.6 11.2a6.4 6.4 0 0 0 12.8 0M12 17.6v3M8.6 20.6h6.8" />
    </Ico>
  ),
  waveform: (p) => (
    <Ico {...p} sw={1.9}>
      <path d="M5 10.5v3M8.5 7v10M12 4.5v15M15.5 8v8M19 10.5v3" />
    </Ico>
  ),
};

Object.assign(window, { Ico, I });
