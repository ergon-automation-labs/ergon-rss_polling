defmodule BotArmyRssPolling do
  @moduledoc """
  BotArmyRssPolling is a job listing discovery bot that polls RSS feeds.

  Polls configured RSS feeds every 15 minutes for new job listings and publishes
  them to the job.listings.ingest subject for deduplication and ingestion by
  the job applications bot.

  Feed configuration comes from the RSS_FEEDS_JSON environment variable,
  which is set by Salt infrastructure from the rss_polling pillar.
  """
end
