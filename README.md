# n8n-stack — production infrastructure for a multilingual Messenger assistant

Docker Compose definition and operational tooling for a single self-hosted
[n8n](https://n8n.io) instance running an automated Facebook Messenger
assistant deployed across **98 pages in three languages**
(French, Italian, Spanish).

This repository is the infrastructure half of the system. The workflows
themselves live in Postgres, which is deliberate. The reasoning behind nearly
every setting is in the comments of [`docker-compose.yml`](docker-compose.yml)
and the scripts.

> Identifiers (domain, origin IP, webhook path, workflow and page IDs) have
> been replaced with placeholders. Secrets, backups, the assistant's prompt and
> the original migration export are excluded — see [`.gitignore`](.gitignore).

## Scale

Measured on 2026-08-25, a representative day:

| | |
|---|---|
| Facebook webhook events received | **61,336** (peak day: 168,101) |
| Inbound user messages | **10,653** |
| AI replies sent | **9,160** |
| Scheduled follow-ups sent | **1,889** |
| New conversations | **1,915** |
| Peak throughput measured | **20,196 executions/hour** |

Roughly 84% of inbound events are delivery receipts, read receipts and echoes
that terminate immediately — a distinction that matters a lot when sizing the
queue and reading the metrics.

Totals as of 2026-11-17:

| | |
|---|---|
| Connected pages | **98** (64 French, 30 Italian, 4 Spanish) |
| People in conversation | **22,305** |
| Messages stored | **218,466** |
| Scheduled follow-ups delivered | **20,781** |
| Executions of the main workflow | **2.2 million+** (counted since 2026-07-23) |

Host: 2 vCPU / 3.7 GiB RAM, plus 2 GiB of swap. Every container is
memory-capped; the sum is deliberately tracked against physical RAM.

## Architecture

```
Cloudflare ──► nginx (host, TLS) ──► n8n main ──► Redis (Bull queue) ──► n8n worker
                                         │                                    │
                                         └──────────► Postgres 16 ◄───────────┘
                                              (workflows, credentials,
                                               conversation state)
```

`EXECUTIONS_MODE=queue`: main accepts webhooks and enqueues; the worker runs
every workflow at `--concurrency=50`. Scaling is
`docker compose up -d --scale n8n-worker=N`, bounded by
`8 + 16×workers < max_connections`.

The origin accepts 80/443 **only** from published Cloudflare ranges, refreshed
by a monthly cron job that updates both the firewall and nginx's
`set_real_ip_from` list.

## Engineering decisions worth reading about

**A 25-second message-grouping window.** People send "hi", "how are you", "you
there" as three separate messages. A leader-election pattern in Postgres
(`INSERT … ON CONFLICT DO NOTHING`) elects one execution per user to batch
them, so the assistant answers once instead of three times. The 25 seconds is
load-bearing in three other settings — container stop grace period, graceful
shutdown timeout, and worker concurrency — and the file says so, because
changing one without the others drops conversations mid-sentence.

**Zero-downtime configuration changes.** `docker compose up -d` recreates
containers and kills every conversation inside its grouping window. Polling for
an empty window and recreating in the gap cost **zero** dropped conversations.
Workflow changes go further: writing both `workflow_entity` and
`workflow_history` in one transaction takes effect on `COMMIT` with no restart
at all.

**Trust the running system, not the files.** Three separate times, config on
disk was not what was running — a missing environment variable is invisible in
a file diff and reads as absent-because-default. One such gap cost 1,698
connection timeouts and 410 dropped webhooks. The fix is to ask the running
system (`docker inspect`, `SHOW max_connections`) instead of reading the file.

**Prompt caching depends on variable position.** All interpolated variables sit
in a `## Context` block at the very end of the system prompt. With them near
the top, the shared static prefix was ~59 tokens and caching never engaged.

**Reading a failed execution.** n8n stores execution data flattened and
deduplicated — every string lives once in a top-level array and every field
holds its *index*. Grepping returns `"message": "38"`, which looks like
corruption and is not.

## Layout

| Path | What it is |
|---|---|
| `docker-compose.yml` | the stack; heavily commented with the reasoning per setting |
| `backup.sh` | nightly encrypted backup; refuses to run if the key and volume disagree |
| `cleanup-buffer.sh` | daily cleanup of abandoned message-buffer rows |
| `firewall-cloudflare.sh` | rebuilds firewall rules from the live Cloudflare ranges |
| `refresh-cloudflare-ips.sh` | monthly range refresh, updates firewall *and* nginx |
| `rotate-key.sh` | encryption key rotation (human-run) |
| `nginx/n8n.conf` | reference copy of the host nginx site |

Comments in the scripts and compose file are in Romanian.

## Notes

There is no build, test or lint step here, and no application code: this
repository is a Compose definition plus operational shell scripts. The workflow
logic lives in the database.
