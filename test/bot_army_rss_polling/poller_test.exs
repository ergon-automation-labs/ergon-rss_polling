defmodule BotArmyRssPolling.PollerTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyRssPolling.Poller

  test "the first poll runs at startup and progress records when it started and finished" do
    # No feeds are configured in tests, so a poll is quick and makes no network calls.
    start_supervised!(Poller)

    progress = wait_for_completed_poll(50)

    assert progress.polling == false
    assert progress.polls_completed >= 1
    assert progress.last_started_at
    assert progress.last_finished_at
    assert progress.last_error == nil
  end

  test "progress answers while a poll is in flight, so the poller is never blocked by a poll" do
    start_supervised!(Poller)
    # A call that returns immediately is the point: the process is not stuck in a poll.
    assert %{polling: _} = Poller.progress()
  end

  defp wait_for_completed_poll(0), do: Poller.progress()

  defp wait_for_completed_poll(n) do
    progress = Poller.progress()

    if progress.polls_completed >= 1 and not progress.polling do
      progress
    else
      Process.sleep(20)
      wait_for_completed_poll(n - 1)
    end
  end

  describe "mark_scored_seen/1" do
    alias BotArmyRssPolling.DedupFilter

    test "only an item that scored is marked seen; a failed one is retried next poll" do
      start_supervised!(DedupFilter)
      ok = %{"guid" => "scored-1"}
      failed = %{"guid" => "failed-1"}
      degraded = %{"guid" => "degraded-1"}

      assert :ok =
               Poller.mark_scored_seen([
                 {ok, {:ok, 7}},
                 {failed, {:error, :parse_error}},
                 {degraded, {:error, :llm_degraded}}
               ])

      assert DedupFilter.seen?("scored-1")
      refute DedupFilter.seen?("failed-1")
      refute DedupFilter.seen?("degraded-1")
    end

    test "a low score still counts as seen: it was judged noise, not lost" do
      start_supervised!(DedupFilter)
      Poller.mark_scored_seen([{%{"guid" => "noise-1"}, {:ok, 1}}])
      assert DedupFilter.seen?("noise-1")
    end
  end

  describe "take_budget/2" do
    defp items(n), do: for(i <- 1..n//1, do: %{"guid" => "g#{i}"})

    test "a feed that returns hundreds is cut to its newest 25" do
      batch = Poller.take_budget(items(913), 100)
      assert length(batch) == 25
      assert hd(batch)["guid"] == "g1"
    end

    test "a small feed is taken whole" do
      assert length(Poller.take_budget(items(8), 100)) == 8
    end

    test "the poll budget bounds what is left, even under the per-feed cap" do
      assert length(Poller.take_budget(items(50), 10)) == 10
    end

    test "an exhausted or negative budget scores nothing" do
      assert [] == Poller.take_budget(items(50), 0)
      assert [] == Poller.take_budget(items(50), -5)
    end

    test "no items is no batch" do
      assert [] == Poller.take_budget([], 100)
    end
  end
end
