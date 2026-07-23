import { ThemeToggle } from "@/components/theme-toggle";

export default function Home() {
  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-4 font-sans">
      <ThemeToggle />
      <h1 className="text-4xl font-semibold tracking-tight">Hello, world</h1>
      <p className="max-w-md text-center text-lg leading-8 text-zinc-600 dark:text-zinc-400">
        A minimal Next.js app — the substrate for the interactive coding
        harness. See <code className="font-mono text-base">harness.md</code>.
      </p>
    </main>
  );
}
