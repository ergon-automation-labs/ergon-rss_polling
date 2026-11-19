defmodule BotArmyRssPolling.DateIdeas do
  @moduledoc """
  Which RSS items are things two people could go do — the date-night stream's filter.

  A feed tag can only say a source *sometimes* has outings: Denverite is tagged `date_night`
  and also publishes bedbug reports and rail news. So items from `date_night`-tagged feeds are
  each judged by Clef (`llm.decide`, the fast decision model). This runs whatever the sieve
  thought of the item: the sieve scores how interesting an item is as news, and a holiday
  market is a fine outing that is dull news.

  ## Two passes, small decisions

  Clef costs about one model pass per question (measured 2026-11-19: ~3.3 s/question for the
  27B on mini, ~4.7 s on air's clef-flash), not one pass per request. So:

    1. every item gets one question — is it an outing? — 12 items per decision;
    2. only the items over the bar get the two descriptive ones — energy, and when — 6 per decision.

  12 questions is ~40 s, under the door's 60 s Clef deadline. Each decision asks `large` (mini)
  and, only if that one cannot be had, asks `local` — an explicit retry by this caller, never a
  swap inside the door.
  """

  require Logger

  @tag "date_night"
  @outing_per_decision 12
  @detail_per_decision 6
  @bar 0.7
  @desc_chars 300
  @timeout_ms 120_000
  @wheres ["large", "local"]

  @doc "Whether a feed's items should be judged as date ideas."
  @spec eligible?([String.t()]) :: boolean()
  def eligible?(tags) when is_list(tags), do: @tag in tags

  @doc """
  Judge items. Returns `{:ok, [{item, %{"outing", "energy", "when"}}]}` for the items over the
  bar, or `{:error, reason}` when a decision could not be had — never an empty list that would
  read as "no ideas this week". `decide` is the `llm.decide` request (injectable).
  """
  @spec classify([map()], (map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [{map(), map()}]} | {:error, term()}
  def classify(items, decide \\ &request/1)
  def classify([], _decide), do: {:ok, []}

  def classify(items, decide) do
    with {:ok, outings} <-
           in_chunks(items, @outing_per_decision, &outing_request/1, decide, &read_outings/2),
         {:ok, details} <-
           in_chunks(
             Enum.map(outings, &elem(&1, 0)),
             @detail_per_decision,
             &detail_request/1,
             decide,
             &read_details/2
           ) do
      {:ok,
       Enum.map(outings, fn {item, p} ->
         {item,
          Map.merge(
            %{"outing" => p},
            Map.get(details, item["guid"], %{"energy" => nil, "when" => nil})
          )}
       end)}
    end
  end

  defp in_chunks([], _size, _build, _decide, read), do: {:ok, read.([], %{})}

  defp in_chunks(items, size, build, decide, read) do
    items
    |> Enum.chunk_every(size)
    |> Enum.reduce_while({:ok, read.([], %{})}, fn chunk, {:ok, acc} ->
      case ask(build.(chunk), decide) do
        {:ok, answers} -> {:cont, {:ok, merge(acc, read.(chunk, answers))}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp merge(a, b) when is_list(a), do: a ++ b
  defp merge(a, b) when is_map(a), do: Map.merge(a, b)

  # Ask large, then local. The first answer wins; the last refusal is the error.
  defp ask(request, decide) do
    Enum.reduce_while(@wheres, {:error, :no_where}, fn where, _ ->
      case decide.(Map.put(request, "where", where)) do
        {:ok, %{"payload" => %{"ok" => true, "answers" => answers}}} ->
          {:halt, {:ok, answers}}

        {:ok, %{"payload" => %{"ok" => false, "error" => %{"code" => code}}}} ->
          Logger.warning("[DateIdeas] llm.decide where=#{where} refused: #{code}")
          {:cont, {:error, {:decide_refused, code}}}

        {:ok, other} ->
          {:cont, {:error, {:unexpected_reply, Map.keys(other)}}}

        {:error, reason} = err ->
          Logger.warning("[DateIdeas] llm.decide where=#{where} failed: #{inspect(reason)}")
          {:cont, err}
      end
    end)
  end

  @doc "The outing question, one per item."
  @spec outing_request([map()]) :: map()
  def outing_request(items) do
    %{
      "state" => state(items),
      "questions" =>
        numbered(items, fn n ->
          %{
            "i#{n}_outing" => %{
              "type" => "noul",
              "instructions" =>
                "Is item #{n} something two people could go and do together in or near Denver/Boulder — " <>
                  "an event, show, market, exhibit, restaurant, class, trail or trip? News about it is not."
            }
          }
        end)
    }
  end

  @doc "The energy and timing questions, for items already judged to be outings."
  @spec detail_request([map()]) :: map()
  def detail_request(items) do
    %{
      "state" => state(items),
      "questions" =>
        numbered(items, fn n ->
          %{
            "i#{n}_energy" => %{
              "type" => "choice",
              "instructions" => "How much energy would item #{n} ask of two people?",
              "criteria" => %{
                "cozy" => "low effort: a meal, a show, a market, a museum",
                "moderate" => "some effort: a long walk, a festival, a class",
                "adventure" => "a big outing: a hike, a day trip, a hot spring, a ski day"
              }
            },
            "i#{n}_when" => %{
              "type" => "choice",
              "instructions" => "When could item #{n} be done?",
              "criteria" => %{
                "dated_event" => "on specific dates only",
                "this_season" => "for a limited season",
                "anytime" => "any time; a place, not an event"
              }
            }
          }
        end)
    }
  end

  defp numbered(items, fun) do
    items
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {_item, n}, acc -> Map.merge(acc, fun.(n)) end)
  end

  defp state(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {item, n} ->
      desc = item |> Map.get("description", "") |> plain() |> String.slice(0, @desc_chars)

      String.trim(
        "#{n}. #{Map.get(item, "title", "")}" <> if(desc == "", do: "", else: " — " <> desc)
      )
    end)
  end

  @doc false
  def read_outings(items, answers) do
    items
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {item, n} ->
      case answers["i#{n}_outing"] do
        %{"noul" => p} when is_number(p) and p >= @bar -> [{item, p}]
        _ -> []
      end
    end)
  end

  @doc false
  def read_details(items, answers) do
    items
    |> Enum.with_index(1)
    |> Map.new(fn {item, n} ->
      {item["guid"],
       %{
         "energy" => get_in(answers, ["i#{n}_energy", "choice"]),
         "when" => get_in(answers, ["i#{n}_when", "choice"])
       }}
    end)
  end

  defp plain(text) do
    text
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/&[a-z#0-9]+;/i, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp request(payload),
    do:
      BotArmyLibraryRuntime.NATS.Publisher.request("llm.decide", payload, timeout_ms: @timeout_ms)
end
