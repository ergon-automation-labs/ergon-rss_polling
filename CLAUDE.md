# CLAUDE.md

Guidance for Claude Code when working with `bot_army_rss_polling`.

## Purpose

**bot_army_rss_polling** is the RSS feed polling bot for job listing discovery.

Polls configured RSS feeds every 15 minutes for new job listings and publishes them to `job.listings.ingest` for deduplication and ingestion by the job applications bot.

## Core Modules

- **Poller** — GenServer, polls every 15 minutes
- **FeedFetcher** — HTTP + sweet_xml RSS/Atom parsing
- **FeedConfig** — Reads RSS_FEEDS_JSON env var from Salt pillar
- **DedupFilter** — ETS-based in-memory dedup (restart = loss, fine)
- **Publisher** — Publishes to job.listings.ingest

## Development

```bash
mix deps.get
mix compile
mix test
```

## Deployment

```bash
cd ../bot_army_infra
make deploy-bot BOT=rss_polling
```

Requires:
1. RSS feed list configured in `pillar/rss_polling.sls`
2. Salt state deployed via `salt/bots/bot_army_rss_polling.sls`

## Testing

Manually test feed parsing:
```elixir
BotArmyRssPolling.FeedFetcher.fetch("https://jobs.lever.co/anthropic/rss")
```

Subscribe to listings on NATS:
```bash
nats-helper subscribe job.listings.ingest
```
