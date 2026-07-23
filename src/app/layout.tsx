import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "plank-harness",
  description:
    "Hello-world Next.js app wired up with the Plank interactive coding harness",
};

// Runs before the page paints (first element the parser executes), so the
// first paint already has the right theme: the stored choice wins; with no
// stored choice the OS preference applies and stays live-followed — the
// listener re-checks storage on every OS change, so it neutralizes itself
// once the user pins a theme.
const themeInit = `(function () {
  var root = document.documentElement;
  var media = window.matchMedia("(prefers-color-scheme: dark)");
  function stored() {
    try { return localStorage.getItem("theme"); } catch (e) { return null; }
  }
  function apply(dark) { root.classList.toggle("dark", dark); }
  var choice = stored();
  apply(choice ? choice === "dark" : media.matches);
  media.addEventListener("change", function (e) {
    if (!stored()) apply(e.matches);
  });
})();`;

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    // suppressHydrationWarning: the theme script legitimately mutates the
    // html class before React hydrates, so the server markup won't match.
    <html
      lang="en"
      suppressHydrationWarning
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">
        <script dangerouslySetInnerHTML={{ __html: themeInit }} />
        {children}
      </body>
    </html>
  );
}
