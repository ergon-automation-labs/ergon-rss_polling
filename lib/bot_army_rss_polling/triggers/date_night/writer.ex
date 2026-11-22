defmodule BotArmyRssPolling.Triggers.DateNight.Writer do
  @moduledoc """
  The one process that edits the date-night note. Feeds poll separately; two of them folding ideas
  in at once would each read the old note and one would erase the other. Casting here keeps the
  poll loop from waiting on PARA, and serializes the read-modify-write.
  """
  use GenServer

  require Logger

  alias BotArmyRssPolling.Triggers.DateNight

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Hand over judged items `[{item, decision}]`. Never blocks, and is a no-op if the writer is not running."
  def submit(judged), do: GenServer.cast(__MODULE__, {:submit, judged})

  @doc "The idea map the note stores, or nil for an item with no link or title to show."
  def idea({item, %{"outing" => outing} = decision}, today) when is_number(outing) do
    with url when is_binary(url) and url != "" <- item["url"],
         title when is_binary(title) and title != "" <- item["title"] do
      %{
        "title" => title,
        "url" => url,
        "energy" => decision["energy"],
        "when" => decision["when"],
        "outing" => outing,
        "source" => host(url),
        "seen" => Date.to_iso8601(today)
      }
    else
      _ -> nil
    end
  end

  def idea(_, _), do: nil

  defp host(url), do: URI.parse(url).host || "unknown"

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_cast({:submit, judged}, state) do
    today = Date.utc_today()
    ideas = judged |> Enum.map(&idea(&1, today)) |> Enum.reject(&is_nil/1)

    result =
      try do
        DateNight.apply(ideas, Keyword.new(state))
      rescue
        e -> {:error, Exception.message(e)}
      end

    Logger.info("DATE_NIGHT note=#{inspect(result)} ideas_in=#{length(ideas)}")
    {:noreply, state}
  end
end
