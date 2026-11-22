defmodule BotArmyRssPolling.DateIdeasTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyRssPolling.DateIdeas

  defp item(n, title, desc \\ "") do
    %{"guid" => "g#{n}", "title" => title, "url" => "https://x.test/#{n}", "description" => desc}
  end

  # The live llm.decide envelope, as captured from the deployed llm 0.11.0 door.
  defp ok(answers),
    do:
      {:ok,
       %{"event" => "llm.decide.response", "payload" => %{"ok" => true, "answers" => answers}}}

  defp refused(code),
    do: {:ok, %{"payload" => %{"ok" => false, "error" => %{"code" => code}}}}

  # A fake Clef: answers each question it is asked from a table keyed by item title.
  defp clef(table) do
    test = self()

    fn req ->
      send(test, {:asked, req["where"], Map.keys(req["questions"])})

      titles =
        req["state"]
        |> String.split("\n")
        |> Enum.map(&(String.split(&1, ". ", parts: 2) |> List.last()))

      ok(Map.new(req["questions"], fn {q, _} -> answer(q, table, titles) end))
    end
  end

  defp answer(q, table, titles) do
    [_, n, kind] = Regex.run(~r/^i(\d+)_(\w+)$/, q)
    row = Map.fetch!(table, Enum.at(titles, String.to_integer(n) - 1))

    case kind do
      "outing" -> {q, %{"type" => "noul", "noul" => row.outing}}
      "energy" -> {q, %{"type" => "choice", "choice" => row.energy}}
      "when" -> {q, %{"type" => "choice", "choice" => row.when}}
    end
  end

  @table %{
    "Holiday market" => %{outing: 0.97, energy: "cozy", when: "this_season"},
    "Bedbugs in shelters" => %{outing: 0.02, energy: "cozy", when: "anytime"},
    "Hot springs day trip" => %{outing: 0.88, energy: "adventure", when: "anytime"},
    "maybe" => %{outing: 0.69, energy: "moderate", when: "anytime"}
  }

  test "eligible?/1: only feeds tagged date_night take part" do
    assert DateIdeas.eligible?(["local", "denver_local", "date_night"])
    refute DateIdeas.eligible?(["local", "news"])
  end

  describe "requests" do
    test "the outing pass asks one noul per item over a numbered state" do
      req =
        DateIdeas.outing_request([
          item(1, "Holiday market", "Saturday, free"),
          item(2, "RTD news")
        ])

      assert req["state"] =~ "1. Holiday market — Saturday, free"
      assert req["state"] =~ "2. RTD news"
      assert Map.keys(req["questions"]) |> Enum.sort() == ~w(i1_outing i2_outing)
      assert req["questions"]["i1_outing"]["type"] == "noul"
      assert req["questions"]["i2_outing"]["instructions"] =~ "item 2"
    end

    test "the detail pass asks energy and when" do
      req = DateIdeas.detail_request([item(1, "Holiday market")])
      assert Map.keys(req["questions"]) |> Enum.sort() == ~w(i1_energy i1_when)

      assert Map.keys(req["questions"]["i1_energy"]["criteria"]) |> Enum.sort() ==
               ~w(adventure cozy moderate)

      assert Map.keys(req["questions"]["i1_when"]["criteria"]) |> Enum.sort() ==
               ~w(anytime dated_event this_season)
    end

    test "descriptions are stripped of HTML and capped" do
      req =
        DateIdeas.outing_request([
          item(1, "Show", "<p>" <> String.duplicate("a", 2000) <> "&amp;</p>")
        ])

      refute req["state"] =~ "<p>"
      refute req["state"] =~ "&amp;"
      assert String.length(req["state"]) < 400
    end
  end

  describe "classify/2" do
    test "keeps the outings over the bar with energy and timing, drops the news" do
      items = [
        item(1, "Holiday market"),
        item(2, "Bedbugs in shelters"),
        item(3, "Hot springs day trip")
      ]

      assert {:ok, ideas} = DateIdeas.classify(items, clef(@table))

      assert [
               {%{"guid" => "g1"},
                %{"outing" => 0.97, "energy" => "cozy", "when" => "this_season"}},
               {%{"guid" => "g3"},
                %{"outing" => 0.88, "energy" => "adventure", "when" => "anytime"}}
             ] = ideas
    end

    test "the detail pass only asks about the items that passed" do
      items = [item(1, "Holiday market"), item(2, "Bedbugs in shelters")]
      DateIdeas.classify(items, clef(@table))

      assert_received {:asked, "large", ["i1_outing", "i2_outing"]}
      assert_received {:asked, "large", detail_qs}
      assert Enum.sort(detail_qs) == ~w(i1_energy i1_when)
    end

    test "an item just under the bar is not an idea, and no detail is asked" do
      assert {:ok, []} = DateIdeas.classify([item(1, "maybe")], clef(@table))
      assert_received {:asked, "large", ["i1_outing"]}
      refute_received {:asked, _, _}
    end

    test "decisions are small: 12 outings, then 6 details, per request" do
      items = Enum.map(1..30, &item(&1, "Holiday market"))
      {:ok, ideas} = DateIdeas.classify(items, clef(@table))
      assert length(ideas) == 30

      sizes =
        Stream.repeatedly(fn ->
          receive do
            {:asked, _, qs} -> length(qs)
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)

      # 3 outing decisions (12,12,6), then 5 detail decisions of 6 items x 2 questions.
      assert sizes == [12, 12, 6, 12, 12, 12, 12, 12]
    end

    test "large refused: local is asked, explicitly, and its answer is used" do
      large_then_local = fn req ->
        send(self(), {:where, req["where"]})
        if req["where"] == "large", do: refused("circuit_open"), else: clef(@table).(req)
      end

      assert {:ok, [{%{"guid" => "g1"}, _}]} =
               DateIdeas.classify([item(1, "Holiday market")], large_then_local)

      assert_received {:where, "large"}
      assert_received {:where, "local"}
    end

    test "both refused is an error, never an empty list that reads as no ideas" do
      assert {:error, {:decide_refused, "circuit_open"}} =
               DateIdeas.classify([item(1, "x")], fn _ -> refused("circuit_open") end)

      assert {:error, :timeout} =
               DateIdeas.classify([item(1, "x")], fn _ -> {:error, :timeout} end)
    end

    test "nothing to classify asks nothing" do
      assert {:ok, []} = DateIdeas.classify([], fn _ -> flunk("should not ask") end)
    end
  end

  describe "report?/1: a title that reports something already over is not an outing" do
    test "past-event wording is caught, from the real titles that got through" do
      for t <- [
            "Denver just hosted its first Hyrox, the world’s fastest-growing fitness race",
            "Recap: the Turkey Trot drew 10,000 runners",
            "What happened at the Boulder Film Festival last weekend",
            "Thousands showed up last night for the tree lighting",
            "The marathon wrapped up Sunday with record times",
            "The Great Colorado Beer Fest took place at Mile High"
          ] do
        assert DateIdeas.report?(item(1, t)), t
      end
    end

    test "real outings, including ones that merely sound recent, are not caught" do
      for t <- [
            "Free things to do in Denver this weekend, Nov. 20-22",
            "A new Thai restaurant just opened in RiNo",
            "Thursday-night jams are coming back to River North",
            "Hot springs near Denver for a winter soak",
            "The Nutcracker returns to the Buell this December"
          ] do
        refute DateIdeas.report?(item(1, t)), t
      end
    end

    test "classify never asks Clef about a report, and asks nothing when only reports remain" do
      assert {:ok, []} =
               DateIdeas.classify(
                 [item(1, "Denver just hosted its first Hyrox")],
                 fn _ -> flunk("a report must not be sent to Clef") end
               )
    end

    test "classify still judges the real outings beside a report" do
      items = [item(1, "Denver just hosted its first Hyrox"), item(2, "Holiday market")]
      assert {:ok, [{%{"guid" => "g2"}, _}]} = DateIdeas.classify(items, clef(@table))
    end

    test "the outing question tells the model what is not an outing" do
      %{"questions" => %{"i1_outing" => %{"instructions" => text}}} =
        DateIdeas.outing_request([item(1, "x")])

      assert text =~ "already happened"
      assert text =~ "sports"
    end
  end
end
