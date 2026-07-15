# Paragraph Reveal Reader

## Components

- `ParagraphRevealReaderView` is the paragraph-based text reader used for sealed text sessions, sender previews, and onboarding.
- `ParagraphRevealSlideControl` owns the reusable hold-then-slide interaction for decrypting and locking one paragraph.
- `ParagraphRevealSection` renders one vertically paged paragraph section with encrypted previous/next context hints.
- `ParagraphRevealText` runs the short cryptographic scramble animation and falls back to reduced-motion text changes when required.

## State model

Reader state lives in `ParagraphRevealReaderView`:

- `activeParagraphIndex`
- `paragraphs: [ParagraphRevealItem]`
- `isTransitioning`
- `scrollPosition`
- `relocksParagraphsOnNavigation`

Each `ParagraphRevealItem` tracks:

- `id`
- `rawText`
- `isUnlocked`
- `hasBeenViewed`

The slider tracks:

- `isHolding`
- `isArmed`
- `dragProgress`
- `isCompleted`
- `mode: unlock | lock`

## Paragraph parsing

Paragraphs are split on blank lines. Single line breaks inside a paragraph are preserved so simple list formatting and existing reader markdown support still render after unlock. If parsing produces no nonempty paragraph, the reader creates one empty fallback section.

## Tuning

The hold duration and slide threshold are local constants in `ParagraphRevealSlideControl`:

- `holdDurationNanoseconds = 220_000_000`
- `completionThreshold = 0.82`

`relocksParagraphsOnNavigation` defaults to `true`, so leaving a paragraph hides it again. Set it to `false` to preserve per-paragraph unlock state during the same reader session.
