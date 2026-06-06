import { createFileRoute, Link } from "@tanstack/react-router";
import {
  ChevronLeft,
  ChevronRight,
  Check,
  Layers,
  Quote,
  Columns2,
  Eye,
  CalendarDays,
  Library,
  BarChart3,
} from "lucide-react";

export const Route = createFileRoute("/deck")({
  head: () => ({
    meta: [
      { title: "English / 1-2000 — iOS 26" },
      { name: "description", content: "Колода и упражнения в стиле iOS 26 Liquid Glass." },
    ],
  }),
  component: DeckPage,
});

const DECK = {
  name: "English / 1-2000",
  cards: 25,
  lang: "EN",
  fresh: 17,
  repeat: 3,
  gradient: "linear-gradient(160deg, oklch(0.75 0.15 285), oklch(0.7 0.18 330))",
};

function DeckPage() {
  return (
    <main className="relative min-h-dvh overflow-hidden">
      <div className="ambient-orb" style={{ width: 420, height: 420, top: -120, left: -90, background: "oklch(0.9 0.1 30 / 0.5)" }} />
      <div className="ambient-orb" style={{ width: 460, height: 460, top: 40, right: -140, background: "oklch(0.88 0.12 350 / 0.45)" }} />
      <div className="ambient-orb" style={{ width: 480, height: 480, bottom: -180, left: -100, background: "oklch(0.9 0.1 160 / 0.4)" }} />
      <div className="ambient-orb" style={{ width: 420, height: 420, bottom: -140, right: -80, background: "oklch(0.88 0.1 250 / 0.5)" }} />

      <div className="relative z-10 mx-auto flex min-h-dvh w-full max-w-md flex-col px-5 pt-[max(env(safe-area-inset-top),1rem)] pb-[max(env(safe-area-inset-bottom),1rem)]">
        {/* Top bar */}
        <header className="relative flex items-center justify-center pt-2">
          <Link
            to="/decks"
            aria-label="Назад"
            className="absolute left-0 inline-flex h-9 w-9 items-center justify-center rounded-full active:scale-95 transition-transform"
            style={{
              background: "oklch(1 0 0 / 0.08)",
              color: "oklch(0.78 0.18 235)",
              border: "0.5px solid oklch(1 0 0 / 0.08)",
            }}
          >
            <ChevronLeft className="h-5 w-5" strokeWidth={2.5} />
          </Link>
          <h1 className="text-[17px] font-semibold tracking-tight text-foreground">{DECK.name}</h1>
        </header>

        {/* Deck summary card */}
        <section className="surface-panel mt-5 rounded-[24px] p-4">
          <div className="flex items-center gap-3">
            <span
              className="h-14 w-14 shrink-0 rounded-[16px]"
              style={{
                background: DECK.gradient,
                boxShadow:
                  "inset 0 1px 0 oklch(1 0 0 / 0.25), 0 8px 18px -8px oklch(0.5 0.2 320 / 0.55)",
              }}
            />
            <div className="min-w-0 flex-1">
              <div className="truncate text-[18px] font-bold tracking-tight text-white">{DECK.name}</div>
              <div className="mt-0.5 text-[13px] text-white/55">
                {DECK.cards} карточек · {DECK.lang}
              </div>
            </div>
          </div>
          <div className="mt-3 flex items-center gap-2">
            <Stat count={DECK.fresh} label="Новые" tone="blue" />
            <span className="h-3 w-px bg-white/10" aria-hidden />
            <Stat count={DECK.repeat} label="Повторить" tone="amber" />
          </div>
        </section>

        {/* Status */}
        <section className="surface-panel mt-4 flex items-center gap-3 rounded-[24px] px-4 py-4">
          <span
            className="inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-full"
            style={{
              background: "oklch(0.72 0.18 150)",
              boxShadow: "inset 0 1px 0 oklch(1 0 0 / 0.35), 0 6px 14px -6px oklch(0.55 0.18 150 / 0.5)",
            }}
          >
            <Check className="h-5 w-5 text-white" strokeWidth={3} />
          </span>
          <div className="min-w-0 flex-1">
            <div className="text-[15px] font-bold leading-tight text-white">Колода включена</div>
            <div className="mt-0.5 text-[12px] text-white/55">Карточки участвуют в повторениях.</div>
          </div>
          <button
            type="button"
            className="shrink-0 rounded-full px-4 py-2 text-[13px] font-semibold active:scale-95 transition-transform"
            style={{
              background: "oklch(1 0 0 / 0.06)",
              color: "oklch(0.78 0.16 55)",
              border: "0.5px solid oklch(0.78 0.16 55 / 0.35)",
            }}
          >
            Отключить
          </button>
        </section>

        {/* Exercises */}
        <SectionHeader title="Упражнения" subtitle="36 пар осталось · 20 карточек в очереди" />

        <div className="flex flex-col gap-2.5">
          <ExerciseRow
            to="/flashcards"
            icon={<Layers className="h-5 w-5" strokeWidth={2.4} />}
            iconBg="oklch(0.6 0.18 45)"
            iconShadow="oklch(0.55 0.18 45 / 0.5)"
            title="Карточки"
            subtitle="Слово, перевод и заметки — переворот по тапу"
          />
          <ExerciseRow
            to="/sentences"
            icon={<Quote className="h-5 w-5" strokeWidth={2.4} />}
            iconBg="oklch(0.62 0.18 250)"
            iconShadow="oklch(0.55 0.18 250 / 0.5)"
            title="Предложения"
            subtitle="Выбери слово для примера с пропуском"
          />
          <ExerciseRow
            to="/match"
            icon={<Columns2 className="h-5 w-5" strokeWidth={2.4} />}
            iconBg="oklch(0.65 0.18 150)"
            iconShadow="oklch(0.55 0.18 150 / 0.5)"
            title="Колонки"
            subtitle="Соедини слово и перевод"
          />
        </div>

        {/* Recall section */}
        <SectionHeader title="Помню / Забыл" subtitle="25 карточек в очереди" />

        <div className="flex flex-col gap-2.5 pb-4">
          <ExerciseRow
            to="/recall"
            icon={<Eye className="h-5 w-5" strokeWidth={2.4} />}
            iconBg="oklch(0.65 0.22 320)"
            iconShadow="oklch(0.55 0.22 320 / 0.55)"
            title="Быстрый проход"
            subtitle="Покажи слово и отметь: помню или забыл"
          />
        </div>

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

function SectionHeader({ title, subtitle }: { title: string; subtitle: string }) {
  return (
    <div className="mt-7 mb-3 px-1">
      <h2 className="text-[26px] font-bold tracking-tight text-foreground">{title}</h2>
      <p className="mt-1 text-[13px] text-muted-foreground">{subtitle}</p>
    </div>
  );
}

function ExerciseRow({
  to,
  icon,
  iconBg,
  iconShadow,
  title,
  subtitle,
}: {
  to: string;
  icon: React.ReactNode;
  iconBg: string;
  iconShadow: string;
  title: string;
  subtitle: string;
}) {
  return (
    <Link
      to={to}
      className="surface-panel flex items-center gap-3 rounded-[20px] px-4 py-4 active:scale-[0.99] transition-transform"
    >
      <span
        className="inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-white"
        style={{
          background: iconBg,
          boxShadow: `inset 0 1px 0 oklch(1 0 0 / 0.3), 0 8px 18px -8px ${iconShadow}`,
        }}
      >
        {icon}
      </span>
      <div className="min-w-0 flex-1">
        <div className="text-[16px] font-bold leading-tight text-white">{title}</div>
        <div className="mt-1 text-[12.5px] leading-snug text-white/55">{subtitle}</div>
      </div>
      <ChevronRight className="h-5 w-5 shrink-0 text-white/35" strokeWidth={2.2} />
    </Link>
  );
}

function Stat({
  count,
  label,
  tone,
}: {
  count: number;
  label: string;
  tone: "blue" | "amber";
}) {
  const dot = tone === "blue" ? "oklch(0.75 0.16 240)" : "oklch(0.78 0.15 65)";
  return (
    <div className="inline-flex items-center gap-1.5 text-[13px]">
      <span
        className="h-1.5 w-1.5 rounded-full"
        style={{ background: dot, boxShadow: `0 0 8px ${dot}` }}
        aria-hidden
      />
      <span className="font-semibold tabular-nums text-white">{count}</span>
      <span className="text-white/55">{label}</span>
    </div>
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
          : { color: "oklch(0.7 0.04 260)" }
      }
    >
      {icon}
      <span className="text-[11px] font-semibold tracking-tight">{label}</span>
    </Link>
  );
}
