# The engine

Repix is not built on a UI library. It runs on its own **framework-engine**,
written for it and living in `src/ui/template.html`. Two halves, one file:

- **The framework** says *how an object is written*. Every object is a
  **description** (built by `buildNode`); every argument of a description has
  a **standard** in one table, `STANDARD`; a description names only what
  differs. There are no local rules: nothing is special-cased for one window.
- **The engine** says *how it is carried out*. One law of motion for
  everything, decisions worked out from data, and triggers instead of
  recomputation.

## The model

1. **Everything that moves goes to a goal.** A thing is told where to be; from
   where it is drawn *now* it goes there, frame by frame. A new goal on the way
   just turns it. The hand gives goals too — a finger holds what it drags under
   itself, a bar pulls its scroll by a spring with play.
2. **One law.** A mass on a spring with a damper (`STANDARD.follow`: `ms` —
   the pace, `stiff`, `damping`, `arrive`, `least` — the least speed,
   `fastest`, `gather` — how fast speed is gathered). Place, a shelf's height,
   a scroll, opacity, a theme color, the pictures' view — all on this law.
   Something let go with speed **glides**: it loses a share of its speed each
   millisecond and ends where that takes it, never speeding up.
3. **The standard is the engine's; an object differs by arguments.** A new
   feature goes into the engine for every object that may need it, never into
   one window.
4. **Triggers, not recomputation.** A change of the page is an input; its
   consequence is worked out from data before anything is painted. Nothing is
   recomputed every frame, nothing is looked over "just in case".
5. **Thresholds are data.** A layout decision (how many rows the knobs take,
   which labels are shortened, whether a row rolls, whether the stage block
   stands as a column) is a function of the room, worked out from widths
   measured once. Its **band** — the rooms where the same would be decided — is
   worked out from the same data. Crossing an edge of a band is the trigger;
   it lays out that field anew, and the change goes smoothly.
6. **An object is on a leash to its area.** Its place is kept in its parent's
   content; an area that does not change inside moves everything in it with
   itself. The backing (the page's own background) never moves.
7. **The window.** While the window is dragged, things follow it at once —
   except a shelf whose state turns at a threshold, and things that declare
   their own pace after the window (`follow.window`).
8. **Pixel style.** Everything is measured in grid pixels (`--unit`): a grid
   pixel is a whole number of screen pixels, chosen by the window's width and
   rounded for the screen's density. The font is a pixel font, icons are
   drawn cell by cell, pictures are drawn without smoothing on whole screen
   pixels, and what comes to rest (a floating window, a placed thing) lands
   on the grid. Motion runs between pixels: the style is pixel, the movement
   is smooth.

## The machinery

| Part | What it does |
|---|---|
| `STANDARD` | every standard in one place: follow, scroll, stretch, appear/vanish, tint, view, knob |
| `approach` | one step of the law, in small sub-steps (stable at any pace) |
| channels (`channel`, `aim`) | a kind of motion is one record: `least`, `args`, `read`, `draw`, `done`; a value is a number or a list of numbers moved along its straight line; `glide` for a let-go |
| `settle(touched)` | turns a change of the page into motion: new places from the layout, offsets from where things are drawn |
| `smoothly(change)` | a named change: where everything is drawn is noted before it |
| the watcher | a `MutationObserver`: every change of the page is an input; shown/hidden is judged over the whole batch |
| goals (`goal`, `stick`, `placeTo`) | a place by what a thing is against: an object, its area, the window; side, gap, align, size, limits; a thing never leaves its area |
| scrolls (`makeScroll`, ways, `makeBar`) | the engine's own scroll: wheel by notches, a bar on a spring with play, a finger under itself, inertia, rubber at the edges; several scrolls can be one way with one bar |
| `packClusters` | the fold of a field for any room, from data; its band |

## Arguments of a description

The layout: `even`, `clip`, `hug`, `fill`, `align`, `pinned`.
Motion: `follow` (`false` — stands at once; `{ms, stiff, damping, …}` — its
own pace; `{window:{ms}}` — its pace after the window), `fades`, `appear`,
`vanish`. Place: `goal`, `stick`. Scroll: `scrolls` (`false` — never a
scroll). Shelves: `slides`, `rolls`, `squeezes`, `ribbon`. Knobs: `knob`
with its rule — `math`, `outside`, `multiple`, `round`, `forbid`.

Each argument is described where the engine carries it out; its standard is
in `STANDARD`.

## Working on it

- **Edit `src/ui/template.html`**, never `repix.html` (it is built).
  Build with `zig build` in `dev/`.
- **A feature goes into the engine**, with a standard and an argument —
  then used everywhere it fits. Check every place that uses it, not one.
- **No per-frame work, no looking over the page.** Find the trigger; make the
  consequence one action. A threshold is a number worked out from measured
  data, never a band one pixel wide.
- **Measure, don't guess.** Before and after a change of the layout, compare
  where every object stands at several window sizes; they must match unless
  the change means otherwise.
- **Rows by the layout, not by the drawing.** A thing on its way is drawn off
  its place; tell rows apart by where the layout puts it (`laidTop`).
- **Testing in a hidden browser tab lies.** A tab that is not painted runs
  no animation frames and no `ResizeObserver`: call what they would call, in
  the order a real frame does (resize events → animation frames → layout →
  size observers → paint), or force real frames (a screenshot paints).
