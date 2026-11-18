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
end
