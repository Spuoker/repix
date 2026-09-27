# Repix

Repix takes an upscaled, recompressed picture — usually a JPEG pulled from the
internet — finds the grid of the original pixel art and gives the art back at
its native resolution: one grid cell = one pixel.

**The pixels are already in the file. JPEG only fogged them. Repix develops them.**

## Running it

**On the web:** https://spuoker.github.io/repix/ — the browser offers to
install it as an app (on a phone too); it then works without the network.

**From disk:** download `repix.html` and open it with a double click. That's all.

No installation, no server, no internet. One self-contained page of about
470 KB with the computing core (WebAssembly, ~115 KB) and the font inside. It
works on a phone too, with the same results: an Android browser opens the file
from the device; an iPhone does not run a page saved on it, so there open it by
its web link.

Drop an image onto the window or press **Open**. The grid is found by itself;
if it misses, the knobs fix it and the result updates at once. **Guide** in the
settings menu (the gear on the **Repix** plate) lists every mouse, key and
finger action.

## The four stages

The grid first, then three passes with a growing field of view, then the hand:

1. **Prepare** — each cell on its own: the grid is found, and every cell gets
   one color from its pixels. Stray pixels are weighed down, neighbouring
   cells help only where they hold the same paint.
2. **Clusters** — neighbouring cells of one paint are joined into clusters
   with one color each; the noise inside them averages out.
3. **Merge** — clusters of the same color anywhere in the work become one
   paint. Weight decides: a paint spread over five hundred cells is the
   author's, five stray cells are a leftover.
4. **Paint** — no more algorithms. Brush, fill and pipette finish what did not
   come together; paints can be copied from any picture, edited, added,
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
      template.html     the live source of the page (layout, styles, interface)
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
