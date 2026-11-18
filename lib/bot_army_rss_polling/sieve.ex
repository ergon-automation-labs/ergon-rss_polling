defmodule BotArmyRssPolling.Sieve do
  @moduledoc """
  Initial triage of RSS items using a local LLM via the NATS bus.
  """

  require Logger

  @doc """
  Triage an RSS item. Returns {:ok, score} where score is 0..10, or {:error, reason}.
  """
  def triage(item) do
    title = item["title"] || ""
    description = item["description"] || ""
    text = "Title: #{title}\nDescription: #{description}"

    prompt = """
    You are a high-speed signal filter for a sovereign intelligence system.
    Your goal is to rate the significance of the following item for a high-performance operator and a foodie.

    Categories of high significance:
    - Macroeconomic shifts (rates, inflation, geopolitical).
    - Major AI/Tech breakthroughs or architectural shifts.
    - High-alpha culinary inspiration (unique recipes, new techniques, or high-quality foodie ideas for home preparation).
    - Thoughtful and unique gift inspiration (high-quality curation, unique gear, or meaningful gift ideas).
    - Denver and Boulder local signals (hidden gems, landmarks to explore, unique events, or cultural activities in the Front Range area).
    - High-value gaming intelligence (build guides, hidden quest locations, world-lore, or strategic tips for Cyberpunk 2077).
    - Life elevation and growth signals (mental models, lifestyle design, philosophy, high-leverage habits, or aesthetic improvements).
    - Vitality and motivation signals (science-based health protocols, workout motivation, a-ha moments for physical performance, or high-energy mindset shifts).
    - High-impact productivity and AI workflows (automation tips, "unlocks" for personal efficiency, and AI-driven leverage).
    - Specific high-impact market volatility or corporate events.

    Ignore: General noise, fluff, routine updates, or low-impact news.

    Rate the significance from 0 (noise) to 10 (critical).
    Output ONLY the integer. No explanation.

    Text:
    #{text}
    """

    payload = %{
      "query" => prompt,
      "model" => "sieve",
      "temperature" => 0
    }

    # Use the library runtime's NATS request to avoid direct HTTP dependencies
    case BotArmyLibraryRuntime.NATS.Publisher.request("llm.request.chat", payload) do
      {:ok, %{"ok" => true, "data" => data}} when is_map(data) ->
        # Data from llm.request.chat is typically a map containing the answer
        # If it's a string directly, handle that. If it's in a 'content' key, handle that.
        content = if is_binary(data), do: data, else: data["content"] || data["answer"]
        parse_score(content)

      {:ok, %{"ok" => false, "error" => error}} ->
        Logger.error("LLM Service returned error: #{inspect(error)}")
        {:error, :api_error}

      {:error, reason} ->
        Logger.error("NATS request to llm.request.chat failed: #{inspect(reason)}")
        {:error, :connection_error}

      other ->
        Logger.error("Unexpected response from LLM service: #{inspect(other)}")
        {:error, :malformed_response}
    end
  end

  defp parse_score(nil), do: {:error, :empty_response}

  defp parse_score(content) when is_binary(content) do
    case String.trim(content) |> String.to_integer() do
      score when score in 0..10 -> {:ok, score}
      _ -> {:error, :invalid_score}
    end
  rescue
    _ -> {:error, :parse_error}
  end

  defp parse_score(_), do: {:error, :invalid_type}
end
