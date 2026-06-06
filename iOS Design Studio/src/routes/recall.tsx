import { createFileRoute, Link } from "@tanstack/react-router";
import { useState } from "react";
import { ChevronLeft, Check, X } from "lucide-react";

export const Route = createFileRoute("/recall")({
  head: () => ({
    meta: [
      { title: "Помню / Забыл — iOS 26" },
      { name: "description", content: "Карточки на запоминание в стиле iOS 26 Liquid Glass." },
    ],
  }),
  component: RecallPage,
});

const WORDS = ["lean", "thorough", "brisk", "linger", "vivid"];
const TRANSLATIONS: Record<string, string> = {
  lean: "худой, стройный",
  thorough: "тщательный",
  brisk: "бодрый, быстрый",
  linger: "задерживаться",
  vivid: "яркий, живой",
};


function RecallPage() {
  const [i, setI] = useState(0);
  const [press, setPress] = useState<"forgot" | "know" | null>(null);

  const word = WORDS[i % WORDS.length];

  const next = (which: "forgot" | "know") => {
    setPress(which);
    setTimeout(() => {
      setPress(null);
      setI((n) => n + 1);
    }, 220);
  };

  return (
    <main className="relative min-h-dvh overflow-hidden">
      {/* Ambient orbs for depth, same as MatchPairs */}
      <div
        className="ambient-orb"
        style={{ width: 360, height: 360, top: -80, left: -60, background: "oklch(0.9 0.1 30 / 0.55)" }}
      />
      <div
        className="ambient-orb"
        style={{ width: 420, height: 420, top: 40, right: -120, background: "oklch(0.88 0.12 350 / 0.5)" }}
      />
      <div
        className="ambient-orb"
        style={{ width: 460, height: 460, bottom: -140, left: -80, background: "oklch(0.9 0.1 160 / 0.45)" }}
      />
      <div
        className="ambient-orb"
        style={{ width: 380, height: 380, bottom: -100, right: -60, background: "oklch(0.88 0.1 250 / 0.5)" }}
      />

      <div className="relative z-10 mx-auto flex min-h-dvh w-full max-w-md flex-col px-5 pt-[max(env(safe-area-inset-top),1rem)] pb-[max(env(safe-area-inset-bottom),1.25rem)]">
        {/* Header */}
        <header className="flex items-center justify-between pt-2">
          <Link
            to="/"
            aria-label="Назад"
            className="glass-strong inline-flex h-11 w-11 items-center justify-center rounded-full text-foreground active:scale-95 transition-transform"
          >
            <ChevronLeft className="h-5 w-5" strokeWidth={2.5} />
          </Link>
          <h1 className="text-[17px] font-semibold tracking-tight text-foreground">
            Помню / Забыл
          </h1>
          <div className="h-11 w-11" />
        </header>

        {/* Progress */}
        <div className="mt-5 flex items-center gap-3">
          <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-[oklch(0.18_0.02_260/0.08)]">
            <div
              className="h-full rounded-full transition-[width] duration-500"
              style={{
                width: `${((i % WORDS.length) / WORDS.length) * 100 + 8}%`,
                background: "var(--gradient-progress)",
              }}
            />
          </div>
          <span className="shrink-0 text-[13px] font-semibold tabular-nums tracking-tight" style={{ color: "oklch(0.55 0.03 260)" }}>
            {i % WORDS.length + 1} / {WORDS.length}
          </span>
        </div>

        {/* Word card — deep gradient slab to stand apart from the ambient background */}
        <section className="flex flex-1 items-center justify-center py-6">
          <div
            key={word}
            className="surface-panel relative flex w-full flex-col items-center justify-center gap-4 overflow-hidden rounded-[32px] px-8 py-20 animate-in fade-in zoom-in-95 duration-300"
            style={{
              background:
                "linear-gradient(155deg, oklch(0.27 0.05 265), oklch(0.18 0.05 270) 60%, oklch(0.14 0.05 275))",
              boxShadow:
                "inset 0 1px 0 oklch(1 0 0 / 0.08), 0 24px 60px -20px oklch(0.1 0.05 270 / 0.55), 0 8px 20px -8px oklch(0.1 0.05 270 / 0.4)",
            }}
          >
            {/* soft accent halo behind the word */}
            <div
              aria-hidden
              className="pointer-events-none absolute inset-x-10 top-1/2 -z-0 h-40 -translate-y-1/2 rounded-full blur-3xl"
              style={{ background: "oklch(0.7 0.18 245 / 0.28)" }}
            />
            <span
              className="relative text-[48px] font-semibold leading-none tracking-tight"
              style={{ color: "oklch(0.99 0.01 240)" }}
            >
              {word}
            </span>
            <span
              className="relative mt-2 text-[15px] font-medium tracking-tight"
              style={{ color: "oklch(0.82 0.03 250 / 0.75)" }}
            >
              {TRANSLATIONS[word]}
            </span>
          </div>
        </section>

        {/* Action buttons */}
        <div className="grid grid-cols-2 gap-3 pb-2">
          <button
            type="button"
            onClick={() => next("forgot")}
            data-wrong={press === "forgot" ? "true" : undefined}
            className="glass-strong flex items-center justify-center gap-2.5 rounded-2xl py-3.5 transition active:scale-[0.97]"
            style={{ color: "oklch(0.58 0.22 25)" }}
          >
            <span
              className="inline-flex h-7 w-7 items-center justify-center rounded-full"
              style={{ background: "oklch(0.62 0.22 25 / 0.14)" }}
            >
              <X className="h-4 w-4" strokeWidth={2.6} />
            </span>
            <span className="text-[15px] font-semibold tracking-tight">Забыл</span>
          </button>

          <button
            type="button"
            onClick={() => next("know")}
            data-success={press === "know" ? "true" : undefined}
            className="glass-strong flex items-center justify-center gap-2.5 rounded-2xl py-3.5 transition active:scale-[0.97]"
            style={{ color: "oklch(0.42 0.14 160)" }}
          >
            <span
              className="inline-flex h-7 w-7 items-center justify-center rounded-full"
              style={{ background: "oklch(0.72 0.13 160 / 0.22)" }}
            >
              <Check className="h-4 w-4" strokeWidth={2.6} />
            </span>
            <span className="text-[15px] font-semibold tracking-tight">Помню</span>
          </button>
        </div>
      </div>
    </main>
  );
}
