import { createFileRoute } from "@tanstack/react-router";
import { MatchPairs } from "@/components/MatchPairs";

export const Route = createFileRoute("/match")({
  head: () => ({
    meta: [
      { title: "Соедини пары — iOS 26" },
      { name: "description", content: "Игра «Соедини пары» в стиле iOS 26 Liquid Glass." },
    ],
  }),
  component: MatchPage,
});

function MatchPage() {
  return <MatchPairs />;
}
