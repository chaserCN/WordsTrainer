import { createFileRoute, Link } from "@tanstack/react-router";
import { Library, ChevronRight, CalendarDays, BarChart3, Plus } from "lucide-react";
import AmbientOrbs from "@/components/AmbientOrbs";

export const Route = createFileRoute("/decks")({
  head: () => ({
    meta: [
      { title: "Колоды — iOS 26" },
      { name: "description", content: "Список колод в стиле iOS 26 Liquid Glass." },
    ],
  }),
  component: DecksPage,
});

type Deck = {
  name: string;
  cards: number;
  lang: string;
  fresh: number;
  repeat: number;
  gradient: string;
};

const DECKS: Deck[] = [
  {
    name: "English / 1-2000",
    cards: 25,
    lang: "EN",
    fresh: 17,
    repeat: 3,
    gradient: "linear-gradient(160deg, oklch(0.75 0.15 285), oklch(0.7 0.18 330))",
  },
];

function DecksPage() {
  return (
    <main className="relative min-h-dvh overflow-hidden">
      <AmbientOrbs variant="decks" />

      <div className="relative z-10 mx-auto flex min-h-dvh w-full max-w-md flex-col px-5 pt-[max(env(safe-area-inset-top),1rem)] pb-[max(env(safe-area-inset-bottom),1rem)]">
        {/* Top bar */}
        <header className="flex items-center justify-between pt-2">
          <span className="w-8" />
          <h1 className="text-[17px] font-semibold tracking-tight text-foreground">Колоды</h1>
          <button
            type="button"
            aria-label="Добавить колоду"
            className="inline-flex h-8 w-8 items-center justify-center rounded-full active:scale-95 transition-transform"
            style={{ background: "oklch(1 0 0 / 0.08)", color: "oklch(0.85 0.05 250)" }}
          >
            <Plus className="h-4 w-4" strokeWidth={2.5} />
          </button>
        </header>

        {/* Hero */}
        <section className="mt-7">
          <h2 className="text-[40px] font-bold leading-[1.02] tracking-[-0.035em] text-foreground">
            Колоды
          </h2>
          <p className="mt-2 text-[15px] text-muted-foreground">
            Выбери активную колоду или верни отключённую в обучение.
          </p>
          <div className="mt-3 flex items-center gap-2 text-[13px] text-muted-foreground">
            <Library className="h-4 w-4" style={{ color: "oklch(0.62 0.19 255)" }} strokeWidth={2.4} />
            <span className="tabular-nums">{DECKS.length} колода</span>
          </div>
        </section>

        {/* Decks list */}
        <section className="mt-5 flex flex-col gap-3">
          {DECKS.map((d) => (
            <DeckCard key={d.name} deck={d} />
          ))}
        </section>

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

function DeckCard({ deck }: { deck: Deck }) {
  return (
    <Link
      to="/deck"
      className="surface-panel block rounded-[24px] p-4 active:scale-[0.99] transition-transform"
    >
      <div className="flex items-center gap-3">
        <span
          className="h-14 w-14 shrink-0 rounded-[16px]"
          style={{
            background:
              "linear-gradient(135deg, oklch(0.8 0.12 280), oklch(0.75 0.15 310), oklch(0.7 0.2 340))",
            boxShadow:
              "inset 0 1px 0 oklch(1 0 0 / 0.25), 0 8px 18px -8px oklch(0.5 0.2 320 / 0.55)",
          }}
        />
        <div className="min-w-0 flex-1">
          <div className="truncate text-[18px] font-bold tracking-tight text-white">
            {deck.name}
          </div>
          <div className="mt-0.5 text-[13px] text-white/55">
            {deck.cards} карточек · {deck.lang}
          </div>
        </div>
        <ChevronRight className="h-5 w-5 shrink-0 text-white/40" strokeWidth={2.5} />
      </div>
      <div className="mt-3 flex items-center gap-2">
        <Stat count={deck.fresh} label="Новые" tone="blue" />
        <span className="h-3 w-px bg-white/10" aria-hidden />
        <Stat count={deck.repeat} label="Повторить" tone="amber" />
      </div>
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
  const dot =
    tone === "blue"
      ? "oklch(0.75 0.16 240)"
      : "oklch(0.78 0.15 65)";
  return (
    <div className="inline-flex items-center gap-1.5 text-[13px]">
      <span
        className="h-1.5 w-1.5 rounded-full"
        style={{
          background: dot,
          boxShadow: `0 0 8px ${dot}`,
        }}
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
