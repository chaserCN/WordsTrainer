import Foundation

/// Selects and tracks matching-column pairs without showing two senses of the same lemma at once.
struct MatchingPairScheduler: Sendable {
    static let slotCount = 5

    private(set) var visible: [MatchingPair] = []
    private(set) var pool: [MatchingPair]

    var remainingCount: Int { visible.count + pool.count }
    var isFinished: Bool { visible.isEmpty && pool.isEmpty }

    init(pairs: [MatchingPair], rng: inout some RandomNumberGenerator) {
        pool = pairs
        pool.shuffle(using: &rng)
        seedVisible(rng: &rng)
    }

    mutating func removeMatched(id: String, rng: inout some RandomNumberGenerator) {
        guard let slotIndex = visible.firstIndex(where: { $0.id == id }) else { return }

        visible.remove(at: slotIndex)

        if let next = pickNext(rng: &rng) {
            visible.insert(next, at: min(slotIndex, visible.count))
        }

        while visible.count < Self.slotCount {
            guard let next = pickNext(rng: &rng) else { break }
            visible.append(next)
        }
    }

    func pair(id: String) -> MatchingPair? {
        visible.first(where: { $0.id == id })
            ?? pool.first(where: { $0.id == id })
    }

    mutating func updateProgress(senseID: UUID, progress: CardProgress) {
        for index in visible.indices where visible[index].senseID == senseID {
            visible[index].progress = progress
        }
        for index in pool.indices where pool[index].senseID == senseID {
            pool[index].progress = progress
        }
    }

    /// Visible pairs must not share the same source card.
    var visibleCardIDsAreUnique: Bool {
        let cardIDs = visible.map(\.cardID)
        return Set(cardIDs).count == cardIDs.count
    }

    /// Visible pairs must not share the same lemma, even if they come from different cards.
    var visibleLemmasAreUnique: Bool {
        let lemmas = visible.map(\.lemmaKey)
        return Set(lemmas).count == lemmas.count
    }

    mutating func pickNext(rng: inout some RandomNumberGenerator) -> MatchingPair? {
        guard !pool.isEmpty else { return nil }

        let visibleCardIDs = Set(visible.map(\.cardID))
        let visibleLemmaKeys = Set(visible.map(\.lemmaKey))
        let eligible = pool.indices.filter {
            !visibleCardIDs.contains(pool[$0].cardID)
                && !visibleLemmaKeys.contains(pool[$0].lemmaKey)
        }

        if let index = eligible.randomElement(using: &rng) {
            return pool.remove(at: index)
        }

        if visible.isEmpty, let index = pool.indices.randomElement(using: &rng) {
            return pool.remove(at: index)
        }

        return nil
    }

    private mutating func seedVisible(rng: inout some RandomNumberGenerator) {
        while visible.count < Self.slotCount {
            guard let pair = pickNext(rng: &rng) else { break }
            visible.append(pair)
        }
    }
}

private extension MatchingPair {
    var lemmaKey: String {
        card.lemma.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension MatchingPairScheduler {
    /// Builds a scheduler with a deterministic shuffle for tests.
    static func forTesting(
        pairs: [MatchingPair],
        seed: UInt64
    ) -> MatchingPairScheduler {
        var rng = SeededRNG(seed: seed)
        return MatchingPairScheduler(pairs: pairs, rng: &rng)
    }
}

/// Deterministic RNG for unit tests.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
