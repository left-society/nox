# Notetaker — marketing site

Pure static site. No build step. Three files + an `assets/` folder.

```
website/
  index.html     ─ markup
  style.css      ─ all styles, hand-rolled CSS
  app.js         ─ the only JS (drives the hero notch state cycle)
  assets/        ─ app icons in 4 sizes
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
- **`rsync`** — `rsync -av website/ user@host:/var/www/notetaker/`

No environment variables. No secret keys. No backend.

## Editing notes

- The hero notch cycle is in `app.js` — list of `{ state, hold }` objects.
  Add a new state by adding a `<div class="n-state n-NEW">` to the markup
  and a `.notch[data-state="NEW"] { width/height/etc }` block to the CSS.
- The screenshot ribbon copy is in the markup directly — edit `<div class="rs">` rows.
- The download links currently point to `#`; wire them to the DMG / GitHub release.
- Replace the social/source links in the footer once the GitHub repo is public.
