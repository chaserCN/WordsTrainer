import { useEffect, useMemo, useState } from "react";
import { ChevronLeft, Volume2, Trophy } from "lucide-react";

type Pair = { en: string; ru: string };

const PAIRS: Pair[] = [
  { en: "a hip", ru: "бедро, тазобедренный сустав" },
  { en: "cast", ru: "бросать, кидать (сеть, взгляд, тень)" },
  { en: "sweep", ru: "мести, сметать" },
  { en: "bust", ru: "сломать, разрушить" },
  { en: "load", ru: "грузить, заряжать (оружие)" },
];

type Card = { id: string; pairId: number; side: "en" | "ru"; text: string };

function shuffle<T>(arr: T[]): T[] {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

export function MatchPairs() {
  const [leftCards, setLeftCards] = useState<Card[]>(
    PAIRS.map((p, i) => ({ id: `L${i}`, pairId: i, side: "en" as const, text: p.en }))
  );
  const [rightCards, setRightCards] = useState<Card[]>(
    PAIRS.map((p, i) => ({ id: `R${i}`, pairId: i, side: "ru" as const, text: p.ru }))
  );
  const [matched, setMatched] = useState<Set<string>>(new Set());
  const [selectedLeft, setSelectedLeft] = useState<Card | null>(null);
  const [selectedRight, setSelectedRight] = useState<Card | null>(null);
  const [wrongPair, setWrongPair] = useState<[string, string] | null>(null);
  const [successPair, setSuccessPair] = useState<[string, string] | null>(null);
  const [score, setScore] = useState(36);
  const [time, setTime] = useState(33);
  const [best] = useState(57);


  useEffect(() => {
    setLeftCards(shuffle(PAIRS.map((p, i) => ({ id: `L${i}`, pairId: i, side: "en" as const, text: p.en }))));
    setRightCards(shuffle(PAIRS.map((p, i) => ({ id: `R${i}`, pairId: i, side: "ru" as const, text: p.ru }))));
  }, []);

  useEffect(() => {
    const t = setInterval(() => setTime((s) => (s > 0 ? s - 1 : 0)), 1000);
    return () => clearInterval(t);
  }, []);

  useEffect(() => {
    if (selectedLeft && selectedRight) {
      if (selectedLeft.pairId === selectedRight.pairId) {
        const ids: [string, string] = [selectedLeft.id, selectedRight.id];
        setSuccessPair(ids);
        setTimeout(() => {
          setSuccessPair(null);
          setMatched((m) => new Set([...m, ...ids]));
          setSelectedLeft(null);
          setSelectedRight(null);
          setScore((s) => Math.max(0, s - 1));
        }, 700);
      } else {
        setWrongPair([selectedLeft.id, selectedRight.id]);
        setTimeout(() => {
          setWrongPair(null);
          setSelectedLeft(null);
          setSelectedRight(null);
        }, 500);
      }
    }
  }, [selectedLeft, selectedRight]);

  const progress = useMemo(() => Math.min(100, (time / 60) * 100), [time]);

  const onPick = (card: Card) => {
    if (matched.has(card.id) || wrongPair) return;
    if (card.side === "en") setSelectedLeft(card);
    else setSelectedRight(card);
  };

  const isSelected = (c: Card) =>
    selectedLeft?.id === c.id || selectedRight?.id === c.id;
  const isWrong = (c: Card) => wrongPair?.includes(c.id) ?? false;
  const isSuccess = (c: Card) => successPair?.includes(c.id) ?? false;
  const isMatched = (c: Card) => matched.has(c.id);

  return (
    <div className="relative min-h-screen overflow-hidden pb-10">
      {/* Ambient orbs */}
      <div className="ambient-orb" style={{ background: "oklch(0.85 0.18 30)", width: 320, height: 320, top: -100, left: -80 }} />
      <div className="ambient-orb" style={{ background: "oklch(0.82 0.18 340)", width: 360, height: 360, bottom: -140, right: -100 }} />
      <div className="ambient-orb" style={{ background: "oklch(0.85 0.15 240)", width: 280, height: 280, top: "45%", left: "35%", opacity: 0.35 }} />

      <div className="relative z-10 mx-auto max-w-md px-5 pt-12">
        {/* Top nav */}
        <header className="flex items-center justify-between">
          <button className="glass flex h-10 w-10 items-center justify-center rounded-full" aria-label="Назад">
            <ChevronLeft className="h-[18px] w-[18px] text-foreground" strokeWidth={2.5} />
          </button>
          <h1 className="text-[15px] font-semibold tracking-tight text-foreground/80">Колонки</h1>
          <button className="glass flex h-10 w-10 items-center justify-center rounded-full" aria-label="Звук">
            <Volume2 className="h-[18px] w-[18px] text-foreground" strokeWidth={2.5} />
          </button>
        </header>

        {/* Title */}
        <h2 className="mt-8 text-[40px] font-bold leading-[1.02] tracking-[-0.035em] text-foreground">
          Соедини<br />пары
        </h2>

        {/* Stats */}
        <div className="mt-7 flex items-end justify-between">
          <div className="flex items-baseline gap-2">
            <span className="text-[32px] font-bold leading-none tabular-nums tracking-tight text-foreground">{score}</span>
            <span className="text-[13px] font-medium text-muted-foreground">осталось</span>
          </div>
          <span className="text-[26px] font-semibold tabular-nums tracking-tight text-foreground">
            0:{String(time).padStart(2, "0")}
          </span>
        </div>

        {/* Progress */}
        <div className="mt-3 flex items-center gap-3">
          <div className="flex items-center gap-1.5 text-muted-foreground">
            <Trophy className="h-[14px] w-[14px]" style={{ color: "var(--color-warning)" }} strokeWidth={2.5} />
            <span className="text-[13px] font-medium tabular-nums">0:{best}</span>
          </div>
          <div className="relative h-[5px] flex-1 overflow-hidden rounded-full" style={{ background: "oklch(0.18 0.02 260 / 0.08)" }}>
            <div
              className="absolute inset-y-0 left-0 rounded-full transition-[width] duration-500"
              style={{ width: `${progress}%`, background: "var(--gradient-progress)" }}
            />
          </div>
        </div>

        {/* Pairs grid */}
        <div className="mt-7 grid grid-cols-2 gap-3">
          <div className="flex flex-col gap-3">
            {leftCards.map((c) => (
              <PairButton
                key={c.id}
                card={c}
                selected={isSelected(c)}
                matched={isMatched(c)}
                success={isSuccess(c)}
                wrong={isWrong(c)}
                onClick={() => onPick(c)}
              />
            ))}
          </div>
          <div className="flex flex-col gap-3">
            {rightCards.map((c) => (
              <PairButton
                key={c.id}
                card={c}
                selected={isSelected(c)}
                matched={isMatched(c)}
                success={isSuccess(c)}
                wrong={isWrong(c)}
                onClick={() => onPick(c)}
              />
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}


function PairButton({
  card, selected, matched, success, wrong, onClick,
}: {
  card: Card; selected: boolean; matched: boolean; success: boolean; wrong: boolean; onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      data-selected={selected}
      data-matched={matched}
      data-success={success}
      data-wrong={wrong}
      className="pair-card flex min-h-[96px] items-center justify-center px-3.5 py-4 text-center"
    >
      <span className="text-[15px] font-semibold leading-tight text-card-foreground">
        {card.text}
      </span>
    </button>
  );
}
