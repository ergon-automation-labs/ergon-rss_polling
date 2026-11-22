defmodule BotArmyRssPolling.FeedFetcherTest do
  use ExUnit.Case, async: true
  @moduletag :ingestion

  alias BotArmyRssPolling.FeedFetcher

  @rss """
  <?xml version="1.0"?>
  <rss version="2.0"><channel><title>t</title>
  <item><guid>g1</guid><title>First</title><link>https://example.com/1</link>
  <description>d</description><pubDate>Wed, 18 Nov 2026 10:00:00 GMT</pubDate></item>
  </channel></rss>
  """

  defp serve(body) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    pid =
      spawn_link(fn ->
        {:ok, sock} = :gen_tcp.accept(listen)
        {:ok, req} = :gen_tcp.recv(sock, 0, 5_000)
        send(:persistent_term.get({__MODULE__, :owner}), {:request, req})

        :gen_tcp.send(
          sock,
          "HTTP/1.1 200 OK\r\ncontent-type: application/rss+xml\r\ncontent-length: " <>
            "#{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
        )

        :gen_tcp.close(sock)
      end)

    {port, pid}
  end

  test "a 200 RSS body is parsed, not rejected as :invalid_body" do
    :persistent_term.put({__MODULE__, :owner}, self())
    {port, _pid} = serve(@rss)

    assert {:ok, [item]} = FeedFetcher.fetch("http://127.0.0.1:#{port}/feed/")
    assert item["title"] == "First"
    assert item["guid"] == "g1"
  end

  test "the request names the client with a User-Agent" do
    :persistent_term.put({__MODULE__, :owner}, self())
    {port, _pid} = serve(@rss)

    assert {:ok, _} = FeedFetcher.fetch("http://127.0.0.1:#{port}/feed/")
    assert_receive {:request, req}
    assert String.downcase(req) =~ "user-agent: mozilla/5.0 (compatible; botarmyrsspolling)"
  end

  test "an Atom feed is parsed" do
    :persistent_term.put({__MODULE__, :owner}, self())

    atom = """
    <?xml version="1.0"?>
    <feed xmlns="http://www.w3.org/2005/Atom"><title>t</title>
    <entry><id>a1</id><title>Entry</title><link rel="alternate" href="https://example.com/a"/>
    <summary>s</summary><published>2026-11-18T10:00:00Z</published></entry></feed>
    """

    {port, _pid} = serve(atom)
    assert {:ok, [item]} = FeedFetcher.fetch("http://127.0.0.1:#{port}/atom")
    assert item["guid"] == "a1"
    assert item["url"] == "https://example.com/a"
  end

  test "a body that is not XML is an error, not a crash" do
    :persistent_term.put({__MODULE__, :owner}, self())
    {port, _pid} = serve("<html><body>blocked")

    assert {:error, _} = FeedFetcher.fetch("http://127.0.0.1:#{port}/feed/")
  end

  test "an item with no <guid> is keyed by its link, so it is not dropped" do
    :persistent_term.put({__MODULE__, :owner}, self())

    hn = """
    <rss version="2.0"><channel><title>HN</title>
    <item><title>No guid</title><link>https://example.com/x</link>
    <description>d</description></item></channel></rss>
    """

    {port, _pid} = serve(hn)
    assert {:ok, [item]} = FeedFetcher.fetch("http://127.0.0.1:#{port}/rss")
    assert item["guid"] == "https://example.com/x"
  end

  # Captured from reddit.com on 2026-11-22: HTTP 200, a valid Atom document, zero entries.
  @reddit_not_found """
  <?xml version="1.0" encoding="UTF-8"?>
  <feed xmlns="http://www.w3.org/2005/Atom">
  <updated>2026-11-22T13:56:14Z</updated>
  <id>https://rss.reddit.com/</id>
  <link rel="self" href="https://rss.reddit.com/" type="application/atom+xml" />
  <title>Not Found</title>
  </feed>
  """

  test "a 200 feed titled Not Found with no items is an error, not a quiet empty feed" do
    :persistent_term.put({__MODULE__, :owner}, self())
    {port, _pid} = serve(@reddit_not_found)

    assert {:error, {:error_feed, "Not Found"}} =
             FeedFetcher.fetch("http://127.0.0.1:#{port}/feed/")
  end

  test "other error titles are caught too, in RSS as well as Atom" do
    for title <- ["Too Many Requests", "403 Forbidden", "Error", "Access Denied"] do
      :persistent_term.put({__MODULE__, :owner}, self())

      rss =
        "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>#{title}</title></channel></rss>"

      {port, _pid} = serve(rss)
      assert {:error, {:error_feed, ^title}} = FeedFetcher.fetch("http://127.0.0.1:#{port}/feed/")
    end
  end

  test "a real feed with no new items yet, or one that merely mentions an error, is still fine" do
    :persistent_term.put({__MODULE__, :owner}, self())

    {port, _pid} =
      serve(
        "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Denver Notes</title></channel></rss>"
      )

    assert {:ok, []} = FeedFetcher.fetch("http://127.0.0.1:#{port}/feed/")

    :persistent_term.put({__MODULE__, :owner}, self())

    {port, _pid} =
      serve(
        "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Lost &amp; Not Found Antiques</title></channel></rss>"
      )

    assert {:ok, []} = FeedFetcher.fetch("http://127.0.0.1:#{port}/feed/")

    :persistent_term.put({__MODULE__, :owner}, self())

    {port, _pid} =
      serve(
        "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Not Found</title>" <>
          "<item><guid>g</guid><title>Real post</title><link>https://example.com/p</link></item></channel></rss>"
      )

    assert {:ok, [_]} = FeedFetcher.fetch("http://127.0.0.1:#{port}/feed/")
  end
end
