import { Link } from "@tanstack/react-router";
import { useState, type ReactNode } from "react";

export function Logo({ className = "size-7" }: { className?: string }) {
  return (
    <svg viewBox="0 0 64 64" className={className} aria-hidden="true">
      <rect width="64" height="64" rx="15" fill="#142017" />
      <rect width="63" height="63" x="0.5" y="0.5" rx="14.5" fill="none" stroke="white" strokeOpacity="0.14" />
      <g fill="#d1eda5" transform="translate(0 4) skewY(-12)">
        <rect x="16" y="28" width="8" height="22" rx="1.5" />
        <rect x="28" y="20" width="8" height="34" rx="1.5" />
        <rect x="40" y="24" width="8" height="27" rx="1.5" />
      </g>
    </svg>
  );
}

export function SiteHeader() {
  return (
    <header className="sticky top-0 z-40 border-b border-white/5 bg-ink/70 backdrop-blur-xl">
      <nav className="mx-auto flex h-14 max-w-6xl items-center gap-6 px-5" aria-label="Main">
        <Link to="/" className="flex items-center gap-2.5 font-display text-[15px] font-semibold tracking-tight">
          <Logo className="size-6" />
          Mobdev
        </Link>
        <div className="ml-auto flex items-center gap-1 text-sm text-muted">
          <Link to="/docs" className="rounded-full px-3 py-1.5 transition hover:text-paper" activeProps={{ className: "text-paper" }}>
            Docs
          </Link>
          <a href="/#pricing" className="hidden rounded-full px-3 py-1.5 transition hover:text-paper sm:block">
            Pricing
          </a>
          <Link
            to="/dashboard"
            className="ml-2 rounded-full bg-paper px-4 py-1.5 font-medium text-ink transition hover:bg-white"
          >
            Dashboard
          </Link>
        </div>
      </nav>
    </header>
  );
}

export function SiteFooter() {
  return (
    <footer className="border-t border-white/5">
      <div className="mx-auto flex max-w-6xl flex-col gap-6 px-5 py-10 text-sm text-faint sm:flex-row sm:items-center">
        <div className="flex items-center gap-2.5">
          <Logo className="size-5" />
          <span>Mobdev · MIT licensed · Not affiliated with Apple, TapKit or MobAI</span>
        </div>
        <div className="flex gap-5 sm:ml-auto">
          <Link to="/docs" className="hover:text-paper">
            Docs
          </Link>
          <Link to="/privacy" className="hover:text-paper">
            Privacy
          </Link>
          <Link to="/dashboard" className="hover:text-paper">
            Dashboard
          </Link>
        </div>
      </div>
    </footer>
  );
}

export function Page({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-dvh flex-col">
      <SiteHeader />
      <main className="flex-1">{children}</main>
      <SiteFooter />
    </div>
  );
}

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
      className="glass shrink-0 rounded-full px-3 py-1 text-xs font-medium text-paper transition hover:bg-white/10"
    >
      <span aria-live="polite">{copied ? "Copied" : label}</span>
    </button>
  );
}

export function Code({ children, copy }: { children: string; copy?: boolean }) {
  return (
    <div className="group relative">
      <pre className="overflow-x-auto rounded-2xl border border-white/10 bg-black/40 p-4 pr-20 font-mono text-[13px] leading-relaxed text-paper/90">
        <code>{children}</code>
      </pre>
      {copy !== false && (
        <div className="absolute right-3 top-3">
          <CopyButton text={children} />
        </div>
      )}
    </div>
  );
}
