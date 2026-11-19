defmodule BotArmyRssPolling.SieveScoreTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyRssPolling.Sieve

  for {reply, score} <- [
        {"7", 7},
        {" 7\n", 7},
        {"10", 10},
        {"0", 0},
        {"Score: 7", 7},
        {"7/10", 7},
        {"**8**", 8},
        {"<think>maybe 3 or 4, hard to say</think>\n9", 9},
        {"The significance is 6 because it is a rate move.", 6}
      ] do
    test "score_reply #{inspect(reply)} -> #{score}" do
      assert {:ok, unquote(score)} = Sieve.score_reply(unquote(reply))
    end
  end

  test "a reply with no integer is a parse_error" do
    assert {:error, :parse_error} = Sieve.score_reply("noise")
  end

  test "an unterminated think block with no answer is a parse_error" do
    assert {:error, :parse_error} = Sieve.score_reply("<think>it could be 5")
  end

  test "a version-like or decimal number is not read as a score" do
    assert {:error, :parse_error} = Sieve.score_reply("2026")
  end

  describe "request_payload/1" do
    setup do
      %{payload: Sieve.request_payload(%{"title" => "Fed cuts rates", "description" => "FOMC"})}
    end

    test "asks for the local uncensored type, so a cloud model never scores it", %{payload: p} do
      assert p["model_type"] == "uncensored"
      assert p["model"] == "baytout3/qwen3.5-uncensored:4b"
    end

    test "turns thinking off, or the reply is an empty string", %{payload: p} do
      assert p["think"] == false
    end

    test "is an async, deterministic request carrying the item text", %{payload: p} do
      assert p["async"] == true
      assert p["temperature"] == 0
      assert p["query"] =~ "Title: Fed cuts rates"
      assert p["query"] =~ "Output ONLY the integer"
    end
  end
end
