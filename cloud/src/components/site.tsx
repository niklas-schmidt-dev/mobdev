import { Link } from "@tanstack/react-router";
import { useState, type ReactNode } from "react";

export function Logo({ className = "size-7" }: { className?: string }) {
  return (
    <svg viewBox="0 0 64 64" className={className} aria-hidden="true">
      <rect width="64" height="64" rx="15" fill="#142017" />
      <g fill="#d1eda5" transform="translate(0 4) skewY(-12)">
        <rect x="16" y="28" width="8" height="22" rx="1.5" />
        <rect x="28" y="20" width="8" height="34" rx="1.5" />
        <rect x="40" y="24" width="8" height="27" rx="1.5" />
      </g>
    </svg>
  );
}

export function SiteHeader() {
  const link = "rounded-md px-3 py-1 text-[13px] text-ink/80 transition-colors hover:text-ink";
  return (
    <header className="nav-glass sticky top-0 z-40 border-b border-black/[0.06]">
      <nav className="mx-auto flex h-12 max-w-5xl items-center px-5" aria-label="Main">
        <Link to="/" className="flex items-center gap-2 text-[15px] font-semibold tracking-tight">
          <Logo className="size-6" />
          Mobdev
        </Link>
        <div className="ml-auto flex items-center">
          <Link to="/docs" className={link} activeProps={{ className: "text-ink" }}>
            Docs
          </Link>
          <a href="/#pricing" className={`${link} hidden sm:block`}>
            Pricing
          </a>
          <Link to="/dashboard" className={link}>
            Account
          </Link>
          <Link
            to="/docs"
            hash="install"
            className="ml-2 rounded-full bg-blue px-3.5 py-1 text-[13px] font-medium text-white transition-colors hover:bg-blue-hover"
          >
            Get Mobdev
          </Link>
        </div>
      </nav>
    </header>
  );
}

export function SiteFooter() {
  const heading = "mb-2.5 text-[12px] font-semibold text-ink";
  const item = "block py-1 text-[12px] text-muted transition-colors hover:text-ink";
  return (
    <footer className="bg-mist">
      <div className="mx-auto max-w-5xl px-5 py-12">
        <div className="grid grid-cols-2 gap-8 border-b border-line pb-8 sm:grid-cols-4">
          <div className="col-span-2 flex items-start gap-2.5">
            <Logo className="size-6" />
            <p className="max-w-xs text-[12px] leading-relaxed text-muted">
              Mobdev gives AI agents a real iPhone. Free and open source under the MIT license.
            </p>
          </div>
          <div>
            <p className={heading}>Product</p>
            <Link to="/" className={item}>
              Overview
            </Link>
            <Link to="/docs" className={item}>
              Docs
            </Link>
            <a href="/#pricing" className={item}>
              Pricing
            </a>
          </div>
          <div>
            <p className={heading}>Account</p>
            <Link to="/dashboard" className={item}>
              Dashboard
            </Link>
            <Link to="/privacy" className={item}>
              Privacy
            </Link>
          </div>
        </div>
        <p className="pt-6 text-[12px] text-faint">
          Not affiliated with Apple, TapKit or MobAI. iPhone and macOS are trademarks of Apple Inc.
        </p>
      </div>
    </footer>
  );
}

export function Page({ children, tone = "white" }: { children: ReactNode; tone?: "white" | "mist" }) {
  return (
    <div className={`flex min-h-dvh flex-col ${tone === "mist" ? "bg-mist" : "bg-white"}`}>
      <SiteHeader />
      <main className="flex-1">{children}</main>
      <SiteFooter />
    </div>
  );
}

export const buttonPrimary =
  "inline-flex items-center justify-center rounded-full bg-blue px-6 py-3 text-[17px] font-medium text-white transition-colors hover:bg-blue-hover disabled:opacity-50";
export const buttonSecondary =
  "inline-flex items-center justify-center rounded-full border border-blue px-6 py-3 text-[17px] font-medium text-blue transition-colors hover:bg-blue hover:text-white";
export const moreLink = "text-[17px] text-link hover:underline underline-offset-4";

export function CopyButton({ text, label = "Copy" }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      onClick={async () => {
        await navigator.clipboard.writeText(text);
        setCopied(true);
        setTimeout(() => setCopied(false), 1600);
      }}
      className="shrink-0 rounded-full bg-white/80 px-3 py-1 text-[13px] font-medium text-link shadow-sm ring-1 ring-black/5 transition-colors hover:bg-white"
    >
      <span aria-live="polite">{copied ? "Copied" : label}</span>
    </button>
  );
}

export function Code({ children, copy, surface = "mist" }: { children: string; copy?: boolean; surface?: "mist" | "white" }) {
  return (
    <div className="relative">
      {/* Inter for code too. Without contextual alternates "--" stays two hyphens. */}
      <pre
        className={`overflow-x-auto rounded-2xl p-5 pr-24 text-[14px] leading-relaxed text-ink [font-feature-settings:'calt'_0,'zero'_1] ${surface === "white" ? "bg-white" : "bg-mist"}`}
      >
        <code>{children}</code>
      </pre>
      {copy !== false && (
        <div className="absolute right-3.5 top-3.5">
          <CopyButton text={children} />
        </div>
      )}
    </div>
  );
}

type IconName = "plug" | "bluetooth" | "sparkle" | "text" | "list" | "globe" | "lock" | "bolt" | "phone";

const iconPaths: Record<IconName, ReactNode> = {
  plug: <path d="M9 3v4M15 3v4M7 7h10v4a5 5 0 0 1-10 0V7zM12 16v5" />,
  bluetooth: <path d="M7 7l10 10-5 5V2l5 5L7 17" />,
  sparkle: <path d="M12 3c.6 4.7 2.3 6.4 7 7-4.7.6-6.4 2.3-7 7-.6-4.7-2.3-6.4-7-7 4.7-.6 6.4-2.3 7-7z" />,
  text: <path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M8 10h8M8 14h5" />,
  list: <path d="M9 6h11M9 12h11M9 18h11M4.5 6h.01M4.5 12h.01M4.5 18h.01" />,
  globe: (
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="M3 12h18M12 3c2.5 2.7 3.8 5.7 3.8 9s-1.3 6.3-3.8 9c-2.5-2.7-3.8-5.7-3.8-9S9.5 5.7 12 3z" />
    </>
  ),
  lock: (
    <>
      <rect x="5" y="11" width="14" height="10" rx="2.5" />
      <path d="M8 11V8a4 4 0 0 1 8 0v3" />
    </>
  ),
  bolt: <path d="M13 3L5 13.5h6L10 21l8-10.5h-6L13 3z" />,
  phone: (
    <>
      <rect x="7" y="2.5" width="10" height="19" rx="2.5" />
      <path d="M11 18.5h2" />
    </>
  ),
};

export function Icon({ name, className = "size-7" }: { name: IconName; className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      {iconPaths[name]}
    </svg>
  );
}
