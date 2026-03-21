defmodule BotArmyRssPolling.DedupFilter do
  @moduledoc """
  ETS-based deduplication filter for RSS feed items.

  Tracks GUIDs of items that have already been published to avoid
  duplicates within a single bot run. Uses in-memory ETS table.

  Note: Deduplication is lost on bot restart. The job_applications bot
  performs content-based deduplication on ingest, so re-publishing dupes
  on restart is acceptable.
  """

  use GenServer
  require Logger

  @table_name :rss_seen_guids

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Logger.info("Starting RSS dedup filter")
    :ets.new(@table_name, [:set, :public, :named_table])
    {:ok, %{}}
  end

  @doc """
  Check if a feed item GUID has already been processed.
  """
  def seen?(guid) do
    :ets.member(@table_name, guid)
  end

  @doc """
  Mark a feed item GUID as processed.
  """
  def mark_seen(guid) do
    :ets.insert(@table_name, {guid, true})
  end
end
