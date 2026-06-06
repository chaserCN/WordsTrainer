import { createFileRoute, Link } from "@tanstack/react-router";
import { useState } from "react";
import { ChevronLeft, Check, X, Volume2, RotateCcw, CalendarDays, Library, BarChart3 } from "lucide-react";
import AmbientOrbs from "@/components/AmbientOrbs";

export const Route = createFileRoute("/flashcards")({
  head: () => ({
    meta: [
      { title: "Карточки — iOS 26" },
      { name: "description", content: "Flashcards в стиле iOS 26 Liquid Glass." },
    ],
  }),
  component: FlashcardsPage,
});

type Card = {
  word: string;
  example: string;
  highlight: string;
  translation: string;
  definition: string;
  ruExample: string;
};

const CARDS: Card[] = [
  {
    word: "a burden",
    example: "The heavy taxes are a great burden for small business owners.",
    highlight: "burden",
    translation: "бремя, ноша",
    definition: "A heavy load that is difficult to carry; something that causes worry or hardship.",
    ruExample: "Высокие налоги — большое бремя для мелких предпринимателей.",
  },
  {
    word: "to linger",
    example: "The smell of coffee lingered in the kitchen all morning.",
    highlight: "lingered",
    translation: "задерживаться, сохраняться",
    definition: "To stay in a place longer than necessary; to continue to exist for a long time.",
    ruExample: "Запах кофе сохранялся на кухне всё утро.",
  },
  {
    word: "vivid",
    example: "She has a vivid memory of her first day at school.",
    highlight: "vivid",
    translation: "яркий, живой",
    definition: "Producing powerful feelings or strong, clear images in the mind.",
    ruExample: "У неё яркое воспоминание о первом дне в школе.",
  },
  {
    word: "thorough",
    example: "The doctor gave him a thorough examination.",
    highlight: "thorough",
    translation: "тщательный, всесторонний",
    definition: "Complete with regard to every detail; not superficial or partial.",
    ruExample: "Врач провёл ему тщательный осмотр.",
  },
];

function FlashcardsPage() {
  const [i, setI] = useState(0);
  const [flipped, setFlipped] = useState(false);
  const [press, setPress] = useState<"again" | "good" | null>(null);
  const card = CARDS[i % CARDS.length];
  const progress = ((i % CARDS.length) / CARDS.length) * 100 + 10;

  const next = (which: "again" | "good") => {
    setPress(which);
    setTimeout(() => {
      setPress(null);
      setFlipped(false);
      setI((n) => n + 1);
    }, 240);
  };

  const toggleFlip = () => setFlipped((f) => !f);

  const renderExample = (text: string, hl: string) => {
    const parts = text.split(new RegExp(`(${hl})`, "i"));
    return parts.map((p, idx) =>
      p.toLowerCase() === hl.toLowerCase() ? (
        <span key={idx} className="font-semibold text-white">{p}</span>
      ) : (
        <span key={idx}>{p}</span>
      )
    );
  };

  return (
    <main className="relative min-h-dvh overflow-hidden">
      <AmbientOrbs variant="flashcards" />

      <div className="relative z-10 mx-auto flex min-h-dvh w-full max-w-md flex-col px-5 pt-[max(env(safe-area-inset-top),1rem)] pb-[max(env(safe-area-inset-bottom),1rem)]">
        {/* Header */}
        <header className="flex items-center justify-between pt-2">
          <Link
            to="/"
            aria-label="Назад"
            className="glass-strong inline-flex h-11 w-11 items-center justify-center rounded-full text-foreground active:scale-95 transition-transform"
          >
            <ChevronLeft className="h-5 w-5" strokeWidth={2.5} />
          </Link>
          <h1 className="text-[17px] font-semibold tracking-tight text-foreground">Карточки</h1>
          <div className="h-11 w-11" />
        </header>

        {/* Progress */}
        <div className="mt-5 flex items-center justify-between gap-3">
          <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-[oklch(0.18_0.02_260/0.08)]">
            <div
              className="h-full rounded-full transition-[width] duration-500"
              style={{ width: `${progress}%`, background: "var(--gradient-progress)" }}
            />
          </div>
          <span className="shrink-0 text-[13px] font-semibold tabular-nums tracking-tight" style={{ color: "oklch(0.55 0.03 260)" }}>
            {i % CARDS.length + 1} / {CARDS.length}
          </span>
        </div>

        {/* Flip card area */}
        <section className="flex flex-1 items-center justify-center py-6" style={{ perspective: "1200px" }}>
          <div
            key={card.word}
            className="relative w-full"
            style={{
              aspectRatio: "4 / 5",
              transformStyle: "preserve-3d",
              transition: "transform 0.6s cubic-bezier(0.4, 0, 0.2, 1)",
              transform: flipped ? "rotateY(180deg)" : "rotateY(0deg)",
            }}
          >
            {/* FRONT — cool blue-violet */}
            <div
              className="absolute inset-0 flex flex-col overflow-hidden rounded-[28px] px-6 py-7 animate-in fade-in zoom-in-95 duration-300"
              style={{
                backfaceVisibility: "hidden",
                WebkitBackfaceVisibility: "hidden",
                background:
                  "linear-gradient(160deg, oklch(0.25 0.04 265), oklch(0.19 0.04 265) 60%, oklch(0.15 0.05 270))",
                boxShadow:
                  "inset 0 1px 0 oklch(1 0 0 / 0.06), 0 24px 60px -20px oklch(0.2 0.12 265 / 0.45), 0 8px 20px -8px oklch(0.2 0.12 265 / 0.25)",
              }}
              onClick={toggleFlip}
            >
              {/* cool corner indicator */}
              <div
                aria-hidden
                className="pointer-events-none absolute right-5 top-5 h-2.5 w-2.5 rounded-full"
                style={{ background: "oklch(0.65 0.2 245)" }}
              />
              <div
                aria-hidden
                className="pointer-events-none absolute -right-16 -top-16 h-48 w-48 rounded-full blur-3xl"
                style={{ background: "oklch(0.7 0.18 245 / 0.25)" }}
              />

              <div className="relative flex items-start justify-between gap-4">
                <h2 className="text-[22px] font-bold tracking-tight text-white">{card.word}</h2>
                <button
                  type="button"
                  aria-label="Произнести"
                  className="inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-full active:scale-95 transition-transform z-10"
                  style={{
                    background: "oklch(0.62 0.2 245 / 0.18)",
                    color: "oklch(0.78 0.18 245)",
                  }}
                  onClick={(e) => e.stopPropagation()}
                >
                  <Volume2 className="h-[18px] w-[18px]" strokeWidth={2.5} />
                </button>
              </div>

              <p className="relative mt-4 text-[20px] leading-snug text-white/85">
                {renderExample(card.example, card.highlight)}
              </p>

              <div className="mt-auto flex items-center justify-center gap-1.5 text-white/40">
                <RotateCcw className="h-3.5 w-3.5" />
                <span className="text-[13px]">Нажмите, чтобы перевернуть</span>
              </div>
            </div>

            {/* BACK — soft lilac */}
            <div
              className="absolute inset-0 flex flex-col overflow-hidden rounded-[28px] px-6 py-7 animate-in fade-in zoom-in-95 duration-300"
              style={{
                backfaceVisibility: "hidden",
                WebkitBackfaceVisibility: "hidden",
                transform: "rotateY(180deg)",
                background:
                  "linear-gradient(160deg, oklch(0.26 0.05 300), oklch(0.19 0.05 300) 60%, oklch(0.15 0.06 305))",
                boxShadow:
                  "inset 0 1px 0 oklch(1 0 0 / 0.06), 0 24px 60px -20px oklch(0.2 0.1 300 / 0.45), 0 8px 20px -8px oklch(0.2 0.1 300 / 0.25)",
              }}
              onClick={toggleFlip}
            >
              {/* lilac corner indicator */}
              <div
                aria-hidden
                className="pointer-events-none absolute right-5 top-5 h-2.5 w-2.5 rounded-full"
                style={{ background: "oklch(0.72 0.14 300)" }}
              />
              <div
                aria-hidden
                className="pointer-events-none absolute -left-16 -bottom-16 h-48 w-48 rounded-full blur-3xl"
                style={{ background: "oklch(0.65 0.18 300 / 0.22)" }}
              />

              <div className="relative flex items-start justify-between gap-4">
                <h2 className="text-[22px] font-bold tracking-tight text-white">{card.word}</h2>
                <button
                  type="button"
                  aria-label="Произнести"
                  className="inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-full active:scale-95 transition-transform z-10"
                  style={{
                    background: "oklch(0.62 0.2 245 / 0.18)",
                    color: "oklch(0.78 0.18 245)",
                  }}
                  onClick={(e) => e.stopPropagation()}
                >
                  <Volume2 className="h-[18px] w-[18px]" strokeWidth={2.5} />
                </button>
              </div>

              <div className="relative mt-5 flex flex-col gap-5">
                <div>
                  <span className="text-[12px] font-medium uppercase tracking-wider text-white/40">Перевод</span>
                  <p className="mt-1 text-[19px] font-semibold text-white">{card.translation}</p>
                </div>

                <div>
                  <span className="text-[12px] font-medium uppercase tracking-wider text-white/40">Определение</span>
                  <p className="mt-1 text-[16px] leading-relaxed text-white/80">{card.definition}</p>
                </div>

                <div>
                  <span className="text-[12px] font-medium uppercase tracking-wider text-white/40">Пример</span>
                  <p className="mt-1 text-[16px] leading-relaxed text-white/80 italic">{card.ruExample}</p>
                </div>
              </div>

              <div className="mt-auto flex items-center justify-center gap-1.5 text-white/40">
                <RotateCcw className="h-3.5 w-3.5" />
                <span className="text-[13px]">Нажмите, чтобы вернуть</span>
              </div>
            </div>
          </div>
        </section>

        {/* Action buttons — match dark card */}
        <div className="grid grid-cols-2 gap-3">
          <button
            type="button"
            onClick={() => next("again")}
            data-wrong={press === "again" ? "true" : undefined}
            className="flex items-center justify-center gap-2.5 rounded-2xl py-3.5 transition active:scale-[0.97]"
            style={{
              background:
                "linear-gradient(160deg, oklch(0.25 0.04 265), oklch(0.19 0.04 265) 60%, oklch(0.15 0.05 270))",
              boxShadow:
                "inset 0 1px 0 oklch(1 0 0 / 0.06), 0 12px 28px -14px oklch(0.2 0.12 265 / 0.45)",
              color: "oklch(0.78 0.18 25)",
            }}
          >
            <span
              className="inline-flex h-7 w-7 items-center justify-center rounded-full"
              style={{ background: "oklch(0.62 0.22 25 / 0.22)" }}
            >
              <X className="h-4 w-4" strokeWidth={2.6} />
            </span>
            <span className="text-[15px] font-semibold tracking-tight">Снова</span>
          </button>

          <button
            type="button"
            onClick={() => next("good")}
            data-success={press === "good" ? "true" : undefined}
            className="flex items-center justify-center gap-2.5 rounded-2xl py-3.5 transition active:scale-[0.97]"
            style={{
              background:
                "linear-gradient(160deg, oklch(0.25 0.04 265), oklch(0.19 0.04 265) 60%, oklch(0.15 0.05 270))",
              boxShadow:
                "inset 0 1px 0 oklch(1 0 0 / 0.06), 0 12px 28px -14px oklch(0.2 0.12 265 / 0.45)",
              color: "oklch(0.82 0.16 160)",
            }}
          >
            <span
              className="inline-flex h-7 w-7 items-center justify-center rounded-full"
              style={{ background: "oklch(0.72 0.13 160 / 0.28)" }}
            >
              <Check className="h-4 w-4" strokeWidth={2.6} />
            </span>
            <span className="text-[15px] font-semibold tracking-tight">Хорошо</span>
          </button>
        </div>

        {/* Bottom tab bar */}
        <nav className="mt-6 flex justify-center">
          <div className="tab-bar flex items-center gap-1 rounded-full px-2 py-2">
            <TabItem icon={<CalendarDays className="h-5 w-5" strokeWidth={2.2} />} label="Сегодня" />
            <TabItem icon={<Library className="h-5 w-5" strokeWidth={2.2} />} label="Колоды" active />
            <TabItem icon={<BarChart3 className="h-5 w-5" strokeWidth={2.2} />} label="Статистика" />
          </div>
        </nav>
      </div>
    </main>
  );
}

function TabItem({ icon, label, active }: { icon: React.ReactNode; label: string; active?: boolean }) {
  return (
    <button
      type="button"
      className="inline-flex flex-col items-center gap-0.5 rounded-full px-4 py-1.5 transition-colors"
      style={
        active
          ? { background: "oklch(1 0 0 / 0.6)", color: "oklch(0.62 0.2 245)" }
          : { color: "oklch(0.35 0.02 260)" }
      }
    >
      {icon}
      <span className="text-[11px] font-semibold tracking-tight">{label}</span>
    </button>
  );
}
