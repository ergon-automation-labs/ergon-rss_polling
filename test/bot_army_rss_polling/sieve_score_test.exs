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
      assert p["prompt_context"]["prompt"] =~ "Title: Fed cuts rates"
      assert p["prompt_context"]["prompt"] =~ "Output ONLY the integer"
    end

    test "the prompt is where llm.request.chat reads it; a top-level query is ignored there",
         %{payload: p} do
      refute Map.has_key?(p, "query")
      assert is_binary(get_in(p, ["prompt_context", "prompt"]))
    end
  end

  describe "read_result/2" do
    import ExUnit.CaptureLog

    test "a readable reply is scored and logs nothing" do
      log =
        capture_log(fn ->
          assert {:ok, 7} = Sieve.read_result("j1", %{"data" => %{"content" => "7"}})
        end)

      refute log =~ "unreadable"
    end

    test "an empty reply is logged raw with its shape and job id" do
      log =
        capture_log(fn ->
          assert {:error, :parse_error} =
                   Sieve.read_result("job-abc", %{"data" => %{"content" => ""}})
        end)

      assert log =~ "Sieve reply unreadable (parse_error)"
      assert log =~ "job=job-abc"
      assert log =~ "shape=map"
      assert log =~ ~s("content" => "")
    end

    test "a reply in an unknown shape is logged with its keys, not dropped" do
      log =
        capture_log(fn ->
          assert {:error, :empty_response} = Sieve.read_result("j2", %{"completion" => "9"})
        end)

      assert log =~ "unreadable (empty_response)"
      assert log =~ "completion"
    end

    test "a long reply is cut, not dumped whole" do
      long = String.duplicate("word ", 400)

      log =
        capture_log(fn ->
          Sieve.read_result("j3", %{"data" => %{"content" => long}})
        end)

      assert byte_size(log) < 1_200
    end
  end
end
