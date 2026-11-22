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
end
