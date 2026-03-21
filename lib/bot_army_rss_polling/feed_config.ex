defmodule BotArmyRssPolling.FeedConfig do
  @moduledoc """
  Loads RSS feed configuration from environment.

  Reads the RSS_FEEDS_JSON environment variable, which is set by Salt
  from the rss_polling pillar. Format:
  ```json
  [
    {
      "url": "https://jobs.lever.co/company/rss",
      "company_name": "Company Name",
      "tags": []
    }
  ]
  ```
  """

  require Logger

  @doc """
  Get all configured RSS feeds.

  Returns a list of feed maps with keys: url, company_name, tags.
  """
  def feeds do
    case System.get_env("RSS_FEEDS_JSON") do
      nil ->
        Logger.warning("RSS_FEEDS_JSON environment variable not set, using empty feed list")
        []

      json_string ->
        case Jason.decode(json_string) do
          {:ok, feeds} ->
            Logger.info("Loaded #{length(feeds)} RSS feeds from configuration")
            feeds

          {:error, reason} ->
            Logger.error("Failed to parse RSS_FEEDS_JSON: #{inspect(reason)}")
            []
        end
    end
  end
end
