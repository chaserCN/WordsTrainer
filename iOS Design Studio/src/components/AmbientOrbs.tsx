import React from "react";

type OrbDef = {
  w: number;
  h: number;
  top?: number;
  left?: number;
  right?: number;
  bottom?: number;
  color: string;
  drift: string;
  dur: string;
};

const PALETTES: Record<string, OrbDef[]> = {
  today: [
    { w: 420, h: 420, top: -120, left: -90, color: "oklch(0.9 0.1 30 / 0.5)", drift: "drift-a", dur: "24s" },
    { w: 460, h: 460, top: 40, right: -140, color: "oklch(0.88 0.12 350 / 0.45)", drift: "drift-b", dur: "30s" },
    { w: 480, h: 480, bottom: -180, left: -100, color: "oklch(0.9 0.1 160 / 0.4)", drift: "drift-c", dur: "28s" },
    { w: 420, h: 420, bottom: -140, right: -80, color: "oklch(0.88 0.1 250 / 0.5)", drift: "drift-d", dur: "32s" },
  ],
  decks: [
    { w: 400, h: 400, top: -100, left: -80, color: "oklch(0.85 0.12 280 / 0.5)", drift: "drift-a", dur: "25s" },
    { w: 440, h: 440, top: 60, right: -120, color: "oklch(0.82 0.14 310 / 0.45)", drift: "drift-b", dur: "31s" },
    { w: 460, h: 460, bottom: -160, left: -90, color: "oklch(0.8 0.15 340 / 0.4)", drift: "drift-c", dur: "27s" },
    { w: 400, h: 400, bottom: -120, right: -60, color: "oklch(0.85 0.1 250 / 0.5)", drift: "drift-d", dur: "33s" },
  ],
  stats: [
    { w: 420, h: 420, top: -110, left: -70, color: "oklch(0.86 0.1 220 / 0.5)", drift: "drift-a", dur: "26s" },
    { w: 460, h: 460, top: 50, right: -130, color: "oklch(0.84 0.12 200 / 0.45)", drift: "drift-b", dur: "29s" },
    { w: 480, h: 480, bottom: -170, left: -80, color: "oklch(0.82 0.1 180 / 0.4)", drift: "drift-c", dur: "27s" },
    { w: 420, h: 420, bottom: -130, right: -70, color: "oklch(0.86 0.1 240 / 0.5)", drift: "drift-d", dur: "34s" },
  ],
  flashcards: [
    { w: 380, h: 380, top: -90, left: -70, color: "oklch(0.9 0.1 30 / 0.55)", drift: "drift-a", dur: "22s" },
    { w: 440, h: 440, top: 20, right: -130, color: "oklch(0.88 0.12 350 / 0.5)", drift: "drift-b", dur: "28s" },
    { w: 460, h: 460, bottom: -160, left: -90, color: "oklch(0.9 0.1 160 / 0.45)", drift: "drift-c", dur: "26s" },
    { w: 400, h: 400, bottom: -120, right: -70, color: "oklch(0.88 0.1 250 / 0.5)", drift: "drift-d", dur: "30s" },
  ],
};

export default function AmbientOrbs({ variant }: { variant: keyof typeof PALETTES }) {
  const orbs = PALETTES[variant] ?? PALETTES.today;
  return (
    <>
      {orbs.map((o, i) => (
        <div
          key={i}
          className="ambient-orb"
          style={{
            width: o.w,
            height: o.h,
            top: o.top,
            left: o.left,
            right: o.right,
            bottom: o.bottom,
            background: o.color,
            animation: `${o.drift} ${o.dur} ease-in-out infinite alternate`,
            willChange: "transform",
          }}
        />
      ))}
    </>
  );
}
