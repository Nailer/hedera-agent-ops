# Brand assets

Sources are the SVGs; the PNGs are rendered from them with `rsvg-convert`. Edit the SVG, never the
PNG.

```bash
rsvg-convert -w 400  -h 400 logo.svg  -o logo-400.png
rsvg-convert -w 1500 -h 500 cover.svg -o cover-1500x500.png
```

## The mark

An agent — the solid centre — wrapped in its own record. The outer rings are broken arcs that follow
the circumference, with uneven runs and gaps, like entries written to a ledger over time. The
unbroken inner ring is the boundary the agent acts inside: the spend policy, enforced on chain, solid
where the record is intermittent.

An earlier version used radial spokes and read unmistakably as a sun. Anything radiating from a
centre dot will. Following the circumference is what makes it read as a record instead.

## Palette

Taken from the app's own theme in `packages/nextjs/styles/globals.css`, not invented:

| Token | Hex |
| --- | --- |
| charcoal (ground) | `#11151d` |
| ultraviolet | `#8259ef` |
| violet | `#4f46e5` |
| cobalt | `#2d84eb` |
| smoke (secondary text) | `#9b9b9d` |

## Sizes

- `logo-400.png` — X avatar. X crops avatars to a circle, so nothing sits outside the inscribed
  circle.
- `cover-1500x500.png` — X header. X overlays the avatar onto the lower left, roughly `x < 260`,
  `y > 385`, so that corner is deliberately empty. Keep it empty.
- `logo-48-legibility-check.png` — not for upload. It exists to check the mark still reads at
  timeline size before shipping a change.
