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
  def publish_listing(item, company_name, tags) when is_map(item) and is_binary(company_name) and is_list(tags) do
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

    case BotArmyRuntime.NATS.Publisher.publish("job.listings.ingest", event) do
      :ok ->
        Logger.debug("Published RSS listing: #{payload["title"]} (#{company_name})")
        :ok

      {:error, reason} ->
        Logger.error("Failed to publish listing: #{inspect(reason)}")
        {:error, reason}
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
