import { createFileRoute, Link } from "@tanstack/react-router";
import { Play, CalendarDays, Library, BarChart3, ChevronRight, RotateCw } from "lucide-react";
import userAvatar from "@/assets/user-avatar.jpg.asset.json";
import AmbientOrbs from "@/components/AmbientOrbs";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Сегодня — iOS 26" },
      { name: "description", content: "Дневная очередь карточек в стиле iOS 26 Liquid Glass." },
      { property: "og:title", content: "Сегодня" },
      { property: "og:description", content: "Закрой дневную очередь и держи ритм." },
    ],
  }),
  component: TodayPage,
});

type Deck = { name: string; due: number; fresh: number; repeat: number };
const DECKS: Deck[] = [
  { name: "English / 1-2000", due: 16, fresh: 14, repeat: 2 },
];

const TOTAL_DUE = DECKS.reduce((s, d) => s + d.due, 0);


function TodayPage() {
  return (
    <main className="relative min-h-dvh overflow-hidden">
      <AmbientOrbs variant="today" />

      <div className="relative z-10 mx-auto flex min-h-dvh w-full max-w-md flex-col px-5 pt-[max(env(safe-area-inset-top),1rem)] pb-[max(env(safe-area-inset-bottom),1rem)]">
        {/* Hero: avatar + name + sync */}
        <section className="mt-2 flex items-center gap-4">
          <UserAvatar streak={7} />
          <div className="min-w-0 flex-1">
            <h2 className="truncate text-[34px] font-bold leading-none tracking-[-0.035em] text-foreground">
              Nikolay
            </h2>
          </div>
          <SyncButton />
        </section>



        {/* Primary CTA — pastel blue like the "Новые" pill */}
        <Link
          to="/today"
          className="surface-panel mt-6 flex items-center justify-between gap-4 overflow-hidden rounded-[24px] px-6 py-6 active:scale-[0.985] transition-transform"
          style={{
            background:
              "linear-gradient(135deg, oklch(0.62 0.17 248), oklch(0.5 0.19 258))",
            boxShadow:
              "inset 0 1px 0 oklch(1 0 0 / 0.35), 0 18px 36px -14px oklch(0.4 0.22 260 / 0.65), 0 6px 14px -4px oklch(0.4 0.22 260 / 0.4)",
          }}
        >
          <div className="min-w-0">
            <div className="text-[24px] font-bold tracking-tight" style={{ color: "oklch(0.99 0.01 240)" }}>Учить сегодня</div>
            <div className="mt-1 text-[14px]" style={{ color: "oklch(0.97 0.02 240 / 0.85)" }}>{TOTAL_DUE} карточек в очереди</div>
          </div>
          <span
            className="inline-flex h-12 w-12 shrink-0 items-center justify-center rounded-full"
            style={{ background: "oklch(1 0 0 / 0.22)", boxShadow: "inset 0 1px 0 oklch(1 0 0 / 0.4)" }}
          >
            <Play className="h-5 w-5" strokeWidth={0} style={{ color: "oklch(0.99 0.01 240)", fill: "oklch(0.99 0.01 240)" }} />
          </span>
        </Link>

        {/* Decks */}
        <section className="mt-7">
          <h3 className="px-1 text-[17px] font-semibold tracking-tight text-foreground">По колодам</h3>
          <div className="mt-3 flex flex-col gap-2.5">
            {DECKS.map((d) => (
              <Link
                key={d.name}
                to="/deck"
                className="surface-panel flex flex-col gap-3 rounded-[20px] px-4 py-4 active:scale-[0.985] transition-transform"
              >
                <div className="flex items-center gap-3">
                  <span
                    className="h-[52px] w-[52px] shrink-0 rounded-[16px]"
                    style={{
                      background: "linear-gradient(135deg, oklch(0.85 0.13 320), oklch(0.7 0.18 300))",
                      boxShadow: "inset 0 1px 0 oklch(1 0 0 / 0.4), 0 8px 18px -8px oklch(0.55 0.2 310 / 0.55)",
                    }}
                  />
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-[17px] font-bold tracking-tight text-white">{d.name}</div>
                    <div className="mt-0.5 text-[13px] text-white/55">{d.due} на сегодня</div>
                  </div>
                  <ChevronRight className="h-5 w-5 shrink-0 text-white/35" strokeWidth={2.2} />
                </div>
                <div className="flex items-center gap-2.5 pl-[2px]">
                  <DeckStat count={d.fresh} label="Новые" tone="blue" />
                  <span className="h-3 w-px bg-white/12" aria-hidden />
                  <DeckStat count={d.repeat} label="Повторить" tone="amber" />
                </div>
              </Link>
            ))}
          </div>
        </section>


        {/* Bottom tab bar */}
        <nav className="mt-auto flex justify-center pt-6">
          <div className="tab-bar flex items-center gap-1 rounded-full px-2 py-2">
            <TabItem to="/" icon={<CalendarDays className="h-5 w-5" strokeWidth={2.2} />} label="Сегодня" active />
            <TabItem to="/decks" icon={<Library className="h-5 w-5" strokeWidth={2.2} />} label="Колоды" />
            <TabItem to="/stats" icon={<BarChart3 className="h-5 w-5" strokeWidth={2.2} />} label="Статистика" />
          </div>
        </nav>
      </div>
    </main>
  );
}


function SyncButton() {
  return (
    <button
      type="button"
      aria-label="Синхронизировать"
      className="inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-full active:scale-90 transition-transform"
      style={{
        background: "oklch(1 0 0 / 0.55)",
        border: "1px solid oklch(1 0 0 / 0.7)",
        boxShadow: "0 6px 16px -8px oklch(0.4 0.05 260 / 0.35), inset 0 1px 0 oklch(1 0 0 / 0.6)",
        backdropFilter: "blur(20px)",
        WebkitBackdropFilter: "blur(20px)",
        color: "oklch(0.4 0.04 260 / 0.85)",
      }}
    >
      <RotateCw className="h-[18px] w-[18px]" strokeWidth={2.6} />
    </button>
  );
}

function UserAvatar({ streak }: { streak?: number }) {
  return (
    <Link
      to="/"
      aria-label="Профиль"
      className="relative shrink-0 active:scale-95 transition-transform"
    >
      <div
        className="relative h-[68px] w-[68px] overflow-hidden rounded-full"
        style={{
          border: "2px solid oklch(1 0 0 / 0.85)",
          boxShadow:
            "0 10px 24px -10px oklch(0.4 0.05 260 / 0.4), inset 0 1px 0 oklch(1 0 0 / 0.5)",
        }}
      >
        <img
          src={userAvatar.url}
          alt="Профиль"
          className="h-full w-full object-cover"
        />
      </div>
      {streak !== undefined && (
        <span
          className="absolute -bottom-1 -right-1 flex h-5 min-w-[20px] items-center justify-center rounded-full px-1 text-[10px] font-bold leading-none text-white"
          style={{
            background: "oklch(0.65 0.23 30)",
            border: "2px solid oklch(1 0 0 / 0.95)",
            boxShadow: "0 3px 8px -2px oklch(0.4 0.1 30 / 0.5)",
          }}
        >
          {streak}
        </span>
      )}
    </Link>
  );
}

function DeckStat({ count, label, tone }: { count: number; label: string; tone: "blue" | "amber" }) {
  const dot = tone === "blue" ? "oklch(0.75 0.16 240)" : "oklch(0.78 0.15 65)";
  return (
    <div className="inline-flex items-center gap-1.5 text-[13px]">
      <span className="h-1.5 w-1.5 rounded-full" style={{ background: dot, boxShadow: `0 0 8px ${dot}` }} aria-hidden />
      <span className="font-semibold tabular-nums text-white">{count}</span>
      <span className="text-white/55">{label}</span>
    </div>
  );
}

function TabItem({ to, icon, label, active }: { to: string; icon: React.ReactNode; label: string; active?: boolean }) {
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
