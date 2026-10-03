# Sage landing page

Plain HTML, CSS and JavaScript in `website/sage/`. No build step.

- `index.html`: compact hero, waitlist, animated demo, and footer. The Mac "screenshot" is regular HTML, designed at 1280×800 and scaled to fit.
- `privacy.html`: privacy and waitlist data details.
- `styles.css`: the cream and sage design system, the Mac mock (menu bar, window, Dock, notification), and responsive and reduced-motion rules.
- `script.js`: scales the Mac, plays a controlled follow-along demo with optional bundled Mac voice clips, a focused mobile crop, and waitlist timeout handling, and posts waitlist signups.

## Preview

Double-click `website/sage/index.html`, or serve it locally:

```bash
cd website && python3 -m http.server 8099
# open http://localhost:8099/sage/
```

## Waitlist

Signups go to the Sage Worker's `POST /waitlist` route and are stored in Cloudflare KV (free). The Worker only accepts them from `kesideonyeocha.com`, `localhost`, `*.pages.dev`, and pages opened from disk.

See who signed up:

- **Dashboard (no code):** Cloudflare dashboard → Storage & databases → KV → **WAITLIST**. Each `signup:<email>` row holds the platform (mac/windows), the signup time, and which site it came from.
- **Spreadsheet:** `cd worker && ./scripts/export-waitlist.sh > waitlist.csv`, then open `waitlist.csv` in Excel or Numbers.

## Deploy

Hosted on Cloudflare Pages (project `sage-landing`) at **https://sage.kesideonyeocha.com**, also reachable at https://sage-landing-4zo.pages.dev.

Publish changes (run from the `website` folder, which has no wrangler config of its own):

```bash
cd website
../worker/node_modules/.bin/wrangler pages deploy sage --project-name sage-landing --branch main
```

DNS: the domain is registered at GoDaddy. The `sage` subdomain is a CNAME record pointing to `sage-landing-4zo.pages.dev`. The main domain still points to the portfolio on Vercel.

If the site moves to another address, add it to `WAITLIST_ALLOWED_ORIGINS` in `worker/src/index.ts` and redeploy the Worker.

`mobile.css` reflows both editors into a 420×560 stage for phone widths. Canva panels fit the stage; Excel focuses on Invoice, Client, and Status. Desktop layouts stay at 1280×800.
