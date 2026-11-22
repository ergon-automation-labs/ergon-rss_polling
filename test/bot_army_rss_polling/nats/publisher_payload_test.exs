defmodule BotArmyRssPolling.NATS.PublisherPayloadTest do
  use ExUnit.Case, async: true
  @moduletag :nats

  alias BotArmyRssPolling.NATS.Publisher

  @item %{"title" => "A thing", "url" => "https://x.test/a"}

  test "a finding names its poster in observed_by as well as source" do
    p = Publisher.finding_payload(@item, 7, ["ai"], "rss_ai_stream")
    assert p["observed_by"] == "bot_army_rss_polling"
    assert p["source"] == "bot_army_rss_polling"
    assert p["metadata"]["score"] == 7
  end

  test "a date idea names its poster in observed_by as well as source" do
    p =
      Publisher.date_idea_payload(
        @item,
        %{"outing" => 0.9, "energy" => "cozy", "when" => "anytime"},
        ["date_night"],
        "rss_date_night_stream"
      )

    assert p["observed_by"] == "bot_army_rss_polling"
    assert p["metadata"]["outing"] == 0.9
    assert p["metadata"]["when"] == "anytime"
  end

  test "a finding points back at its article in source_url, not at the poster" do
    p = Publisher.finding_payload(@item, 7, ["ai"], "rss_ai_stream")
    assert p["source_url"] == "https://x.test/a"
    assert p["source"] == "bot_army_rss_polling"
    refute p["source_url"] == p["source"]
  end

  test "a non-http item url is sent as no pointer, never as a pointer" do
    assert Publisher.source_url(%{"url" => "javascript:alert(1)"}) == nil
    assert Publisher.source_url(%{"url" => "  "}) == nil
    assert Publisher.source_url(%{}) == nil
    assert Publisher.source_url(%{"url" => " https://x.test/b "}) == "https://x.test/b"
  end
end
