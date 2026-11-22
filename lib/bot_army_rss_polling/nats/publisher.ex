defmodule BotArmyRssPolling.NATS.Publisher do
  @moduledoc """
  Publishes RSS feed items to the job.listings.ingest subject.

  Items are published as individual ingestion events for deduplication
  and scoring by the job applications bot.
  """

  require Logger

  @doc """
  Publish a single RSS feed item to job.listings.ingest.
  """
  def publish_listing(item, company_name, tags)
      when is_map(item) and is_binary(company_name) and is_list(tags) do
    payload = %{
      "source" => "rss",
      "company_name" => company_name,
      "title" => item["title"] || "",
      "url" => item["url"] || "",
      "description" => item["description"] || "",
      "published_at" => item["published_at"] || "",
      "tags" => tags
    }

    event = build_event(payload)

    case BotArmyLibraryRuntime.NATS.Publisher.publish("job.listings.ingest", event) do
      :ok ->
        Logger.debug("Published RSS listing: #{payload["title"]} (#{company_name})")
        :ok

      {:error, reason} ->
        Logger.error("Failed to publish listing: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Publish a high-signal RSS item as a finding to the Intelligence Protocol.
  """
  def publish_finding(item, score, tags \\ [])
      when is_map(item) and is_integer(score) and is_list(tags) do
    # Determine the theory ID based on tags. If tags are empty, use the general stream.
    theory_id =
      case tags do
        [] -> "rss_signal_stream"
        [primary | _] -> "rss_#{primary}_stream"
      end

    # We post this as evidence for the specific topic's theory.
    payload = finding_payload(item, score, tags, theory_id)

    category = finding_category(tags)

    with :ok <- ensure_theory(theory_id, category),
         {:ok, _} <- request("bridge.nexus.intelligence.blackboard.evidence.post", payload) do
      Logger.debug(
        "Posted RSS finding (score #{score}) to #{theory_id}: #{item["title"] || "Untitled"}"
      )

      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to post RSS finding to #{theory_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Post an item Clef judged to be an outing to `rss_date_night_stream`, with what it decided
  (`outing` probability, `energy`, `when`). This is separate from `publish_finding/3`, which
  files by the feed's first tag and so never reached the date-night stream.
  """
  def publish_date_idea(item, %{"outing" => outing} = decision, tags \\ [])
      when is_map(item) and is_number(outing) do
    theory_id = "rss_date_night_stream"

    payload = date_idea_payload(item, decision, tags, theory_id)

    with :ok <- ensure_theory(theory_id, "date_night"),
         {:ok, _} <- request("bridge.nexus.intelligence.blackboard.evidence.post", payload) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to post date idea: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # The article a finding is about, so the blackboard can point back at it. Anything that is not
  # an http(s) URL is sent as nil (absent) rather than refused: a bad feed item must not drop the finding.
  @doc false
  def source_url(%{"url" => url}) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" -> url
      _ -> nil
    end
  end

  def source_url(_item), do: nil

  @doc false
  def finding_payload(item, score, tags, theory_id) do
    %{
      "theory_id" => theory_id,
      "summary" => "High-signal RSS item: #{item["title"] || "Untitled"}",
      "stance" => "support",
      "source" => "bot_army_rss_polling",
      "source_url" => source_url(item),
      "observed_by" => "bot_army_rss_polling",
      "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "metadata" => %{
        "score" => score,
        "url" => item["url"] || "",
        "title" => item["title"] || "",
        "tags" => tags
      }
    }
  end

  @doc false
  def date_idea_payload(item, %{"outing" => outing} = decision, tags, theory_id) do
    %{
      "theory_id" => theory_id,
      "summary" => "Date idea: #{item["title"] || "Untitled"}",
      "stance" => "support",
      "source" => "bot_army_rss_polling",
      "source_url" => source_url(item),
      "observed_by" => "bot_army_rss_polling",
      "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "metadata" => %{
        "url" => item["url"] || "",
        "title" => item["title"] || "",
        "tags" => tags,
        "outing" => outing,
        "energy" => decision["energy"],
        "when" => decision["when"]
      }
    }
  end

  @finding_categories ~w(culinary growth gaming local vitality gifts date_night macro ai uncategorized)

  defp finding_category([primary | _]) when primary in @finding_categories, do: primary
  defp finding_category(_tags), do: "uncategorized"

  # Evidence can only attach to a theory that exists, so post the theory on first sight.
  # Later findings for the same theory reuse it.
  defp ensure_theory(theory_id, category) do
    case request("bridge.nexus.intelligence.blackboard.theory.get", %{"id" => theory_id}) do
      {:ok, _} ->
        :ok

      {:error, %{"code" => "not_found"}} ->
        theory = %{
          "id" => theory_id,
          "statement" => "RSS findings for #{theory_id}",
          "topic" => "RSS findings",
          "category" => category,
          "proposed_by" => "bot_army_rss_polling",
          "metadata" => %{"source" => "bot_army_rss_polling"}
        }

        case request("bridge.nexus.intelligence.blackboard.theory.post", theory) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # One request/reply to a bridge subject. The bridge answers {ok: true, data} or {ok: false, code}.
  defp request(subject, payload) do
    case BotArmyLibraryRuntime.NATS.Publisher.request(subject, payload) do
      {:ok, %{"ok" => true} = reply} -> {:ok, reply}
      {:ok, %{"ok" => false} = reply} -> {:error, reply}
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_event(payload) do
    %{
      "event" => "job.listings.ingest",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_rss_polling",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "rss.poller",
      "schema_version" => "1.0",
      "payload" => payload
    }
  end
end
