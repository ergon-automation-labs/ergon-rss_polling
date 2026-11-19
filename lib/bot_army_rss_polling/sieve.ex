defmodule BotArmyRssPolling.Sieve do
  @moduledoc """
  Initial triage of RSS items using a local LLM via the NATS bus.

  Items are scored as async LLM jobs, in batches: every item in a batch is submitted
  first, and then the whole set is polled together. A batch takes about as long as its
  slowest job, not the sum of all of them, and a triaged (queued) request is waited
  for like any other job instead of being read as an empty answer.
  """

  require Logger

  @sieve_model "baytout3/qwen3.5-uncensored:4b"
  @job_budget_ms 180_000
  @poll_ms 2_000

  @doc """
  Score a batch of RSS items. Returns `[{item, result}]`, where result is
  `{:ok, score}` (0..10) or `{:error, reason}`. Blocks until every job is done or the
  budget runs out; the caller decides what to do with each result.
  """
  def triage_many([]), do: []

  def triage_many(items) do
    submitted =
      Enum.map(items, fn item ->
        case submit(item) do
          {:ok, job_id} -> {:pending, item, job_id}
          {:error, reason} -> {:done, item, {:error, reason}}
        end
      end)

    deadline = System.monotonic_time(:millisecond) + @job_budget_ms
    done = for {:done, item, result} <- submitted, do: {item, result}
    pending = for {:pending, item, job_id} <- submitted, do: {item, job_id}

    await_all(pending, deadline, done)
  end

  # Submit one item as an async job. Returns {:ok, job_id} or {:error, reason}.
  defp submit(item) do
    payload = request_payload(item)

    case BotArmyLibraryRuntime.NATS.Publisher.request("llm.request.chat", payload) do
      {:ok, %{"job_id" => job_id}} when is_binary(job_id) ->
        {:ok, job_id}

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

  @doc false
  def request_payload(item) do
    text = "Title: #{item["title"] || ""}\nDescription: #{item["description"] || ""}"

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

    %{
      "query" => prompt,
      "model" => @sieve_model,
      "model_type" => "uncensored",
      # A reasoning model on its default settings spends the answer on hidden thinking and
      # replies with an empty string, which is not a score.
      "think" => false,
      "temperature" => 0,
      # Async: the LLM bot answers with a job id at once; the score is read by polling
      # llm.job.status. A queued (triaged) request cannot be mistaken for an empty answer.
      "async" => true
    }
  end

  # One round over the still-pending jobs, then a short sleep, until none are pending or the
  # budget runs out. Each round asks each pending job once, so a slow job never holds the rest.
  defp await_all([], _deadline, done), do: done

  defp await_all(pending, deadline, done) do
    {still, finished} =
      Enum.reduce(pending, {[], []}, fn {item, job_id}, {still, finished} ->
        case job_status(job_id) do
          :pending -> {[{item, job_id} | still], finished}
          {:done, result} -> {still, [{item, result} | finished]}
        end
      end)

    done = done ++ Enum.reverse(finished)

    cond do
      still == [] ->
        done

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("#{length(still)} sieve job(s) still running at budget; leaving them")
        done ++ Enum.map(still, fn {item, _} -> {item, {:error, :timeout}} end)

      true ->
        Process.sleep(@poll_ms)
        await_all(Enum.reverse(still), deadline, done)
    end
  end

  # :pending while the job runs; {:done, result} once it has an answer or has failed.
  defp job_status(job_id) do
    case BotArmyLibraryRuntime.NATS.Publisher.request("llm.job.status", %{"job_id" => job_id}) do
      {:ok, %{"status" => "completed", "result" => result}} ->
        {:done, result |> content_of() |> parse_score()}

      {:ok, %{"status" => "failed"} = job} ->
        Logger.error("Sieve job #{job_id} failed: #{inspect(job["error"])}")
        {:done, {:error, :api_error}}

      {:ok, %{"status" => status}} when status in ["pending", "running", "queued"] ->
        :pending

      {:ok, other} ->
        Logger.error("Unexpected job status reply for #{job_id}: #{inspect(other)}")
        {:done, {:error, :malformed_response}}

      {:error, reason} ->
        # Transient transport error: ask again on the next round.
        Logger.warning("Sieve status request for #{job_id} failed: #{inspect(reason)}")
        :pending
    end
  end

  # The stored result is the chat reply: either {ok, data: {...}} or the fields directly.
  defp content_of(%{"data" => data}) when is_map(data), do: content_of(data)
  defp content_of(%{} = map), do: map["content"] || map["answer"] || map["text"]
  defp content_of(text) when is_binary(text), do: text
  defp content_of(_), do: nil

  @doc false
  def score_reply(content), do: parse_score(content)

  defp parse_score(nil), do: {:error, :empty_response}

  defp parse_score(content) when is_binary(content) do
    cleaned =
      content
      |> String.replace(~r/<think>.*?<\/think>/s, "")
      |> String.replace(~r/<think>.*\z/s, "")

    case Regex.run(~r/(?<![\d.])(10|[0-9])(?![\d])/, cleaned) do
      [_, digits] -> {:ok, String.to_integer(digits)}
      _ -> {:error, :parse_error}
    end
  end

  defp parse_score(_), do: {:error, :invalid_type}
end
