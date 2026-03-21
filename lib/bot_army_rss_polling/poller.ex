defmodule BotArmyRssPolling.Poller do
  @moduledoc """
  GenServer that periodically polls configured RSS feeds for new items.

  Checks all configured feeds every 15 minutes, filters out seen GUIDs,
  and publishes new items to job.listings.ingest.
  """

  use GenServer
  require Logger

  alias BotArmyRssPolling.{FeedConfig, FeedFetcher, DedupFilter, NATS.Publisher}

  @check_interval_ms 900_000  # 15 minutes

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Logger.info("Starting RSS Poller - checking every #{@check_interval_ms}ms (15 minutes)")
    schedule_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    poll_feeds()
    schedule_poll()
    {:noreply, state}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @check_interval_ms)
  end

  defp poll_feeds do
    try do
      feeds = FeedConfig.feeds()
      Logger.info("Polling #{length(feeds)} RSS feeds")

      Enum.each(feeds, &poll_feed/1)
    rescue
      error ->
        Logger.error("Error polling RSS feeds: #{inspect(error)}")
    end
  end

  defp poll_feed(%{"url" => url, "company_name" => company_name, "tags" => tags} = _feed) do
    case FeedFetcher.fetch(url) do
      {:ok, items} ->
        Logger.info("Fetched #{length(items)} items from #{url}")

        new_items =
          Enum.reject(items, fn item ->
            guid = item["guid"]
            DedupFilter.seen?(guid)
          end)

        Logger.info("#{length(new_items)} new items after dedup filter")

        Enum.each(new_items, fn item ->
          DedupFilter.mark_seen(item["guid"])
          Publisher.publish_listing(item, company_name, tags)
        end)

      {:error, reason} ->
        Logger.warning("RSS poll failed for #{url}: #{inspect(reason)}")
    end
  end

  defp poll_feed(feed) do
    Logger.warning("Invalid feed configuration: #{inspect(feed)}")
  end
end
