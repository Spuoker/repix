# Repix

You found a piece of pixel art you love, and all the internet has left of it
is a blurry, upscaled JPEG. Repix brings it back: it finds the grid of the original
art and hands you the art at its real size — one cell, one pixel, clean enough
to edit.

**The pixels are still in the file. JPEG only fogged them. Repix develops them.**

It is also made with care. Nothing in it jumps or flickers: every button,
panel and picture moves to its place by one law of motion, like a thing with
a little weight to it — see [The engine](#the-engine).

**From the concept to this release: nine days.**

<img width="1920" height="1080" alt="Снимок экрана 2026-09-28 174003" src="https://github.com/user-attachments/assets/66da5780-752e-4f3a-9c04-9210fc2d1896" />

## Running it

**In the browser:** open https://spuoker.github.io/repix/. The browser will
offer to install it as an app, on a phone too, and then it works offline.

**From disk:** download `repix.html` and double-click it. That's it.

Nothing to install, no server, no account, no internet. It is one page of
about 630 KB with everything inside: the computing core (WebAssembly,
~118 KB) and the font. On Android, open the file right from the phone; an
iPhone won't run a saved page, so use the web link there.

## Using it

Drop a picture onto the window, or press **Open**. Repix finds the grid by
itself. If it gets it wrong, turn the knobs — the result follows at once. A
knob's field takes maths too: type `12/3` or `(2+3)*4`. **F11** gives a clean
full screen, with no browser bar sliding over the buttons. Everything the
mouse, keys and fingers can do is listed in **Guide**, in the settings menu
(the gear on the **Repix** plate).

You don't have to think about saving your progress. Close the tab, reload,
let the phone unload the page — Repix opens right where you left it, painting
and undo history included. **Save** gives you the current result as a PNG.

And make it yours: **52 themes**, each with an idea behind it, kept by
families — daylight ones, the old machines pixel art was born on, a bar with a
drink each, sodas, warm wood and tea, water and night skies, dark nights with
a story. Heart the ones you like, and the arrows flip through just those. You
can make your own themes too, save them to a file and bring them to another
browser.

## The four stages

The grid first, then three passes that look a little wider each time, then
your hand:

1. **Prepare** — each cell on its own: the grid is found, and every cell gets
   one color from its pixels. Stray pixels are weighed down, neighbouring
   cells help only where they hold the same paint.
2. **Clusters** — neighbouring cells of one paint are joined into clusters
   with one color each; the noise inside them averages out.
3. **Merge** — clusters of the same color anywhere in the work become one
   paint. Weight decides: a paint spread over five hundred cells is the
   author's, five stray cells are a leftover.
4. **Paint** — no more algorithms, your turn. Brush, fill and pipette finish
   what did not come together; paints can be copied from any picture, edited, added,
   deleted, and the unused ones cleaned out.

The left window shows any step already passed (keys `1`…`8`: source, grid,
pixels, cluster borders, clusters, paint borders, merged paints, painted
borders); the right window always shows the current stage's result.

The grid is a **map of source areas** from which colors are taken. It does not
shape the output pixel: an art pixel is always square. Moving a grid line by
hand changes *what* goes into a cell, not what the cell looks like.

## Rules the core follows

- **Pass 1 does not reduce colors.** It hands on the truest shade it can,
  noise included: noise averages out in a cluster, a lost intent of the author
  comes back from nowhere. Pass 1 is judged by error against the truth, not by
  the number of colors.
- **Thresholds are built from sources, not tuned per work.** The floor comes
  from 8-bit color, the multiple from the measured noise, the ceiling from
  how close different paints of the work come.
- **One live source per layer.** Not three variants to pick the best from.
- A threshold tuned on one work means nothing: it is measured on a bench with
  known answers — and then checked by eye.

## The engine

Repix does not sit on a UI library. It has a **framework-engine** of its own,
made for it and living inside the same page. The ideas it stands on:

- **Everything that moves goes to a goal.** A button finding its new place, a
  panel rolling into one row, a scroll, a fading hint, a theme color, the
  pictures' zoom — one law of motion for all of them: a mass on a spring with
  a damper. A new goal on the way turns it without a jerk; let go with speed,
  it glides and slows; pushed past an edge, it stretches and springs back.
- **Triggers, not recomputation.** A change is an input, its consequence is
  worked out from data before anything is painted. When nothing changes,
  nothing runs.
- **Thresholds are data.** How the panels fold at a given width is a function
  of widths measured once; where the fold would change is worked out from the
  same numbers. Crossing such a threshold lays the panel out anew — smoothly,
  even while the window is being dragged.
- **The standard is the engine's.** Every object is a description; every
  argument has one standard in one table, and a description names only what
  differs. No window has rules of its own.
- **Pixel style out of the box.** Sizes, gaps, frames and shadows are counted
  in grid pixels, and a grid pixel is a whole number of screen pixels, so
  edges stay sharp at 125% or on a phone. The font is a pixel font, the icons
  are drawn cell by cell, the pictures are shown without smoothing, and what
  comes to rest lands on the grid. Motion itself runs smoothly between the
  pixels — the style is pixel, the movement is not.

The model and the rules for working on it: [`dev/ENGINE.md`](dev/ENGINE.md).

## Building

```sh
cd dev
zig build
```

Needs only [Zig](https://ziglang.org) 0.16. It compiles the core to
WebAssembly, embeds it with the font into the page and puts the result where it belongs:

```
repix.html              the program, in the project root, kept in git
dev/zig-out/Repix.zip   repix.html with README.md, LICENSE and OFL-Tiny5.txt,
                        for a release
dev/zig-out/site/       the web site: the same page as index.html, and what
                        makes it an installable app — its description
                        (manifest), the script that keeps it for work without
                        the network (sw.js) and the app icons
```

Put the contents of `site/` on any web host (GitHub Pages will do). Opened
from there, the browser offers to install Repix: it then opens in a window of
its own, without the browser around it, and works without the network. On an
iPhone this is the only way — "Add to Home Screen" from the site.

Running needs nothing but a browser.

Why embed instead of shipping `core.wasm` next to the page: a page opened from
disk may not read a neighbouring file — browsers forbid it. One file works
everywhere: from disk, from a USB stick, from any web host, on a phone (on an
iPhone — from a web host). The cost is a third on top of the core, ~39 KB of
base64 overhead.

## What is where

The program and the workshop, apart:

```
repix.html              the program; built, never edited by hand
README.md               this description
LICENSE                 GPL-3.0
.gitignore              what git leaves out: build cache, zip, test pictures
dev/                    everything else
  ENGINE.md             the framework-engine: its model, its parts, how to
                        work on it
  build.zig             `zig build`: core -> wasm, page, zip, site
  src/
    core/               Zig, compiled to WebAssembly
      core.zig          the build root
      memory.zig        shared memory: the page asks for blocks, the core bumps a pointer
      grid.zig          grid search: the art's frame, edge profiles, step and origins
      phases.zig        one-pass step search by how well transitions agree on a phase
      pass1.zig         pass 1: image -> cells, measurements, automatic settings
      pass2.zig         pass 2: cells -> clusters
      pass3.zig         pass 3: clusters -> paints across the work, palette
    ui/
      template.html     the live source of the page: the interface and the
                        framework-engine it runs on
      pipeline.js       how the page drives the core, as pure functions; the
                        build puts it into the page, the tests import it
      worker.js         the core's own thread: the page sends it jobs and
                        stays alive while it computes
      fonts/            Tiny5, Latin letters (SIL OFL 1.1)
    site/
      manifest.webmanifest  the app's description: name, icons, a window of
                        its own, the images it opens
      sw.js             keeps the site for work without the network
    tools/
      embed.zig         puts the core, the font, its license, the pipeline and
                        the core's thread into the page
      icons.zig         the app icons of the site, made cell for cell from
                        the page's own small icon
      pack.zig          packs the release zip
  tests/
    bench.html          the test bench, runs the core from the built page
    expected.json       recorded results for the regression test
    lib/                the pipeline adapted to plain images, measures, synthetic art
    data/               your own test pictures (not in the repository)
```

## Tests

The bench tests the core embedded in `repix.html`, the very file that is
released, so run `zig build` first. A browser page may not read
files from disk, so serve the project root with any static server, e.g.

```sh
python -m http.server 8000
```

and open `http://localhost:8000/dev/tests/bench.html`.

- **Regression** needs nothing: five synthetic works, four steps, three kinds
  of damage. Every stage's result is compared with `expected.json`. When a
  change is meant to alter results, press **Record expected** and commit the
  new file.
- **Grid**, **Stages 2–3** and **Real pairs** need pictures with known
  answers. Other people's artworks are not shipped, so put your own into
  `dev/tests/data/`: `pairs.json` lists `{name, source, truth, step}`, sources
  go to `data/sources/`, the hand-made originals to `data/truth/`.
  A hand-made original is the best answer at hand, not a guaranteed truth:
  it may be off by a pixel or a shade, so a small difference from it can be
  its mistake rather than Repix's. Check such cases by eye.

## Compared with

**Pixelera Pixel Art Downscaler** looks for a whole-number factor by
periodicity. On a clean ×6 upscale it is right; at the first JPEG compression
(q=0.95) it falls back to "1×". It does not take fractional steps at all.
Repix holds a step of 6.000 on the same file down to q=0.3.

**pixeldetector** (Astropulse, MIT) — the one inside Aseprite via Retro
Diffusion. It takes peaks of a neighbour-difference profile and the median
distance between them, without searching for the origin. On our 27 pairs it
found the art size once; Repix finds 26 of 27. The bilateral weight in pass 1
was taken from there and won on both measures.

## Numbers

Grid search on 27 real pairs with hand-made answers: the median step error is
0.016%. The art size is found for 26 of 27; the miss is an 800×600 picture that
has no trace of a lattice at all.

Pass 1 run over finished art does not change a single cell — a fixed point:
with no overlap even at a wide tolerance, and with overlap at the settings the
program picks itself. Only a tolerance forced wider than the gap between a
work's own shades merges them — which is what a tolerance means.

## License

Repix — Copyright (C) 2026 Spuoker.

Repix is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed WITHOUT ANY WARRANTY. See `LICENSE`.

The Tiny5 font embedded in the page is © The Tiny5 Project Authors and stays
under the SIL Open Font License 1.1 — its text is inside repix.html
itself and in `dev/src/ui/fonts/OFL-Tiny5.txt`.
