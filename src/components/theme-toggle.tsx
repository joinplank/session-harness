"use client";

import { useSyncExternalStore } from "react";

// The root `dark` class is the single source of truth; this store re-reads it
// on the two events that change it: OS-scheme flips (delivered by the media
// query — the pre-hydration script's listener runs first, so the class is
// already updated) and our own toggles (delivered via toggleListeners).
const toggleListeners = new Set<() => void>();

function subscribe(onChange: () => void) {
  const media = window.matchMedia("(prefers-color-scheme: dark)");
  media.addEventListener("change", onChange);
  toggleListeners.add(onChange);
  return () => {
    media.removeEventListener("change", onChange);
    toggleListeners.delete(onChange);
  };
}

function isDark() {
  return document.documentElement.classList.contains("dark");
}

export function ThemeToggle() {
  // Server snapshot is "light"; React re-reads the real class right after
  // hydration, so the markup stays consistent without a hydration mismatch.
  const dark = useSyncExternalStore(subscribe, isDark, () => false);

  function toggle() {
    const next = !isDark();
    document.documentElement.classList.toggle("dark", next);
    try {
      localStorage.setItem("theme", next ? "dark" : "light");
    } catch {
      // Storage unavailable — the flip still applies to this page view; it
      // just won't persist.
    }
    for (const notify of toggleListeners) notify();
  }

  return (
    <button
      type="button"
      aria-label="Dark mode"
      aria-pressed={dark}
      onClick={toggle}
      className="fixed top-6 right-6 rounded-full border border-zinc-300 px-4 py-2 text-sm text-zinc-600 transition-colors hover:border-zinc-500 dark:border-zinc-700 dark:text-zinc-400 dark:hover:border-zinc-400"
    >
      <span aria-hidden="true">{dark ? "☾" : "☀"}</span>
    </button>
  );
}
