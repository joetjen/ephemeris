defmodule Ephemeris.SentenceTest do
  use ExUnit.Case, async: true

  doctest Ephemeris.Sentence

  alias Ephemeris.RRule
  alias Ephemeris.Sentence

  # Each sentence, the RRULE it means, and the sentence it renders back to.
  # Where the third element is nil the sentence round-trips unchanged.
  @sentences [
    {"every 30 seconds", "FREQ=SECONDLY;INTERVAL=30", nil},
    {"every 5 minutes", "FREQ=MINUTELY;INTERVAL=5", nil},
    {"every hour", "FREQ=HOURLY", nil},
    {"every day", "FREQ=DAILY", nil},
    {"every 2 weeks on Monday", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO", nil},
    {"every Monday and Friday", "FREQ=WEEKLY;BYDAY=MO,FR", nil},
    {"every weekday", "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", nil},
    {"every last Sunday of the month", "FREQ=MONTHLY;BYDAY=-1SU", nil},
    {"every 3rd Monday of the month", "FREQ=MONTHLY;BYDAY=3MO", nil},
    {"every last weekday of the month", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", nil},
    {"every 1st of the month", "FREQ=MONTHLY;BYMONTHDAY=1", nil},
    {"every 29 February", "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29", nil},
    {"every Monday at 9:30 am", "FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=30;BYSECOND=0", nil},
    {"every day at midnight", "FREQ=DAILY;BYHOUR=0;BYMINUTE=0;BYSECOND=0", nil},
    {"every 1st of the month at 8:00 am",
     "FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=8;BYMINUTE=0;BYSECOND=0", nil}
  ]

  describe "parsing" do
    test "every supported sentence means the RRULE it should" do
      for {sentence, rrule, _rendered} <- @sentences do
        assert {:ok, rule} = Sentence.parse(sentence)
        assert RRule.render(rule) == rrule, "wrong rule for #{sentence}"
      end
    end

    test "ignores case and the words that carry no meaning" do
      assert {:ok, spelled} = Sentence.parse("Every Last Sunday Of The Month")
      assert {:ok, plain} = Sentence.parse("every last sunday of the month")
      assert spelled == plain
    end

    test "accepts spelled and numeric ordinals alike" do
      assert {:ok, spelled} = Sentence.parse("every third Monday of the month")
      assert {:ok, numeric} = Sentence.parse("every 3rd Monday of the month")
      assert spelled == numeric
    end

    test "reads times in several shapes" do
      assert {:ok, %{by_hour: [9], by_minute: [30]}} = Sentence.parse("every day at 9:30 am")
      assert {:ok, %{by_hour: [21], by_minute: [0]}} = Sentence.parse("every day at 9 pm")
      assert {:ok, %{by_hour: [0], by_minute: [0]}} = Sentence.parse("every day at midnight")
      assert {:ok, %{by_hour: [12], by_minute: [0]}} = Sentence.parse("every day at noon")
      assert {:ok, %{by_hour: [17], by_minute: [45]}} = Sentence.parse("every day at 17:45")
    end
  end

  describe "refusing" do
    # A sentence that parses into almost the right rule is worse than one that
    # fails: the failure is visible, the near-miss fires at the wrong time.
    test "refuses anything it does not recognise" do
      for sentence <- [
            "sometimes, whenever",
            "every blursday",
            "every 2 fortnights",
            "each monday",
            "every monday at",
            "every"
          ] do
        assert {:error, %{code: code}} = Sentence.parse(sentence)
        assert code in [:unsupported_expression, :invalid_expression], "accepted #{sentence}"
      end
    end
  end

  describe "rendering" do
    test "renders every rule back to the sentence it came from" do
      for {sentence, _rrule, rendered} <- @sentences do
        assert {:ok, rule} = Sentence.parse(sentence)
        assert Sentence.render(rule) == (rendered || sentence)
      end
    end

    test "renders a rule that was written as RRULE" do
      assert {:ok, rule} = RRule.parse("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")
      assert Sentence.render(rule) == "every last weekday of the month"
    end
  end
end
