defmodule BotArmyRssPolling.Triggers.DateNightTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyRssPolling.Triggers.DateNight

  @today ~D[2026-11-22]

  defp idea(title, attrs \\ %{}) do
    Map.merge(
      %{
        "title" => title,
        "url" => "https://x.test/" <> String.replace(title, " ", "-"),
        "energy" => "cozy",
        "when" => "anytime",
        "outing" => 0.8,
        "source" => "x.test",
        "seen" => "2026-11-22"
      },
      attrs
    )
  end

  describe "merge/3" do
    test "new ideas are added, and an idea seen again keeps its first-seen date" do
      state =
        DateNight.merge(
          %{"ideas" => [], "pick" => nil},
          [idea("Holiday market", %{"seen" => "2026-11-20"})],
          @today
        )

      again =
        DateNight.merge(
          state,
          [idea("Holiday market", %{"seen" => "2026-11-22", "outing" => 0.9})],
          @today
        )

      assert [only] = again["ideas"]
      assert only["seen"] == "2026-11-20"
      assert only["outing"] == 0.9
    end

    test "old ideas fall away: a dated event after 4 days, anything else after 21" do
      old = [
        idea("Tonight only", %{"when" => "dated_event", "seen" => "2026-11-17"}),
        idea("Hot springs", %{"when" => "anytime", "seen" => "2026-11-05"}),
        idea("Very old market", %{"when" => "this_season", "seen" => "2026-10-20"})
      ]

      state = DateNight.merge(%{"ideas" => old, "pick" => nil}, [], @today)
      assert Enum.map(state["ideas"], & &1["title"]) == ["Hot springs"]
    end

    test "the list is capped, keeping the best, so it cannot grow without end" do
      many = for n <- 1..80, do: idea("Idea #{n}", %{"outing" => n / 100})
      state = DateNight.merge(%{"ideas" => [], "pick" => nil}, many, @today)
      assert length(state["ideas"]) == 40
      assert Enum.all?(state["ideas"], &(&1["outing"] >= 0.41))
    end
  end

  describe "choose/2" do
    test "a fresh dated event outranks an evergreen idea of the same score" do
      state = %{
        "ideas" => [idea("Evergreen"), idea("This week's show", %{"when" => "dated_event"})],
        "pick" => nil
      }

      assert %{pick: pick, backups: [backup]} = DateNight.choose(state, @today)
      assert pick["title"] == "This week's show"
      assert backup["title"] == "Evergreen"
    end

    test "one pick and at most two backups, ranked" do
      ideas =
        for {t, s} <- [{"a", 0.7}, {"b", 0.95}, {"c", 0.8}, {"d", 0.75}],
            do: idea(t, %{"outing" => s})

      assert %{pick: pick, backups: backups} =
               DateNight.choose(%{"ideas" => ideas, "pick" => nil}, @today)

      assert pick["title"] == "b"
      assert Enum.map(backups, & &1["title"]) == ["c", "d"]
    end

    test "the pick is sticky: a better idea arriving does not swap it while it is still good" do
      ideas = [idea("Current", %{"outing" => 0.75}), idea("Shinier", %{"outing" => 0.99})]
      state = %{"ideas" => ideas, "pick" => "https://x.test/Current"}

      assert %{pick: %{"title" => "Current"}, backups: [%{"title" => "Shinier"}]} =
               DateNight.choose(state, @today)
    end

    test "a pick that has expired is replaced" do
      ideas = [idea("Gone", %{"when" => "dated_event", "seen" => "2026-11-10"}), idea("Fresh")]
      state = %{"ideas" => ideas, "pick" => "https://x.test/Gone"}
      assert %{pick: %{"title" => "Fresh"}} = DateNight.choose(state, @today)
    end

    test "nothing to suggest is nothing, not an empty pick" do
      assert DateNight.choose(%{"ideas" => [], "pick" => nil}, @today) == :none
    end
  end

  describe "render/2" do
    defp sample_state do
      %{
        "ideas" => [
          idea("Holiday market", %{"energy" => "cozy", "when" => "this_season"}),
          idea("Hot springs", %{"energy" => "adventure", "when" => "anytime"}),
          idea("Thursday jams", %{"energy" => "moderate", "when" => "dated_event"})
        ],
        "pick" => "https://x.test/Holiday-market"
      }
    end

    test "one idea with a first step, two backups, and a plain warning that dates are not checked" do
      md = DateNight.render(sample_state(), @today)

      assert md =~ "# Date night — this week"
      assert md =~ "## One idea"
      assert md =~ "**Holiday market**"
      assert md =~ "First step:"
      assert md =~ "## Two backups"
      assert md =~ "Dates aren't checked"
    end

    test "it is a note, not a to-do list: no checkboxes, no deadlines, no counts of what was missed" do
      md = DateNight.render(sample_state(), @today)

      refute md =~ "- [ ]"
      refute String.downcase(md) =~ "overdue"
      refute String.downcase(md) =~ "missed"
      refute String.downcase(md) =~ "should"
      assert md =~ "Nothing here is a to-do"
    end

    test "the first step fits the kind of idea" do
      assert DateNight.first_step(idea("x", %{"when" => "dated_event"})) =~ "check the date"
      assert DateNight.first_step(idea("x", %{"when" => "this_season"})) =~ "season"

      assert DateNight.first_step(idea("x", %{"when" => "anytime", "energy" => "adventure"})) =~
               "weather"
    end

    test "nothing to suggest says so kindly and keeps the file honest" do
      md = DateNight.render(%{"ideas" => [], "pick" => nil}, @today)
      assert md =~ "Nothing new this week"
      refute md =~ "## One idea"
    end
  end

  describe "ends_on/2: the end date the title itself states" do
    test "a day range in one month" do
      assert DateNight.ends_on("Free things to do this weekend, Nov. 20-22", @today) ==
               ~D[2026-11-22]
    end

    test "a range across months, and with the word to" do
      assert DateNight.ends_on("Events Nov 28 to Dec 3", @today) == ~D[2026-12-03]
      assert DateNight.ends_on("Lights through Dec. 31", @today) == ~D[2026-12-31]
    end

    test "a single date, long month names, and the latest date wins" do
      assert DateNight.ends_on("Opening night November 27", @today) == ~D[2026-11-27]
      assert DateNight.ends_on("Fri Nov 20 and Sat Nov 21 shows", @today) == ~D[2026-11-21]
    end

    test "a January date seen in December is next year; a December date seen in January is last year" do
      assert DateNight.ends_on("Parade Jan 3", ~D[2026-12-28]) == ~D[2027-01-03]
      assert DateNight.ends_on("Holiday market Dec 20", ~D[2027-01-05]) == ~D[2026-12-20]
    end

    test "no date, an impossible date, or words that only look like one give nil" do
      assert DateNight.ends_on("Best hot springs near Denver", @today) == nil
      assert DateNight.ends_on("Feb 31 special", @today) == nil
      assert DateNight.ends_on("The Mayor's march of progress", @today) == nil
      assert DateNight.ends_on(nil, @today) == nil
    end
  end

  describe "an idea whose title says when it ends" do
    test "is gone the day after it ends, even though it was seen only yesterday" do
      over =
        idea("Free things this weekend, Nov. 14-15", %{
          "when" => "dated_event",
          "seen" => "2026-11-21"
        })

      state = DateNight.merge(%{"ideas" => [over], "pick" => nil}, [], @today)
      assert state["ideas"] == []
    end

    test "is kept through its last day, however long ago it was first seen" do
      on =
        idea("Free things this weekend, Nov. 20-22", %{
          "when" => "dated_event",
          "seen" => "2026-11-16"
        })

      state = DateNight.merge(%{"ideas" => [on], "pick" => nil}, [], @today)
      assert [_] = state["ideas"]

      assert %{pick: %{"title" => "Free things this weekend, Nov. 20-22"}} =
               DateNight.choose(state, @today)
    end

    test "an expired pick is replaced by the next idea, and the note stops showing it" do
      over =
        idea("Free things this weekend, Nov. 14-15", %{
          "when" => "dated_event",
          "seen" => "2026-11-21"
        })

      fresh = idea("Hot springs")
      state = %{"ideas" => [over, fresh], "pick" => over["url"]}
      assert %{pick: %{"title" => "Hot springs"}} = DateNight.choose(state, @today)
      refute DateNight.render(state, @today) =~ "Nov. 14-15"
    end

    test "an evergreen idea ignores a date in its title" do
      any =
        idea("Why I loved the Nov 3 hot springs trip", %{
          "when" => "anytime",
          "seen" => "2026-11-20"
        })

      state = DateNight.merge(%{"ideas" => [any], "pick" => nil}, [], @today)
      assert [_] = state["ideas"]
    end
  end

  describe "round trip through the file" do
    test "the state survives being written into the note and read back" do
      state = %{
        "ideas" => [idea("Holiday market"), idea("Hot springs")],
        "pick" => "https://x.test/Hot-springs"
      }

      assert DateNight.parse(DateNight.render(state, @today)) == state
    end

    test "no note at all reads as empty state" do
      assert DateNight.parse(nil) == %{"ideas" => [], "pick" => nil}
    end

    test "a note without our state, or with state we cannot read, is foreign: never treated as empty" do
      assert DateNight.parse("# Date night\n\njust words Abby typed") == :foreign
      assert DateNight.parse("<!-- sensing-state v1\nnot json\n-->") == :foreign

      assert DateNight.parse("<!-- sensing-state v1\n" <> Base.encode64("[1,2]") <> "\n-->") ==
               :foreign
    end

    test "a title containing --> cannot end the state comment early" do
      nasty =
        idea("Sale --> everything 50% off <!-- sensing-state v1", %{"url" => "https://x.test/n"})

      state = %{"ideas" => [nasty], "pick" => nil}
      md = DateNight.render(state, @today)

      assert DateNight.parse(md) == state
      [_, comment] = String.split(md, "<!-- sensing-state v1", parts: 2)
      [encoded, _] = String.split(comment, "-->", parts: 2)
      refute encoded =~ "Sale"
    end

    test "titles with quotes, dashes and html-ish text survive" do
      weird =
        idea(~s(Rock & "Roll" <b>night</b> — 2-for-1), %{"url" => "https://x.test/a?b=1&c=2"})

      state = %{"ideas" => [weird], "pick" => weird["url"]}
      assert DateNight.parse(DateNight.render(state, @today)) == state
    end
  end

  describe "apply/2: reads the note, merges, writes only when something changed" do
    defmodule Para do
      @moduledoc false
      def read(path), do: Process.get({:file, path}, {:error, :not_found})

      def write(path, content) do
        send(self(), {:wrote, path, content})
        Process.put({:file, path}, {:ok, content})
        :ok
      end
    end

    @path "projects/Date Night/this_week.md"

    test "the first ideas create the note" do
      assert :written = DateNight.apply([idea("Holiday market")], para: Para, today: @today)
      assert_received {:wrote, @path, md}
      assert md =~ "**Holiday market**"
    end

    test "the same ideas again change nothing and write nothing" do
      DateNight.apply([idea("Holiday market")], para: Para, today: @today)
      assert_received {:wrote, @path, _}

      assert :unchanged = DateNight.apply([idea("Holiday market")], para: Para, today: @today)
      refute_received {:wrote, _, _}
    end

    test "no ideas and no note writes nothing" do
      assert :unchanged = DateNight.apply([], para: Para, today: @today)
      refute_received {:wrote, _, _}
    end

    test "a note Abby has written herself is left alone: nothing is written, and it is reported" do
      Process.put({:file, @path}, {:ok, "# Date night\n\nMy own list: the hot springs one!\n"})

      assert {:error, :foreign_note} = DateNight.apply([idea("x")], para: Para, today: @today)
      refute_received {:wrote, _, _}
    end

    test "a store that will not answer is an error, and the note is not overwritten with less" do
      defmodule Down do
        @moduledoc false
        def read(_), do: {:error, :timeout}
        def write(_, _), do: flunk("must not write when the read failed")
      end

      assert {:error, :timeout} = DateNight.apply([idea("x")], para: Down, today: @today)
    end
  end

  describe "Para adapter reply reading, against bodies captured from the live door (2026-11-22)" do
    alias BotArmyRssPolling.Triggers.DateNight.Para, as: Adapter

    @read_ok %{
      "ok" => true,
      "data" => %{
        "content" => "hello",
        "encoding" => "utf-8",
        "relative_path" => "a/b.md",
        "bytes_read" => 5
      }
    }
    @missing %{"ok" => false, "code" => "validation_error", "error" => "path is not a file"}
    @other_refusal %{
      "ok" => false,
      "code" => "validation_error",
      "error" => "path escapes the PARA root"
    }

    test "a read that answers carries the content" do
      assert Adapter.read_reply({:ok, @read_ok}) == {:ok, "hello"}
    end

    test "a missing file is :not_found, and only that refusal is" do
      assert Adapter.read_reply({:ok, @missing}) == {:error, :not_found}
      assert Adapter.read_reply({:ok, @other_refusal}) == {:error, "path escapes the PARA root"}
    end

    test "a timeout or a broken reply is an error, never :not_found" do
      assert Adapter.read_reply({:error, :timeout}) == {:error, :timeout}
      assert {:error, {:unexpected_reply, _}} = Adapter.read_reply({:ok, %{"weird" => 1}})
    end

    test "a write is ok only when the door says ok" do
      assert Adapter.write_reply({:ok, %{"ok" => true, "data" => %{}}}) == :ok
      assert Adapter.write_reply({:ok, @other_refusal}) == {:error, "path escapes the PARA root"}
      assert Adapter.write_reply({:error, :timeout}) == {:error, :timeout}
    end
  end
end
