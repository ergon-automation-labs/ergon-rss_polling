defmodule BotArmyRssPolling.Poller do
  @moduledoc """
  GenServer that polls the configured RSS feeds for new items.

  A poll runs in its own task, so this process stays responsive while feeds are
  fetched and items are scored. Only one poll runs at a time: a tick that finds a poll
  still running logs it and skips, rather than starting a second.

  The first poll runs at startup, then every 15 minutes. `progress/0` reports when the
  last poll started and finished, so a stuck poll shows up as an old finish time.
  """

  use GenServer
  require Logger

  alias BotArmyRssPolling.{FeedConfig, FeedFetcher, DedupFilter, NATS.Publisher, Sieve}

  # 15 minutes
  @check_interval_ms 900_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "When the last poll started and finished, and whether one is running now."
  def progress(server \\ __MODULE__), do: GenServer.call(server, :progress)

  @impl true
  def init(_) do
    Logger.info("Starting RSS Poller - first poll now, then every #{@check_interval_ms}ms")

    state = %{
      polling: false,
      last_started_at: nil,
      last_finished_at: nil,
      polls_completed: 0,
      last_error: nil
    }

    # The first poll runs at startup. (Before, the first poll waited a full interval.)
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %{polling: true} = state) do
    Logger.warning("RSS poll still running; skipping this tick")
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    me = self()
    started = now_ms()

    Task.start(fn ->
      result = run_poll()
      GenServer.cast(me, {:poll_done, started, result})
    end)

    schedule_poll()
    {:noreply, %{state | polling: true, last_started_at: started}}
  end

  @impl true
  def handle_cast({:poll_done, started, result}, state) do
    error = if result == :ok, do: nil, else: result

    {:noreply,
     %{
       state
       | polling: false,
         last_started_at: started,
         last_finished_at: now_ms(),
         polls_completed: state.polls_completed + 1,
         last_error: error
     }}
  end

  @impl true
  def handle_call(:progress, _from, state) do
    {:reply,
     %{
       polling: state.polling,
       last_started_at: iso(state.last_started_at),
       last_finished_at: iso(state.last_finished_at),
       polls_completed: state.polls_completed,
       last_error: state.last_error
     }, state}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @check_interval_ms)
  end

  # Runs in the poll task. Always returns :ok or an error description, so the process
  # that owns the state hears about every poll, including a crashed one.
  defp run_poll do
    try do
      feeds = FeedConfig.feeds()
      Logger.info("Polling #{length(feeds)} RSS feeds")
      Enum.each(feeds, &poll_feed/1)
      :ok
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
    end
  end

  defp poll_feed(%{"url" => url, "company_name" => company_name, "tags" => tags} = _feed) do
    case FeedFetcher.fetch(url) do
      {:ok, items} ->
        Logger.info("Fetched #{length(items)} items from #{url}")

        new_items = Enum.reject(items, fn item -> DedupFilter.seen?(item["guid"]) end)
        Logger.info("#{length(new_items)} new items after dedup filter")

        if is_job_listing?(tags) do
          Enum.each(new_items, fn item -> DedupFilter.mark_seen(item["guid"]) end)
          Enum.each(new_items, fn item -> Publisher.publish_listing(item, company_name, tags) end)
        else
          # One batch per feed: every item is submitted, then the batch is polled together.
          results = Sieve.triage_many(new_items)
          mark_scored_seen(results)
          Enum.each(results, fn {item, result} -> handle_score(item, result, tags) end)
        end

      {:error, reason} ->
        Logger.warning("RSS poll failed for #{url}: #{inspect(reason)}")
    end
  end

  defp poll_feed(feed) do
    Logger.warning("Invalid feed configuration: #{inspect(feed)}")
  end

  # An item is "seen" once it has been scored, not once it has been fetched. A sieve that
  # failed (the model was unavailable, the reply was unreadable) leaves the item unseen, so
  # the next poll tries it again instead of dropping it until the bot restarts.
  @doc false
  def mark_scored_seen(results) do
    for {item, {:ok, _score}} <- results, do: DedupFilter.mark_seen(item["guid"])
    :ok
  end

  defp handle_score(item, {:ok, score}, tags) when score >= 5 do
    log_score(item, score, true, tags)
    Publisher.publish_finding(item, score, tags)
  end

  defp handle_score(item, {:ok, score}, tags) do
    log_score(item, score, false, tags)
    Logger.debug("RSS item filtered as noise: #{item["title"] || "Untitled"}")
  end

  defp handle_score(item, {:error, reason}, _tags) do
    Logger.warning("Sieve triage failed for #{item["title"] || "Untitled"}: #{inspect(reason)}")
  end

  # One line per scored item, admitted or not, so the source report can measure how
  # often each host clears the sieve cutoff. Grep: RSS_SCORE
  defp log_score(item, score, admitted, tags) do
    host =
      case URI.parse(item["url"] || "") do
        %URI{host: host} when is_binary(host) -> String.replace_prefix(host, "www.", "")
        _ -> "unknown"
      end

    Logger.info(
      "RSS_SCORE host=#{host} score=#{score} admitted=#{admitted} tags=#{Enum.join(tags, ",")}"
    )
  end

  defp is_job_listing?(tags) do
    Enum.any?(tags, fn tag -> tag == "job" or tag == "listing" end)
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp iso(nil), do: nil
  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
