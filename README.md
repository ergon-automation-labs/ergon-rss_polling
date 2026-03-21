# bot_army_rss_polling

RSS feed polling bot for job listing discovery. Polls configured RSS feeds every 15 minutes for new job listings.

## What It Does

1. **Polls RSS feeds** every 15 minutes (configurable)
2. **Fetches and parses** RSS 2.0 and Atom feed items using sweet_xml
3. **Filters duplicates** using in-memory ETS table
4. **Publishes new listings** to `job.listings.ingest` for ingestion by job applications bot
5. **Integrates with GTD** via job applications bot (automatic task creation on important listings)

## Feed Configuration

Feeds are configured via Salt pillar in `bot_army_infra/pillar/rss_polling.sls`:

```yaml
rss_polling:
  poll_interval_ms: 900000  # 15 minutes
  feeds:
    - url: "https://jobs.lever.co/anthropic/rss"
      company_name: "Anthropic"
      tags: ["elixir", "distributed-systems"]
    - url: "https://boards.greenhouse.io/togetherai/jobs.json"
      company_name: "Together AI"
      tags: []
```

## Architecture

- **Poller** — GenServer that triggers every 15 minutes
- **FeedFetcher** — Fetches HTTP feeds and parses XML
- **DedupFilter** — Tracks seen GUIDs in memory (ETS)
- **Publisher** — Publishes to `job.listings.ingest`
- **FeedConfig** — Reads RSS_FEEDS_JSON from environment

## Development

```bash
mix deps.get
mix compile
mix test
MIX_ENV=prod mix release
```

## Pre-Push Hook

The `.git-hooks/pre-push` hook enforces:
1. Compilation without warnings
2. All tests passing
3. Release built successfully
4. Tarball created and published to GitHub releases

Install the hook:
```bash
git config core.hooksPath git-hooks
```

## Deployment

1. Add feeds to `bot_army_infra/pillar/rss_polling.sls`
2. Push to main (triggers pre-push hook → GitHub release)
3. Jenkins downloads release and deploys via Salt
4. Watch bot logs: `tail -f /var/log/bot_army/rss_polling.log`
