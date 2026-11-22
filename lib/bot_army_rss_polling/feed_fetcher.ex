defmodule BotArmyRssPolling.FeedFetcher do
  @moduledoc """
  Fetches and parses RSS/Atom feeds from URLs.

  Uses OTP's :httpc for HTTP requests and sweet_xml for XML parsing.
  Supports both RSS 2.0 and Atom feed formats.
  """

  import SweetXml
  require Logger

  @http_timeout_ms 15_000
  @request_headers [
    {~c"user-agent", ~c"Mozilla/5.0 (compatible; BotArmyRssPolling)"},
    {~c"accept", ~c"application/rss+xml, application/atom+xml, application/xml, text/xml, */*"}
  ]

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
           :httpc.request(
             :get,
             {String.to_charlist(url), @request_headers},
             [{:timeout, @http_timeout_ms}, {:autoredirect, true}],
             body_format: :binary
           ),
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

  # An XML declaration must be the first thing in the document. 5280.com sends "\n<?xml ...?>", and
  # some servers prepend a BOM; strictly parsed, either is "invalid_target_name" and the feed is lost.
  defp parse_feed(body) when is_binary(body) do
    doc =
      body
      |> String.trim_leading("\uFEFF")
      |> String.trim_leading()
      |> SweetXml.parse(quiet: true)

    parse_items(doc)
  catch
    :exit, reason ->
      Logger.error("Failed to parse XML: #{inspect(reason)}")
      {:error, {:invalid_xml, reason}}
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

    case items do
      [] -> reject_error_feed(doc)
      _ -> {:ok, normalize(items)}
    end
  end

  # A server that is refusing us can still answer 200 with a well-formed feed that has a title and
  # no items (reddit.com did, 2026-11-22: title "Not Found"). That must not read as "nothing new".
  @error_title ~r/^\s*(not found|404|403|429|error|forbidden|access denied|too many requests|rate limit|blocked|unauthorized|service unavailable)\b/i

  defp reject_error_feed(doc) do
    title =
      doc
      |> SweetXml.xpath(~x"/*/title/text() | /*/channel/title/text()"s)
      |> to_string()

    if Regex.match?(@error_title, title),
      do: {:error, {:error_feed, String.trim(title)}},
      else: {:ok, []}
  end

  defp normalize(items) do
    # Normalize to map format with string keys
    normalized =
      Enum.map(items, fn item ->
        %{
          "guid" => guid_for(item),
          "title" => to_string(item[:title] || ""),
          "url" => to_string(item[:link] || ""),
          "description" => to_string(item[:description] || ""),
          "published_at" => to_string(item[:pub_date] || "")
        }
      end)
      |> Enum.filter(&(String.length(Map.get(&1, "guid", "")) > 0))

    normalized
  end

  # Some feeds (Hacker News) carry no <guid>; the item's link is the stable key then.
  defp guid_for(item) do
    case to_string(item[:guid] || "") do
      "" -> to_string(item[:link] || "")
      guid -> guid
    end
  end
end
