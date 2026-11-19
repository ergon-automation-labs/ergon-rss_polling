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
end
