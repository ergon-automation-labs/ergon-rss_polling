defmodule BotArmyRssPolling.Triggers.DateNight do
  @moduledoc """
  Sensing-to-action for date night: the ideas Clef judged to be outings become one note,
  `projects/Date Night/this_week.md` — one idea with a first step, two backups, nothing to tick.

  The note carries its own state (a base64 block in an HTML comment) so the bot needs no table.
  A note without that block is Abby's own writing and is never overwritten.
  """

  require Logger

  @path "projects/Date Night/this_week.md"
  @marker "<!-- sensing-state v1"
  @cap 40
  @dated_days 4
  @other_days 21
  @good 0.7
  @dated_boost 0.1
  @empty %{"ideas" => [], "pick" => nil}

  def path, do: @path

  @doc "Add new ideas to the state, keep first-seen dates, drop stale ones, cap the list."
  def merge(state, new, today) do
    known = Map.new(state["ideas"], &{&1["url"], &1})

    merged =
      Enum.reduce(new, known, fn idea, acc ->
        url = idea["url"]

        case Map.fetch(acc, url) do
          {:ok, old} -> Map.put(acc, url, Map.put(idea, "seen", old["seen"]))
          :error -> Map.put(acc, url, idea)
        end
      end)

    ideas =
      merged
      |> Map.values()
      |> Enum.filter(&fresh?(&1, today))
      |> Enum.sort_by(&{-&1["outing"], &1["seen"] || ""})
      |> Enum.take(@cap)

    added? = Enum.any?(new, &(not Map.has_key?(known, &1["url"])))
    state = %{state | "ideas" => ideas}
    if added?, do: Map.put(state, "last_new", Date.to_iso8601(today)), else: state
  end

  @doc "One pick (sticky while it is still good and fresh) and up to two backups, or :none."
  def choose(state, today) do
    live = Enum.filter(state["ideas"], &fresh?(&1, today))
    ranked = Enum.sort_by(live, &{-score(&1), &1["title"] || ""})

    pick =
      Enum.find(live, &(&1["url"] == state["pick"] and &1["outing"] >= @good)) ||
        List.first(ranked)

    case pick do
      nil ->
        :none

      pick ->
        %{pick: pick, backups: ranked |> Enum.reject(&(&1["url"] == pick["url"])) |> Enum.take(2)}
    end
  end

  def first_step(%{"when" => "dated_event"}),
    do: "check the date, and whether you need tickets. It only happens on certain days."

  def first_step(%{"when" => "this_season"}),
    do: "see how long the season runs, then pick a day while it is on."

  def first_step(%{"energy" => "adventure"}),
    do: "look at the weather for a free day, and decide then."

  def first_step(_), do: "send Louiza this one and see if it sounds good."

  @doc "The note. State rides along, encoded, so it survives a round trip."
  def render(state, today) do
    body =
      case choose(state, today) do
        :none -> "Nothing new this week. That is fine; ideas come in as the feeds do.\n"
        %{pick: pick, backups: backups} -> pick_section(pick) <> backups_section(backups)
      end

    """
    # Date night — this week

    #{body}
    Dates aren't checked: look before you plan around one. Nothing here is a to-do; it is a note.

    Last new idea: #{last_new(state)}

    #{@marker}
    #{encode(state)}
    -->
    """
  end

  def parse(nil), do: @empty

  def parse(text) when is_binary(text) do
    with [_, rest] <- String.split(text, @marker <> "\n", parts: 2),
         [encoded, _] <- String.split(rest, "\n-->", parts: 2),
         {:ok, json} <- Base.decode64(String.trim(encoded)),
         {:ok, %{"ideas" => ideas} = state} when is_list(ideas) <- Jason.decode(json) do
      Map.put_new(state, "pick", nil)
    else
      _ -> :foreign
    end
  end

  @doc """
  Fold new ideas into the note. Reads first; a failed read is an error and writes nothing, and a
  note that is not ours is reported and left alone. Writes only when the text changes.
  """
  def apply(ideas, opts) do
    para = Keyword.get(opts, :para, __MODULE__.Para)
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)

    with {:ok, existing, state} <- load(para) do
      state = merge(state, ideas, today)
      state = Map.put(state, "pick", pick_url(choose(state, today)))

      if existing == nil and state["ideas"] == [] do
        :unchanged
      else
        write_if_changed(para, existing, render(state, today))
      end
    end
  end

  defp load(para) do
    case para.read(@path) do
      {:ok, text} ->
        case parse(text) do
          :foreign ->
            Logger.warning("DATE_NIGHT note at #{@path} is not ours; leaving it alone")
            {:error, :foreign_note}

          state ->
            {:ok, text, state}
        end

      {:error, :not_found} ->
        {:ok, nil, @empty}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_if_changed(_para, existing, text) when existing == text, do: :unchanged

  defp write_if_changed(para, _existing, text) do
    case para.write(@path, text) do
      :ok -> :written
      {:error, reason} -> {:error, reason}
    end
  end

  defp pick_url(:none), do: nil
  defp pick_url(%{pick: pick}), do: pick["url"]

  defp fresh?(idea, today) do
    age = Date.diff(today, seen(idea, today))
    age <= if(idea["when"] == "dated_event", do: @dated_days, else: @other_days)
  end

  defp seen(idea, today) do
    case Date.from_iso8601(idea["seen"] || "") do
      {:ok, d} -> d
      _ -> today
    end
  end

  defp score(%{"when" => "dated_event"} = idea), do: idea["outing"] + @dated_boost
  defp score(idea), do: idea["outing"]

  defp pick_section(pick) do
    """
    ## One idea

    **#{pick["title"]}** (#{pick["source"]})
    #{pick["url"]}

    First step: #{first_step(pick)}

    """
  end

  defp backups_section([]), do: ""

  defp backups_section(backups) do
    heading = if length(backups) == 1, do: "## A backup", else: "## Two backups"
    lines = Enum.map_join(backups, "\n", &"- #{&1["title"]} — #{&1["url"]}")
    "#{heading}\n\n#{lines}\n"
  end

  defp last_new(%{"last_new" => d}) when is_binary(d), do: d

  defp last_new(%{"ideas" => ideas}) do
    case ideas |> Enum.map(& &1["seen"]) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end) do
      nil -> "none seen yet"
      d -> d
    end
  end

  defp encode(state), do: state |> Jason.encode!() |> Base.encode64()
end
