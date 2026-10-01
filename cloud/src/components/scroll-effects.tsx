import { useEffect, useRef, type ReactNode } from "react";

/**
 * Scroll-linked touches for the home page below the 3D story. All of them leave the page as it is
 * rendered on the server until they run, and do nothing when the visitor prefers reduced motion.
 */

const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/** Runs `update` once now and on every animation frame in which the page scrolled or resized. */
function useScrollFrame(update: () => void, enabled = true) {
  const latest = useRef(update);
  latest.current = update;
  useEffect(() => {
    if (!enabled || reducedMotion()) return;
    let scheduled = 0;
    const run = () => {
      scheduled = 0;
      latest.current();
    };
    const schedule = () => {
      if (!scheduled) scheduled = requestAnimationFrame(run);
    };
    run();
    window.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule);
    return () => {
      cancelAnimationFrame(scheduled);
      window.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
    };
  }, [enabled]);
}

/**
 * Fades and lifts every `[data-reveal]` element on the page as it scrolls into view. Elements
 * already on screen stay as they are, so nothing blinks after hydration.
 */
export function useReveal() {
  useEffect(() => {
    if (reducedMotion()) return;
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          entry.target.classList.add("revealed");
          observer.unobserve(entry.target);
        }
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.12 },
    );
    for (const element of document.querySelectorAll<HTMLElement>("[data-reveal]")) {
      if (element.getBoundingClientRect().top < window.innerHeight) continue;
      element.classList.add("reveal-armed");
      observer.observe(element);
    }
    return () => observer.disconnect();
  }, []);
}

/** Tips its content back like a screen opening towards the reader as it scrolls into view. */
export function Tilt({ children }: { children: ReactNode }) {
  const element = useRef<HTMLDivElement>(null);
  useScrollFrame(() => {
    const node = element.current;
    if (!node) return;
    const rect = node.getBoundingClientRect();
    const height = window.innerHeight;
    const progress = Math.min(1, Math.max(0, (height - rect.top) / (height * 0.75)));
    const eased = 1 - (1 - progress) ** 3;
    node.style.transform = `rotateX(${(1 - eased) * 28}deg) scale(${0.86 + eased * 0.14})`;
  });
  return (
    <div className="[perspective:1600px]">
      <div ref={element} className="origin-bottom will-change-transform">
        {children}
      </div>
    </div>
  );
}

/**
 * A statement whose words light up one after another as it scrolls through the viewport. Each
 * entry of `parts` is plain text, split into words, a node that lights up as one, or "\n" for a line break.
 */
export function LitText({ parts, className }: { parts: (string | ReactNode)[]; className?: string }) {
  const element = useRef<HTMLParagraphElement>(null);
  useScrollFrame(() => {
    const node = element.current;
    if (!node) return;
    const words = node.querySelectorAll<HTMLElement>("[data-word]");
    const rect = node.getBoundingClientRect();
    const height = window.innerHeight;
    // From the statement's top at 85% of the viewport to its bottom at 45%.
    const progress = (height * 0.85 - rect.top) / (rect.height + height * 0.4);
    words.forEach((word, i) => {
      const lit = Math.min(1, Math.max(0, progress * (words.length + 2) - i));
      word.style.opacity = String(0.2 + lit * 0.8);
    });
  });
  let key = 0;
  return (
    <p ref={element} className={className}>
      {parts.map((part) =>
        part === "\n" ? (
          <br key={key++} />
        ) : typeof part === "string" ? (
          part.split(/(\s+)/).map((word) =>
            /^\s+$/.test(word) || word === "" ? (
              word
            ) : (
              <span key={key++} data-word="" className="transition-opacity duration-150">
                {word}
              </span>
            ),
          )
        ) : (
          <span key={key++} data-word="" className="transition-opacity duration-150">
            {part}
          </span>
        ),
      )}
    </p>
  );
}
