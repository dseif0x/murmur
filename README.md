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
  Parakeet v3. Only text is uploaded, never audio. See [`mac/`](mac/).
- **Server** (`murmur serve`): `POST /v1/transcripts` for devices (bearer
  token), the web UI (items, a timeline of transcripts by day, search, runs)
  and its `/api`, and the consumer that stores worker results from NATS.
  Transcripts expire after `retentionDays`; items keep a quote of what was said.
- **Worker** (`murmur worker`, a CronJob, every 30 minutes by default): if
  nothing new came in, it exits without calling the model (the GPU node stays
  asleep). Otherwise it sends the new transcripts and the open items to an
  OpenAI-compatible endpoint (LiteLLM) and publishes the answer, a list of
  create/update/complete/dismiss actions, on `murmur.results`.
- **NATS JetStream** carries `murmur.transcripts.created`, `murmur.results`,
  `murmur.items.created` and `murmur.items.updated`, so other things can hook
  in later. **Postgres** stores everything; no object store.

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
