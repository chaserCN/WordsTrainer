import { createFileRoute, Link } from "@tanstack/react-router";
import { CalendarDays, Library, BarChart3, RotateCw } from "lucide-react";
import AmbientOrbs from "@/components/AmbientOrbs";

export const Route = createFileRoute("/stats")({
  head: () => ({
    meta: [
      { title: "Статистика — iOS 26" },
      { name: "description", content: "Регулярность, объём и ближайшие повторения." },
    ],
  }),
  component: StatsPage,
});

type Metric = { label: string; value: string; sub: string };
const METRICS: Metric[] = [
  { label: "Сегодня", value: "15", sub: "карточек" },
  { label: "7 дней", value: "15", sub: "карточек" },
  { label: "30 дней", value: "15", sub: "карточек" },
  { label: "Дни занятий", value: "1", sub: "за 30 дней" },
];

// Activity heatmap — 4 months × 7 weekdays
const MONTHS = ["Март", "Апрель", "Май", "Июнь"];
const WEEKDAYS = ["П", "В", "С", "Ч", "П", "С", "В"];

function seededIntensity(seed: number): number {
  const x = Math.sin(seed * 9301 + 49297) * 233280;
  const r = x - Math.floor(x);
  if (r < 0.35) return 0;
  if (r < 0.55) return 1;
  if (r < 0.78) return 2;
  if (r < 0.93) return 3;
  return 4;
}
const HEAT_LEVELS: Record<number, string> = {
  0: "oklch(0.32 0.02 265 / 0.5)",
  1: "oklch(0.55 0.1 235 / 0.55)",
  2: "oklch(0.65 0.15 235 / 0.75)",
  3: "oklch(0.72 0.18 235 / 0.9)",
  4: "oklch(0.8 0.2 235)",
};

const WEEK: { day: string; count: number }[] = [
  { day: "06-01", count: 2 },
  { day: "06-02", count: 2 },
  { day: "06-03", count: 0 },
  { day: "06-04", count: 0 },
  { day: "06-05", count: 4 },
  { day: "06-06", count: 0 },
  { day: "06-07", count: 0 },
];

const FORGOTTEN: { en: string; ru: string }[] = [
  { en: "a load", ru: "груз, ноша, бремя" },
  { en: "a cigarette butt", ru: "окурок" },
  { en: "a burden", ru: "бремя, ноша" },
];

function StatsPage() {
  const maxCount = Math.max(...WEEK.map((w) => w.count), 1);

  return (
    <main className="relative min-h-dvh overflow-hidden">
      <AmbientOrbs variant="stats" />

      <div className="relative z-10 mx-auto flex min-h-dvh w-full max-w-md flex-col px-5 pt-[max(env(safe-area-inset-top),1rem)] pb-[max(env(safe-area-inset-bottom),1rem)]">
        {/* Top bar */}
        <header className="flex items-center justify-center pt-2">
          <h1 className="text-[17px] font-semibold tracking-tight text-foreground">Статистика</h1>
        </header>

        {/* Hero */}
        <section className="mt-7">
          <h2 className="text-[40px] font-bold leading-[1.02] tracking-[-0.035em] text-foreground">
            Статистика
          </h2>
          <p className="mt-2 text-[15px] text-muted-foreground">
            Регулярность, объём и ближайшие повторения.
          </p>
        </section>

        {/* Metrics grid */}
        <section className="mt-5 grid grid-cols-2 gap-3">
          {METRICS.map((m) => (
            <MetricCard key={m.label} {...m} />
          ))}
        </section>

        {/* Activity heatmap */}
        <section className="surface-panel mt-6 rounded-[24px] px-5 py-5">
          <div className="flex items-baseline justify-between">
            <h3 className="text-[17px] font-semibold tracking-tight text-white">Активность</h3>
            <span className="text-[12px] text-white/55">4 мес.</span>
          </div>

          <div className="mt-4 grid grid-cols-4 gap-3">
            {MONTHS.map((m, mi) => (
              <div key={m} className="min-w-0">
                <div className="truncate text-[11px] font-medium text-white/75">{m}</div>
                <div className="mt-1.5 flex gap-[3px] text-[9px] text-white/45">
                  {WEEKDAYS.map((d, di) => (
                    <span key={`${m}-h-${di}`} className="flex-1 text-center">{d}</span>
                  ))}
                </div>
                <div className="mt-1.5 grid grid-cols-7 gap-[3px]">
                  {Array.from({ length: 7 * 5 }).map((_, i) => {
                    const isToday = mi === 3 && i === 7;
                    const level = seededIntensity(mi * 100 + i);
                    return (
                      <span
                        key={i}
                        className="aspect-square rounded-[4px]"
                        style={
                          isToday
                            ? {
                                background: "oklch(0.78 0.2 235)",
                                boxShadow:
                                  "0 0 0 1.5px oklch(1 0 0 / 0.9), 0 0 10px oklch(0.7 0.18 235 / 0.6)",
                              }
                            : { background: HEAT_LEVELS[level] }
                        }
                      />
                    );
                  })}
                </div>
              </div>
            ))}
          </div>
        </section>

        {/* Week plan */}
        <section className="mt-6">
          <h3 className="mb-3 text-[20px] font-bold tracking-tight text-foreground">
            План на неделю
          </h3>
          <div className="surface-panel rounded-[24px] p-4">
            <div className="flex flex-col gap-2.5">
              {WEEK.map((w) => (
                <div key={w.day} className="flex items-center gap-3">
                  <span
                    className="w-12 shrink-0 text-[13px] tabular-nums"
                    style={{ color: "oklch(0.82 0.03 250 / 0.7)" }}
                  >
                    {w.day}
                  </span>

                  <div className="relative h-2 flex-1 overflow-hidden rounded-full bg-[oklch(1_0_0/0.08)]">
                    <div
                      className="absolute inset-y-0 left-0 rounded-full transition-[width] duration-500"
                      style={{
                        width: `${Math.max((w.count / maxCount) * 100, w.count > 0 ? 6 : 2)}%`,
                        background:
                          "linear-gradient(90deg, oklch(0.78 0.14 235), oklch(0.7 0.18 245))",
                        boxShadow: w.count > 0 ? "0 0 14px -2px oklch(0.7 0.18 245 / 0.55)" : "none",
                      }}
                    />
                  </div>
                  <span
                    className="w-4 shrink-0 text-right text-[14px] font-semibold tabular-nums"
                    style={{ color: "oklch(0.97 0.01 240)" }}
                  >
                    {w.count}
                  </span>

                </div>
              ))}
            </div>
          </div>
        </section>

        {/* Often forgotten */}
        <section className="mt-6">
          <h3 className="mb-3 text-[20px] font-bold tracking-tight text-foreground">
            Часто забываемые
          </h3>
          <div className="flex flex-col gap-2.5">
            {FORGOTTEN.map((f) => (
              <ForgottenRow key={f.en} {...f} />
            ))}
          </div>
        </section>

        {/* Bottom tab bar */}
        <nav className="mt-auto flex justify-center pt-6">
          <div className="tab-bar flex items-center gap-1 rounded-full px-2 py-2">
            <TabItem to="/" icon={<CalendarDays className="h-5 w-5" strokeWidth={2.2} />} label="Сегодня" />
            <TabItem to="/decks" icon={<Library className="h-5 w-5" strokeWidth={2.2} />} label="Колоды" />
            <TabItem to="/stats" icon={<BarChart3 className="h-5 w-5" strokeWidth={2.2} />} label="Статистика" active />
          </div>
        </nav>
      </div>
    </main>
  );
}

function MetricCard({ label, value, sub }: Metric) {
  return (
    <div className="surface-panel flex flex-col gap-1 rounded-[20px] p-4">
      <span className="text-[13px] font-medium" style={{ color: "oklch(0.82 0.03 250 / 0.7)" }}>
        {label}
      </span>
      <span
        className="text-[32px] font-bold leading-none tracking-tight"
        style={{ color: "oklch(0.99 0.01 240)" }}
      >
        {value}
      </span>
      <span className="text-[13px]" style={{ color: "oklch(0.82 0.03 250 / 0.65)" }}>
        {sub}
      </span>
    </div>
  );
}


function ForgottenRow({ en, ru }: { en: string; ru: string }) {
  return (
    <div className="surface-panel flex items-center gap-3 rounded-[20px] px-4 py-3">
      <div className="min-w-0 flex-1">
        <div
          className="truncate text-[16px] font-semibold tracking-tight"
          style={{ color: "oklch(0.99 0.01 240)" }}
        >
          {en}
        </div>
        <div className="truncate text-[13px]" style={{ color: "oklch(0.82 0.03 250 / 0.65)" }}>
          {ru}
        </div>
      </div>

      <button
        type="button"
        aria-label={`Повторить ${en}`}
        className="inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-full active:scale-95 transition-transform"
        style={{
          background: "oklch(0.62 0.2 245 / 0.18)",
          color: "oklch(0.78 0.14 235)",
          boxShadow: "inset 0 1px 0 oklch(1 0 0 / 0.12)",
        }}
      >
        <RotateCw className="h-4 w-4" strokeWidth={2.5} />
      </button>
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
