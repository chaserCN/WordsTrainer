import { createFileRoute, Link } from "@tanstack/react-router";
import { useState } from "react";
import {
  ChevronLeft,
  Check,
  X,
  Volume2,
  CalendarDays,
  Library,
  BarChart3,
} from "lucide-react";

export const Route = createFileRoute("/sentences")({
  head: () => ({
    meta: [
      { title: "Предложения — iOS 26" },
      {
        name: "description",
        content: "Подбери пропущенное слово в примере — iOS 26 Liquid Glass.",
      },
    ],
  }),
  component: SentencesPage,
});

type Question = {
  sentence: string;
  answer: string;
  options: string[];
  ru: string;
};

const QUESTIONS: Question[] = [
  {
    sentence: "The truck was carrying a heavy ___ of bricks to the construction site.",
    answer: "load",
    options: ["hip", "load", "sake", "tap"],
    ru: "Грузовик вёз тяжёлый груз кирпичей на стройплощадку.",
  },
  {
    sentence: "She turned on the ___ to fill the kettle with fresh water.",
    answer: "tap",
    options: ["tap", "hip", "load", "sake"],
    ru: "Она открыла кран, чтобы наполнить чайник свежей водой.",
  },
  {
    sentence: "He twisted his ___ while running down the stairs.",
    answer: "hip",
    options: ["sake", "tap", "hip", "load"],
    ru: "Он подвернул бедро, сбегая по лестнице.",
  },
  {
    sentence: "Please be quiet for the ___ of the sleeping baby.",
    answer: "sake",
    options: ["load", "hip", "tap", "sake"],
    ru: "Пожалуйста, потише ради спящего малыша.",
  },
];

function SentencesPage() {
  const [i, setI] = useState(0);
  const [picked, setPicked] = useState<string | null>(null);

  const q = QUESTIONS[i % QUESTIONS.length];
  const progress = ((i % QUESTIONS.length) / QUESTIONS.length) * 100 + 10;
  const isAnswered = picked !== null;
  const isCorrect = picked === q.answer;

  const next = () => {
    setPicked(null);
    setI((n) => n + 1);
  };

  const renderSentence = (text: string, hl: string) => {
    if (!isAnswered || !isCorrect) {
      // hide highlight while unanswered or when wrong
      return text;
    }
    const parts = text.split(new RegExp(`(${hl})`, "i"));
    return parts.map((p, idx) =>
      p.toLowerCase() === hl.toLowerCase() ? (
        <span key={idx} style={{ color: "oklch(0.78 0.16 155)" }} className="font-bold">
          {p}
        </span>
      ) : (
        <span key={idx}>{p}</span>
      ),
    );
  };

  return (
    <main className="relative min-h-dvh overflow-hidden">
      {/* Ambient orbs — same palette family as flashcards/deck */}
      <div className="ambient-orb" style={{ width: 380, height: 380, top: -90, left: -70, background: "oklch(0.9 0.1 30 / 0.55)" }} />
      <div className="ambient-orb" style={{ width: 440, height: 440, top: 20, right: -130, background: "oklch(0.88 0.12 350 / 0.5)" }} />
      <div className="ambient-orb" style={{ width: 460, height: 460, bottom: -160, left: -90, background: "oklch(0.9 0.1 160 / 0.45)" }} />
      <div className="ambient-orb" style={{ width: 400, height: 400, bottom: -120, right: -70, background: "oklch(0.88 0.1 250 / 0.5)" }} />

      <div className="relative z-10 mx-auto flex min-h-dvh w-full max-w-md flex-col px-5 pt-[max(env(safe-area-inset-top),1rem)] pb-[max(env(safe-area-inset-bottom),1rem)]">
        {/* Header */}
        <header className="flex items-center justify-between pt-2">
          <Link
            to="/deck"
            aria-label="Назад"
            className="glass-strong inline-flex h-11 w-11 items-center justify-center rounded-full text-foreground active:scale-95 transition-transform"
          >
            <ChevronLeft className="h-5 w-5" strokeWidth={2.5} />
          </Link>
          <h1 className="text-[17px] font-semibold tracking-tight text-foreground">
            Предложения
          </h1>
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
          <span
            className="shrink-0 text-[13px] font-semibold tabular-nums tracking-tight"
            style={{ color: "oklch(0.55 0.03 260)" }}
          >
            {(i % QUESTIONS.length) + 1} / {QUESTIONS.length}
          </span>
        </div>

        {/* Sentence card */}
        <section
          key={`s-${i}`}
          className="relative mt-5 flex items-start gap-4 overflow-hidden rounded-[24px] px-5 py-5 animate-in fade-in zoom-in-95 duration-300"
          style={{
            background:
              "linear-gradient(160deg, oklch(0.25 0.04 265), oklch(0.19 0.04 265) 60%, oklch(0.15 0.05 270))",
            boxShadow:
              "inset 0 1px 0 oklch(1 0 0 / 0.06), 0 24px 60px -20px oklch(0.2 0.12 265 / 0.45), 0 8px 20px -8px oklch(0.2 0.12 265 / 0.25)",
          }}
        >
          <div
            aria-hidden
            className="pointer-events-none absolute -right-16 -top-16 h-44 w-44 rounded-full blur-3xl"
            style={{ background: "oklch(0.7 0.18 245 / 0.25)" }}
          />
          <p className="relative flex-1 text-[19px] leading-snug text-white/90 font-medium">
            {renderSentence(q.sentence, q.answer)}
          </p>
          <button
            type="button"
            aria-label="Произнести"
            className="relative inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-full active:scale-95 transition-transform"
            style={{
              background: "oklch(0.62 0.2 245 / 0.18)",
              color: "oklch(0.78 0.18 245)",
            }}
          >
            <Volume2 className="h-[18px] w-[18px]" strokeWidth={2.5} />
          </button>
        </section>

        {/* Options — white pair-card glass, consistent with other screens */}
        <div className="mt-4 flex flex-col gap-2.5">
          {q.options.map((opt) => {
            const isPicked = picked === opt;
            const isAnswer = opt === q.answer;
            const showSuccess = isAnswered && isAnswer;
            const showWrong = isAnswered && isPicked && !isCorrect;
            const dim = isAnswered && !isAnswer && !isPicked;

            let badge: React.ReactNode = null;
            if (showWrong) {
              badge = (
                <span
                  className="inline-flex h-6 w-6 items-center justify-center rounded-full"
                  style={{ background: "oklch(0.66 0.22 25)", color: "oklch(1 0 0)" }}
                >
                  <X className="h-3.5 w-3.5" strokeWidth={3} />
                </span>
              );
            } else if (showSuccess) {
              badge = (
                <span
                  className="inline-flex h-6 w-6 items-center justify-center rounded-full"
                  style={{ background: "oklch(0.7 0.16 155)", color: "oklch(1 0 0)" }}
                >
                  <Check className="h-3.5 w-3.5" strokeWidth={3} />
                </span>
              );
            }

            return (
              <button
                key={opt}
                type="button"
                disabled={isAnswered}
                onClick={() => setPicked(opt)}
                data-success={showSuccess ? "true" : undefined}
                data-wrong={showWrong ? "true" : undefined}
                className="pair-card flex items-center justify-between px-5 py-4 text-left"
                style={{
                  opacity: dim ? 0.45 : 1,
                  color: "oklch(0.2 0.02 260)",
                }}
              >
                <span className="text-[17px] font-semibold tracking-tight">{opt}</span>
                {badge}
              </button>
            );
          })}
        </div>

        {/* Feedback + next */}
        {isAnswered && (
          <div className="mt-6 flex flex-col items-center gap-4 animate-in fade-in slide-in-from-bottom-2 duration-300">
            <p
              className="text-center text-[15px] leading-snug"
              style={{ color: "oklch(0.45 0.03 260)" }}
            >
              {q.ru}
            </p>
            <button
              type="button"
              onClick={next}
              className="inline-flex h-14 items-center justify-center gap-2 overflow-hidden rounded-full px-10 text-[17px] font-bold tracking-tight active:scale-[0.97] transition-transform"
              style={{
                background:
                  "linear-gradient(135deg, oklch(0.62 0.17 248), oklch(0.5 0.19 258))",
                color: "oklch(0.99 0.01 240)",
                boxShadow:
                  "inset 0 1px 0 oklch(1 0 0 / 0.35), 0 18px 36px -14px oklch(0.4 0.22 260 / 0.65), 0 6px 14px -4px oklch(0.4 0.22 260 / 0.4)",
              }}
            >
              Дальше
            </button>
          </div>
        )}

        {/* Bottom tab bar */}
        <nav className="mt-auto flex justify-center pt-6">
          <div className="tab-bar flex items-center gap-1 rounded-full px-2 py-2">
            <TabItem to="/" icon={<CalendarDays className="h-5 w-5" strokeWidth={2.2} />} label="Сегодня" />
            <TabItem to="/decks" icon={<Library className="h-5 w-5" strokeWidth={2.2} />} label="Колоды" active />
            <TabItem to="/stats" icon={<BarChart3 className="h-5 w-5" strokeWidth={2.2} />} label="Статистика" />
          </div>
        </nav>
      </div>
    </main>
  );
}

function TabItem({
  to,
  icon,
  label,
  active,
}: {
  to: string;
  icon: React.ReactNode;
  label: string;
  active?: boolean;
}) {
  return (
    <Link
      to={to}
      className="inline-flex flex-col items-center gap-0.5 rounded-full px-4 py-1.5 transition-colors"
      style={
        active
          ? { background: "oklch(1 0 0 / 0.6)", color: "oklch(0.62 0.2 245)" }
          : { color: "oklch(0.35 0.02 260)" }
      }
    >
      {icon}
      <span className="text-[11px] font-semibold tracking-tight">{label}</span>
    </Link>
  );
}
