# Content model

This document fixes the current learning-content model used by the iOS app and
the local SQLite database `flashgame.db`.

The app is early-stage, so the schema is allowed to be replaced instead of
migrated. The main source of truth is server sync; local generated SQLite test
data, when needed, is written under `.generated/test_data/Data/`.

## Storage layout

On device:

```text
Documents/Data/
  flashgame.db
  <deck-id>/
    media/
      *.mp3
      *.jpg / *.png / *.webp
```

All UUID values are stored as lowercase UUID strings. The media folder name is
the same lowercase `decks.id`.

## Database schema

### `decks`

Deck metadata.

```sql
id TEXT PRIMARY KEY NOT NULL,
status TEXT NOT NULL DEFAULT 'active',
title TEXT NOT NULL,
avatar_system_name TEXT,
avatar_media_id TEXT,
language_code TEXT NOT NULL,
new_cards_per_day INTEGER NOT NULL,
review_cards_per_day INTEGER NOT NULL
```

`avatar_media_id` points at `media_objects.id`. `avatar_system_name` is only a
fallback SF Symbol.

### `media_objects`

All deck avatars, card images, example images, word audio, and example audio are
stored through this table.

```sql
id TEXT PRIMARY KEY NOT NULL,
storage_key TEXT,
local_path TEXT,
sha256 TEXT,
mime_type TEXT,
byte_size INTEGER,
width INTEGER,
height INTEGER
```

- `status`: deck-level enable/disable switch exposed in the deck detail UI.
  `active` decks are included in normal study queues; `inactive` decks stay in
  storage but produce no standard study queue.

### `cards`

The learning unit: the word or phrase we want the user to learn.

```sql
id TEXT PRIMARY KEY NOT NULL,
deck_id TEXT NOT NULL,
status TEXT NOT NULL DEFAULT 'active',
lemma TEXT NOT NULL,
display_word TEXT NOT NULL,
part_of_speech TEXT,
translation TEXT NOT NULL,
short_definition TEXT,
memory_hint TEXT,
etymology TEXT,
usage_note TEXT,
synonym_note TEXT,
grammar_note TEXT,
notes TEXT,
image_media_id TEXT,
audio_word_media_id TEXT
```

Field meaning:

- `status`: internal content flag for imports/tooling and a future card editor.
  The current UI does not expose per-card enable/disable controls. `active`
  cards are included in normal study queues; `inactive` cards stay in the deck
  but are skipped.
- `lemma`: canonical dictionary form without article, for example `hip`, `get`.
- `display_word`: user-facing headword, for example `a hip`, `get`.
- `part_of_speech`: normalized coarse POS, for example `noun`, `verb`, `adjective`.
- `translation`: short translation shown in drills.
- `short_definition`: concise English definition.
- `memory_hint`: mnemonic or child-friendly memory hint.
- `etymology`: origin note.
- `usage_note`: usage constraints, register, common context.
- `synonym_note`: difference from close synonyms.
- `grammar_note`: imported or curated grammar note, for example `Noun, Countable`.
- `notes`: general free-form note.

### `card_examples`

Example sentence for sentence/cloze mode. For now each example has exactly one
blank.

```sql
id TEXT PRIMARY KEY NOT NULL,
card_id TEXT NOT NULL,
template TEXT NOT NULL,
answer TEXT NOT NULL,
answer_form_key TEXT,
translation TEXT,
note TEXT,
image_media_id TEXT,
audio_example_media_id TEXT,
sort_order INTEGER NOT NULL DEFAULT 0
```

Rules:

- `template` contains exactly one `{{blank}}`.
- `answer` is the exact surface form that fills the blank, for example `hips`,
  `gotten`, `gave up`, `for the sake`.
- `answer_form_key` describes the form of `answer`, not the lemma.
- Multi-word answers are allowed, but still occupy one blank.
- Current UI uses the first example by `sort_order`.
- `image_media_id` is an optional image for this concrete example. If it is
  absent, UI falls back to `cards.image_media_id`.

Example:

```text
template: She stood with her hands on her {{blank}}, waiting for an explanation.
answer: hips
answer_form_key: plural
```

### `word_forms`

Known forms of the card's lemma. Used to generate sentence-mode choices from
the user's real learning set.

```sql
card_id TEXT NOT NULL,
form_key TEXT NOT NULL,
text TEXT NOT NULL,
sort_order INTEGER NOT NULL DEFAULT 0,
PRIMARY KEY (card_id, form_key, text)
```

Standard English `form_key` values:

- Verbs: `base`, `third_person_singular`, `present_participle`, `past`,
  `past_participle`.
- Nouns: `singular`, `plural`.
- Adjectives: `base`, `comparative`, `superlative`.
- Phrases or uncategorized answers: `phrase` or `base`.

One `form_key` may have several accepted texts:

```text
get:
  base = get
  third_person_singular = gets
  present_participle = getting
  past = got
  past_participle = gotten
  past_participle = got

clothe:
  past = clothed
  past = clad
  past_participle = clothed
  past_participle = clad
```

Forms are content data. Import from Anki can seed them, but the app should not
be limited by what Anki happened to contain.

### `example_distractors`

Optional curated choices for one concrete example.

```sql
id TEXT PRIMARY KEY NOT NULL,
example_id TEXT NOT NULL,
text TEXT NOT NULL,
source_card_id TEXT,
priority INTEGER NOT NULL DEFAULT 0
```

These are overrides or additions. The normal path is generated choices from
`word_forms`.

### Progress tables

Study state is stored separately from learning content:

- `card_progress`: FSRS state per card.
- `deck_daily_usage`: daily new-card counter.
- `deck_matching_records`: best result for the matching/columns mode.
- `study_reviews`: append-only review history for activity, accuracy, and weak-card stats.

### `study_reviews`

Each SRS-affecting answer appends one row:

```sql
id TEXT PRIMARY KEY NOT NULL,
card_id TEXT NOT NULL,
deck_id TEXT NOT NULL,
mode TEXT NOT NULL,
outcome TEXT NOT NULL,
reviewed_at REAL NOT NULL,
duration_ms INTEGER,
was_new INTEGER NOT NULL,
previous_state TEXT,
new_state TEXT
```

The dashboard treats `remembered` and `correct` as passed outcomes, and
`forgot` and `incorrect` as mistakes.

## iOS models

### `WordCardContent`

Runtime card model loaded from `cards` plus its primary `card_examples`,
`word_forms`, and optional `example_distractors`.

```swift
enum ContentStatus: String, Codable, Hashable, Sendable {
    case active
    case inactive
}

struct WordCardContent: Codable, Identifiable, Hashable {
    let id: UUID
    let status: ContentStatus     // cards.status
    let word: String              // cards.display_word
    let lemma: String             // cards.lemma
    let partOfSpeech: String?
    let translation: String

    let clozePrompt: String       // currently same as clozeTemplate
    let clozeTemplate: String?    // card_examples.template
    let clozeAnswer: String?      // card_examples.answer
    let clozeExampleImageURL: URL? // card_examples.image_media_id, fallback to cards.image_media_id in loading
    let answerFormKey: String?    // card_examples.answer_form_key

    let shortDefinition: String?
    let memoryHint: String?
    let etymology: String?
    let usageNote: String?
    let synonymNote: String?
    let grammarNote: String?
    let explanation: String?      // maps to cards.notes

    let imageURL: URL?
    let audioWordURL: URL?
    let audioExampleURL: URL?

    let distractors: [String]
    let forms: [WordForm]
}
```

Important computed behavior:

- `effectiveClozeAnswer`: explicit `clozeAnswer`, then legacy `<b>...</b>`
  fallback, then headword fallback.
- `clozePromptWithGap`: renders `{{blank}}` as `___`.
- `clozePromptFilled(with:)`: fills the sentence with the selected answer.
- `clozeChoices(answerPool:)`: builds choices from real cards in the same deck.

### `WordForm`

```swift
struct WordForm: Codable, Hashable {
    let formKey: String
    let text: String
}
```

Maps directly to one row in `word_forms`.

### `DeckContent`

```swift
struct DeckContent: Identifiable, Hashable {
    let id: UUID
    var status: ContentStatus     // decks.status
    var title: String
    var avatarSystemName: String? // fallback SF Symbol
    var avatarImageURL: URL?      // resolved from decks.avatar_media_id
    var languageCode: String
    var newCardsPerDay: Int
    var reviewCardsPerDay: Int
    var cards: [WordCardContent]
}
```

Maps to `decks` plus loaded `cards`.

Normal study queues use only active decks and active cards. The current product
surface manages activity at the deck level; card-level status is stored for
imports/tooling and future card management, not for a separate "train all"
workflow.

## Sentence mode choice generation

The goal is to test the target word in context without switching the learning
focus to full-sentence translation.

For a target example:

1. Correct answer is `card_examples.answer`.
2. Manual `example_distractors` are included first if present.
3. Other cards in the same deck are scanned.
4. Cards with a `word_forms.form_key` equal to the target `answer_form_key`
   produce same-form choices first.
5. If there are not enough choices, fallback choices use `base` or `singular`.
6. Choices are deduplicated case-insensitively.
7. Presentation layer may shuffle, but the model returns the correct answer
   first before shuffling.

Example for target `hips` with `answer_form_key = plural`:

```text
correct: hips
preferred generated distractors: loads, heels, ...
fallback generated distractors: settle, cast, ...
```

This avoids semantically artificial sets like `shoulders`, `knees`, `elbows`,
`wrists` for a sentence where several could be physically possible.

## Import and generation rules

Anki is only an input source. It does not define the product model.

Import should normalize:

- `lemma (Noun, Countable)` into `lemma`, `display_word`, `part_of_speech`,
  `grammar_note`.
- `<b>answer</b>` in legacy examples into `template` plus `answer`.
- `___` examples into `template` if explicit `answer` exists.
- Generated forms into `word_forms`.

For English forms:

- Regular forms may be generated automatically.
- Common irregular forms should be explicit curated data.
- Missing forms should be filled by content tooling or manual curation, not by
  UI fallback behavior.

## Current constraints

- One blank per example.
- Multiple examples per card are supported by the database, but the current UI
  reads the first example by `sort_order`.
- No production migrations yet. Rebuild and replace the local database when the
  schema changes.
