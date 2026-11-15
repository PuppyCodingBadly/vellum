# Ink annotations

Handwriting on a book page, anchored to the content rather than to a bitmap.

## Anchors

Every stroke stores an anchor plus points normalized to that anchor's rectangle
(`x/width`, `y/height`, pressure 0–1). Rendering recomputes the anchor rectangle
from the current layout and maps the points into it, so ink follows the content.

| Kind | Used for | Anchor identity | Rectangle |
|---|---|---|---|
| `text` | EPUB/MOBI body text | rendered character range (document offsets) | union of the range's line boxes |
| `page` | PDF page mode | page index | displayed page rectangle |
| `reflowBlock` | PDF reflow | block index | the rendered block's box |

Points may leave `0..1`: a note in the margin still belongs to the line it was
drawn beside.

## Interaction

- The pen button in the reader header toggles ink mode. Stylus (and mouse on
  desktop) draws; touch is never treated as ink.
- Ink mode disables scrolling and text selection so a drag draws instead of
  panning; turn it off to scroll, select, or swipe pages.
- The floating toolbar provides pen/eraser, four inks, three widths, undo,
  redo, and close. Erasing is per stroke.
- Undo/redo is per reading session and clears when the chapter changes.

## Storage

`ink_strokes(book_id, chapter, kind, start, end, rect, color, width, points,
created)` with `ON DELETE CASCADE` from `books`; points are little-endian
float32 `(x, y, pressure)` triples. The table is created by the normal
migration path for existing libraries.

## Export

`Export annotated PDF…` (PDF books in page mode, header overflow menu) rasterizes
each source page, draws the page-anchored strokes as vector paths over it, and
saves a new PDF. Text and PDF-reflow ink stay in the library: their anchors
describe a layout, not a PDF page, so there is no honest page mapping for them.
