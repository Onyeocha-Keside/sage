# Sage business model: B2B and B2C

Reference for anyone (human or AI agent) working on Sage's positioning, pricing, website, or deck. Sources: `docs/pitch/` (deck and speaker notes), `docs/PRODUCTION_REVIEW.md`, and the cost analysis done on 7 October 2026. Everything below is a hypothesis to test, not validated demand. Do not present it as traction.

## B2B: the decided direction

**Positioning.** "Know what to click next." Sage is an AI guide for the software a team already uses. It reads the live screen, explains by voice, and points at the next control. The user makes every click; Sage never takes control.

**Today vs. next.**
- Built today: a guide to the *interface*. Voice questions, screen interpretation, spoken answers, follow-along pointing on macOS.
- Next product direction: a guide to the team's *process*. Ground guidance in each team's approved procedures (file names, export settings, review steps, handoffs). This is the intended advantage; pointing alone is not unique. Not built yet.

**First wedge.** Mac-using agencies, teams of 10–50.
- Starting workflow: client-file preparation (export settings, naming, review, delivery).
- Buyer: owner or team lead. Users: junior staff and contractors.
- Discovery must establish: repeated training pain, permission to process screens, willingness to pay.

**Offer.**
1. Paid pilot: four weeks, five workflows, one team of 5–10 users, agreed success criteria. Price experiment: **$300–$750**.
2. Renewal: a team subscription with a monthly minimum and pooled usage. Price to test: **$15–$25 per user per month with fair use**.

**What to measure in pilots.** Correct task completion, trainer interventions, cost per workflow, and paid continuation (renewal).

**Unit economics (estimates, October 2026 list prices).**

| | Today | Production quality |
|---|---|---|
| Cost per question | ≈ $0.01 (Claude Sonnet 5.5; Mac speech and voice are free) | ≈ $0.02 (adds streaming speech-to-text and a premium voice) |
| Light user (5 questions/day, 22 days) | ≈ $1.10/month | ≈ $2.20/month |
| Typical user (15/day) | ≈ $3.30/month | ≈ $6.60/month |
| Heavy user (40/day) | ≈ $8.80/month | ≈ $17.60/month |

Each follow-along step counts as one question. A 10-person, four-week pilot uses about $70 of AI at production quality. At $15–$25 per user, a typical user leaves about 55–75% margin before payment fees. Heavy users need fair-use caps or pooled team usage.

**Fixed and one-time costs.** About $20–60/month fixed at small scale (Apple Developer $99/year, Cloudflare paid plan $5/month once past the free tier, transactional email). One-time cost to production: about $560 lean, $2,800–4,200 comfortable (founder-built; hired development excluded). The deck's costed ask is **about $1,000–$1,500**, covering a signed Mac app plus three pilots.

**Not built yet (B2B milestones, not claims):** accounts, billing, team administration, procedure ingestion, organization isolation, contractual data handling. Today's access is invite-only bearer tokens with per-account and service-wide spending limits.

**Milestone.** Three paid pilots, measured task outcomes, and evidence of renewal.

## B2C: not decided

No B2C model has been agreed. The facts that exist:

- The public landing page (sage.kesideonyeocha.com) collects a waitlist from individual Mac users. This is top-of-funnel interest, not a consumer pricing decision.
- The per-user costs above bound any consumer price: a typical individual costs about $3–7/month in AI at production quality, so a consumer plan needs a price and usage cap above that.
- The deck targets businesses. Any consumer plan must not undercut or confuse the B2B pilot story.

Open questions to settle before building any B2C feature: whether to offer an individual plan at all, its price and usage cap, free trial or free tier limits, distribution (direct download vs. Mac App Store), and whether consumer users feed the B2B funnel (for example, individuals bringing Sage into their teams).

## Rules for agents

- Treat pricing, customer profile, and pilot targets as hypotheses. Never present them as traction, interviews, or revenue.
- Keep the founder's claims to work visible in the codebase. Preserve the Clicky (MIT) attribution.
- Do not invent a B2C decision. Ask the founder first.
