# Sage

**An AI companion that lives next to your cursor.** Hold **Control + Option**, ask a question out loud, and Sage looks at your screen, talks you through the answer, and flies its cursor to each thing it mentions as it says it.

- "What am I looking at?" → a guided tour, with the cursor hopping between parts of the app
- "How do I export this?" → step-by-step help, pointing at each button
- "What does this error mean?" → a plain-English explanation of what's on screen

Built on macOS (SwiftUI + AppKit) with Claude for vision and reasoning.

---

## What it costs to run

| Piece | Cost |
| --- | --- |
| Claude (Sonnet 5.5) | about **$0.01 per question**, from your Anthropic credits |
| Speech-to-text | **free** (Apple, on-device) |
| Voice | **free** Mac voice, or ElevenLabs (optional; its free tier covers a demo video) |
| Server (Cloudflare Worker) | **free** tier |

Set a monthly spend limit in the [Anthropic Console](https://console.anthropic.com) (Settings → Limits). It's the best safety net against surprise bills.

---

## Setup

You need: a Mac on macOS 14.2+, **Xcode** (free in the App Store), **Node.js**, and an **Anthropic API key**.

### 1. Run the server locally

```bash
cd worker
npm install
```

Open `worker/.dev.vars` (git-ignored, never committed) and fill in your key:

```
ANTHROPIC_API_KEY=sk-ant-...
SAGE_APP_KEY=<a long random string; generate with: openssl rand -hex 24>
# ELEVENLABS_API_KEY=...   (optional)
```

Start it:

```bash
npx wrangler dev
```

Check it at http://localhost:8787/health. It should say `"claudeConfigured": true`.

### 2. Point the app at the server

Copy `config/SageSecrets.example.plist` to `leanring-buddy/App/SageSecrets.plist` (git-ignored) and set:

- `WorkerBaseURL`: `http://localhost:8787` for now
- `AppKey`: the same value as `SAGE_APP_KEY`

### 3. Build and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode: select the **leanring-buddy** scheme (the folder name is a legacy typo, the app is called Sage). Under *Signing & Capabilities*, pick your own Team (a free Apple ID works). Press **Cmd + R**.

A leaf icon appears in the menu bar. Grant the permissions it asks for, hit **Start**, and Sage introduces itself.

> **Tip:** the default Mac voices sound robotic. Download a Premium voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices (for example "Zoe (Premium)"). Sage picks the best one installed automatically.

### 4. Deploy the server (so it works off your laptop)

```bash
cd worker
npx wrangler login
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put SAGE_APP_KEY
npx wrangler secret put ELEVENLABS_API_KEY   # optional
npx wrangler deploy
```

Put the `https://sage-api.<you>.workers.dev` URL into `SageSecrets.plist` and rebuild.

---

## How it works

```
hold Control+Option ──► mic → Apple Speech (on-device) ──► transcript
                                                              │
release ──► screenshot every display ──► Worker /chat ──► Claude (streaming)
                                                              │
     ┌────────────────────────────────────────────────────────┘
     ▼
 split the stream into sentences + [POINT:x,y:label] tags
     │
     ├─► speak each sentence the moment it's complete (Mac voice or ElevenLabs)
     └─► when a sentence starts playing, fly the cursor to its tagged element
```

The Worker holds the API keys, fixes the model and prompts, checks the app key, and rate-limits each IP address, so a leaked app key can't be used as a free Claude proxy.

## Project layout

```
leanring-buddy/                Mac app (folder name is legacy; the app is Sage)
  App/                         entry point, configuration
  Companion/                   the conductor + reply parsing + permissions
  Services/                    Claude, screen capture, speech in/out, hotkey
  UI/                          menu bar panel, cursor overlay, design system
leanring-buddyTests/           unit tests (Cmd + U)
worker/                        Cloudflare Worker: /chat, /tts, prompts
config/                        example secrets file
```

See `AGENTS.md` for the full architecture notes.

## Credits

Started from [Clicky](https://github.com/farzaa/clicky) by Farza (MIT license). See `LICENSE`.
