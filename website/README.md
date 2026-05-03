# nox — marketing site

Pure static site for **nox** (nox.app). No build step. Three files + an `assets/` folder.

```
website/
  index.html     ─ markup
  style.css      ─ all styles, hand-rolled CSS
  app.js         ─ the only JS (drives the hero halo state cycle)
  assets/        ─ app icons in 4 sizes, dock glyphs, demo videos
```

## Run locally

```bash
cd website
python3 -m http.server 8765
# → http://localhost:8765/
```

## Deploy

Drop the contents of `website/` onto any static host:

- **Vercel** — `vercel deploy --cwd website` (or drag the folder into the dashboard)
- **Netlify** — `netlify deploy --dir website --prod`
- **GitHub Pages** — push, set Pages source to `/website`
- **Cloudflare Pages** — connect repo, set output dir to `website`
- **`rsync`** — `rsync -av website/ user@host:/var/www/nox/`

No environment variables. No secret keys. No backend.

## Brand

- **Name:** `nox` (always lowercase, never "Nox", never "NOX")
- **Domain:** `nox.app`
- **Mark:** thin lavender ring with a notch cut from the top — see `Notetaker/Resources/nox-icon.svg` for the authoritative source. The site inlines a smaller variant in `index.html`.
- **Palette (locked):** lavender `#C5A3FF` accents on a pure-black canvas. No other hues. All values are CSS custom properties on `:root`.

## Editing notes

- The hero halo cycle is in `app.js` — list of `{ state, hold }` objects.
  Add a new state by adding a `<div class="n-state n-NEW">` to the markup
  and a `.notch[data-state="NEW"] { width/height/etc }` block to the CSS.
- The screenshot ribbon copy is in the markup directly.
- The download links currently point to a `mailto:` for beta access; wire them to the DMG / GitHub release on launch.
- Replace the source link in the footer once the GitHub repo is public.
