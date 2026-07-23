"use client";

import { useEffect, useState } from "react";

export function ThemeToggle() {
  // null until mounted: the server can't know the theme, so the first client
  // render must match the server markup; the real state lands right after
  // hydration.
  const [dark, setDark] = useState<boolean | null>(null);

  useEffect(() => {
    const root = document.documentElement;
    setDark(root.classList.contains("dark"));
    // While no choice is stored, the pre-hydration script live-follows the OS
    // by flipping the root class; mirror those flips into button state. This
    // listener registers after that script's, so the class is already updated
    // when it reads it.
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const sync = () => setDark(root.classList.contains("dark"));
    media.addEventListener("change", sync);
    return () => media.removeEventListener("change", sync);
  }, []);

  function toggle() {
    // The root class is the single source of truth — derive from it, not from
    // the mirrored button state.
    const next = !document.documentElement.classList.contains("dark");
    document.documentElement.classList.toggle("dark", next);
    try {
      localStorage.setItem("theme", next ? "dark" : "light");
    } catch {
      // Storage unavailable (e.g. blocked) — the flip still applies to this
      // page view; it just won't persist.
    }
    setDark(next);
  }

  return (
    <button
      type="button"
      aria-label="Dark mode"
      aria-pressed={dark === true}
      onClick={toggle}
      className="fixed top-6 right-6 rounded-full border border-zinc-300 px-4 py-2 text-sm text-zinc-600 transition-colors hover:border-zinc-500 dark:border-zinc-700 dark:text-zinc-400 dark:hover:border-zinc-400"
    >
      <span aria-hidden="true">{dark ? "☾" : "☀"}</span>
    </button>
  );
}
