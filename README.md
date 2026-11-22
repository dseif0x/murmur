# murmur

Turns what you say through the day into reminders, todos, events and notes.

```
 Mac / iPhone / Watch            cluster
 ┌────────────────────┐   text   ┌──────────┐  murmur.transcripts.created
 │ mic → VAD →        │ ───────▶ │  server  │ ─────────────┐
 │ Parakeet v3 (local)│  /v1     │ API + UI │              ▼
 └────────────────────┘          │          │◀─ murmur.results ─┐   NATS JetStream
                                 └────┬─────┘                    │
                                      │ Postgres         ┌───────┴──────┐
                                      └──────────────────│ worker (Cron │──▶ LiteLLM
                                                         │ Job)         │
                                                         └──────────────┘
```

- **Devices** listen (always, push-to-talk, or off), cut speech into utterances
  with voice activity detection and transcribe them **on the device** with
  Parakeet v3. Only text is uploaded, never audio. See [`mac/`](mac/) and
  [`ios/`](ios/) (iPhone).
- **Server** (`murmur serve`): `POST /v1/transcripts` for devices (bearer
  token), the web UI (items, a timeline of transcripts by day, search, runs)
  and its `/api`, and the consumer that stores worker results from NATS.
  Transcripts expire after `retentionDays`; items keep a quote of what was said.
- **Conversations:** the timeline groups each device's transcripts into
  conversations (a silence longer than `conversationGapMinutes`, default 10,
  starts a new one), with duration, word count and copy-as-Markdown.
- **Classification is optional and off by default** (`classify.enabled`).
  Off, murmur only stores what was said and shows it as conversations: no
  worker CronJob, no LLM key, no Items/Runs pages. On, the worker below
  turns transcripts into items; it only takes transcripts received after it
  was switched on, unless `classify.backfill` is true.
- **Worker** (`murmur worker`, a CronJob, every 30 minutes by default): if
  nothing new came in, it exits without calling the model (the GPU node stays
  asleep). Otherwise it sends the new transcripts and the open items to an
  OpenAI-compatible endpoint (LiteLLM) and publishes the answer, a list of
  create/update/complete/dismiss actions, on `murmur.results`.
- **NATS JetStream** carries `murmur.transcripts.created`, `murmur.results`,
  `murmur.items.created` and `murmur.items.updated`, so other things can hook
  in later. **Postgres** stores everything; no object store.

## Speakers

Both apps can attribute what was said to speakers (Settings → Speakers), on
the device with FluidAudio's CAM++ speaker-embedding model (~30 MB,
downloaded on first use):

- **Off** (default): transcripts carry no speaker.
- **Label speakers:** each transcript is marked `me` or `speaker 2`,
  `speaker 3`, … (numbered per conversation; a 10-minute silence starts over).
- **Only my voice:** only what you say is kept; other voices are recognised on
  the device and dropped before anything is uploaded.

"me" is your voice, recorded once in the app (12 seconds of reading aloud).
Only a voice fingerprint (a 192-number embedding) is stored on the device,
no audio. The server stores the label (`speaker`); the timeline shows it and
the classification worker, if enabled, knows who said what. Utterances under
a second are too short to tell and get the previous speaker if they follow
within a few seconds, otherwise none (and "only my voice" drops them).

## iPhone app

[`ios/`](ios/) is the same pipeline on the iPhone (iOS 17+): the capture,
VAD segmentation, Parakeet v3 and upload queue are compiled from the Mac app's
`Audio.swift` and `Uploader.swift`; only the UI and the app model differ.

- **Modes:** *Hold* (press and hold the button), *Tap* (tap to start, tap to
  send), *Always* (continuous listening; keeps running with the screen locked,
  orange mic indicator) and *Off*.
- **Siri, Shortcuts, Action Button:** "Record with Murmur" / "Murmur aufnehmen"
  starts a recording and opens the app; run it again (or "Stop Murmur") to
  send. For the Action Button: Settings → Action Button → Shortcut → Murmur.
- First start downloads the speech model (~600 MB). Transcripts wait on the
  phone until the server takes them; murmur.homelab is reachable at home or
  over the VPN.
- **Install:** CI (`.github/workflows/ios.yml`) builds an **unsigned** IPA:
  the `ios-latest` prerelease (from `main`) or `ios-v*` tags. Sign and install
  it with Sideloadly or AltStore/SideStore (a free Apple ID needs re-signing
  every 7 days).
- **Build locally:** `brew install xcodegen && cd ios && xcodegen generate`,
  then open `Murmur.xcodeproj` and pick your signing team.

## Deploy

```sh
helm repo add murmur https://dseif0x.github.io/murmur
helm install murmur murmur/murmur -n murmur --create-namespace \
  --set ingress.enabled=true --set ingress.host=murmur.example.com \
  --set ingestTokens.existingSecret=murmur-tokens \
  --set worker.llmApiKey.existingSecret=murmur-llm
```

The chart creates a CloudNativePG `Cluster` (needs the CNPG operator; or set
`database.cnpg.enabled=false` and `database.external.existingSecret`) and
installs NATS as a dependency. See [values.yaml](charts/murmur/values.yaml):
schedule, model, endpoint, time zone, retention, output language, extra prompt.

Secrets:

```sh
kubectl -n murmur create secret generic murmur-tokens --from-literal=tokens="$(openssl rand -hex 24)"
kubectl -n murmur create secret generic murmur-llm --from-literal=api-key=sk-...
```

## Device API

```http
POST /v1/transcripts
Authorization: Bearer <token>

{"device": "macbook", "segments": [
  {"id": "<uuid, made on the device>", "text": "…", "started_at": "2026-11-04T09:12:03+01:00",
   "ended_at": "2026-11-04T09:12:08+01:00", "language": "de", "mode": "always"}
]}
```

Ids make uploads idempotent: a retried batch doesn't duplicate anything.
`GET /v1/ping` checks a token.

## Develop

```sh
cd server && DATABASE_URL=postgres://… NATS_URL=nats://localhost:4222 go run . serve
cd server && LLM_BASE_URL=http://localhost:4000/v1 LLM_API_KEY=… go run . worker
cd web && npm i && npm run dev     # proxies /api to :8080
```
