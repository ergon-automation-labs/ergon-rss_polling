defmodule BotArmyRssPolling.FeedFetcher do
  @moduledoc """
  Fetches and parses RSS/Atom feeds from URLs.

  Uses OTP's :httpc for HTTP requests and sweet_xml for XML parsing.
  Supports both RSS 2.0 and Atom feed formats.
  """

  import SweetXml
  require Logger

  @http_timeout_ms 15_000

  @doc """
  Fetch and parse a single RSS/Atom feed.

  Returns {:ok, items} where items is a list of maps with keys:
  - "guid" - unique identifier (from <guid> or <id>)
  - "title" - feed item title
  - "url" - item link (from <link> or <link href>)
  - "description" - item description/summary
  - "published_at" - publication date

  Returns {:error, reason} on HTTP or parsing errors.
  """
  def fetch(url) do
    with {:ok, {{_http, 200, _status}, _headers, body}} <-
           :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, @http_timeout_ms}], []),
         {:ok, items} <- parse_feed(body) do
      {:ok, items}
    else
      {:ok, {{_http, status, _status}, _headers, _body}} ->
        Logger.warning("HTTP error fetching #{url}: status #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("Failed to fetch #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_feed(body) when is_binary(body) do
    case SweetXml.parse(body) do
      {:ok, doc} ->
        parse_items(doc)

      {:error, reason} ->
        Logger.error("Failed to parse XML: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_feed(_body), do: {:error, :invalid_body}

  # Try RSS 2.0 <item> format first
  defp parse_items(doc) do
    items =
      doc
      |> SweetXml.xpath(~x"//item"l,
        guid: ~x"guid/text()"s,
        title: ~x"title/text()"s,
        link: ~x"link/text()"s,
        description: ~x"description/text()"s,
        pub_date: ~x"pubDate/text()"s
      )

    # If no items, try Atom <entry> format
    items =
      if Enum.empty?(items) do
        doc
        |> SweetXml.xpath(~x"//entry"l,
          guid: ~x"id/text()"s,
          title: ~x"title/text()"s,
          link: ~x"link[@rel='alternate']/@href"s,
          description: ~x"summary/text()"s,
          pub_date: ~x"published/text()"s
        )
      else
        items
      end

    # Normalize to map format with string keys
    normalized =
      Enum.map(items, fn item ->
        %{
          "guid" => to_string(item[:guid] || ""),
          "title" => to_string(item[:title] || ""),
          "url" => to_string(item[:link] || ""),
          "description" => to_string(item[:description] || ""),
          "published_at" => to_string(item[:pub_date] || "")
        }
      end)
      |> Enum.filter(&(String.length(Map.get(&1, "guid", "")) > 0))

    {:ok, normalized}
  end
end
