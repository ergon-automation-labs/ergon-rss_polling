defmodule BotArmyRssPolling.Sieve do
  @moduledoc """
  Initial triage of RSS items using a local LLM via the NATS bus.
  """

  require Logger

  @job_budget_ms 180_000
  @poll_ms 2_000

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
      "temperature" => 0,
      # Async: the LLM bot answers with a job id at once, and the answer is read by
      # polling llm.job.status. A queued (triaged) request then cannot be mistaken
      # for an empty answer, and a slow one gets the full job budget.
      "async" => true
    }

    case BotArmyLibraryRuntime.NATS.Publisher.request("llm.request.chat", payload) do
      {:ok, %{"job_id" => job_id}} when is_binary(job_id) ->
        await_score(job_id, System.monotonic_time(:millisecond) + @job_budget_ms)

      {:ok, %{"ok" => false, "error" => error}} ->
        Logger.error("LLM Service refused the sieve request: #{inspect(error)}")
        {:error, :api_error}

      {:error, reason} ->
        Logger.error("NATS request to llm.request.chat failed: #{inspect(reason)}")
        {:error, :connection_error}

      other ->
        Logger.error("Unexpected response from LLM service: #{inspect(other)}")
        {:error, :malformed_response}
    end
  end

  # Poll the job until it completes, fails, or the budget runs out. Each poll is short,
  # so one slow job cannot hold a single request open for the whole budget.
  defp await_score(job_id, deadline) do
    case BotArmyLibraryRuntime.NATS.Publisher.request("llm.job.status", %{"job_id" => job_id}) do
      {:ok, %{"status" => "completed", "result" => result}} ->
        result |> content_of() |> parse_score()

      {:ok, %{"status" => "failed"} = job} ->
        Logger.error("Sieve job #{job_id} failed: #{inspect(job["error"])}")
        {:error, :api_error}

      {:ok, %{"status" => status}} when status in ["pending", "running", "queued"] ->
        if System.monotonic_time(:millisecond) >= deadline do
          Logger.warning("Sieve job #{job_id} still #{status} at its budget; leaving it")
          {:error, :timeout}
        else
          Process.sleep(@poll_ms)
          await_score(job_id, deadline)
        end

      other ->
        Logger.error("Unexpected job status reply for #{job_id}: #{inspect(other)}")
        {:error, :malformed_response}
    end
  end

  # The stored result is the chat reply: either {ok, data: {...}} or the fields directly.
  defp content_of(%{"data" => data}) when is_map(data), do: content_of(data)
  defp content_of(%{} = map), do: map["content"] || map["answer"] || map["text"]
  defp content_of(text) when is_binary(text), do: text
  defp content_of(_), do: nil

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
