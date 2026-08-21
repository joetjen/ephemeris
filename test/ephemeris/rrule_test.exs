defmodule Ephemeris.RRuleTest do
  use ExUnit.Case, async: true

  doctest Ephemeris.RRule

  alias Ephemeris.RRule
  alias Ephemeris.Rule

  describe "parsing" do
    test "reads every part RFC 5545 defines" do
      assert {:ok, rule} =
               RRule.parse(
                 "FREQ=MONTHLY;INTERVAL=2;WKST=SU;BYMONTH=3;BYWEEKNO=10;BYYEARDAY=-1;" <>
                   "BYMONTHDAY=1,-1;BYDAY=MO,-1SU;BYHOUR=9;BYMINUTE=30;BYSECOND=0;BYSETPOS=-1"
               )

      assert %Rule{
               frequency: :monthly,
               interval: 2,
               week_start: :sunday,
               by_month: [3],
               by_week_number: [10],
               by_year_day: [-1],
               by_month_day: [1, -1],
               by_day: [:monday, {-1, :sunday}],
               by_hour: [9],
               by_minute: [30],
               by_second: [0],
               by_set_position: [-1]
             } = rule
    end

    test "accepts the RRULE: prefix an iCalendar line carries" do
      assert {:ok, %Rule{frequency: :daily}} = RRule.parse("RRULE:FREQ=DAILY")
    end

    test "defaults interval and week start rather than leaving them unset" do
      assert {:ok, %Rule{interval: 1, week_start: :monday}} = RRule.parse("FREQ=DAILY")
    end

    test "reads UNTIL with and without a time part" do
      assert {:ok, %Rule{until: ~U[2026-03-15 09:00:00Z]}} =
               RRule.parse("FREQ=DAILY;UNTIL=20260315T090000Z")

      assert {:ok, %Rule{until: ~U[2026-03-15 00:00:00Z]}} =
               RRule.parse("FREQ=DAILY;UNTIL=20260315")
    end
  end

  describe "rejecting" do
    # Strict on purpose: a rule that silently drops a constraint fires at the
    # wrong time, which is worse than one that refuses to load.
    test "refuses a rule with no frequency" do
      assert {:error, %{code: :missing_frequency}} = RRule.parse("INTERVAL=2")
    end

    test "refuses an unsupported frequency" do
      assert {:error, %{code: :invalid_frequency, details: %{value: "FORTNIGHTLY"}}} =
               RRule.parse("FREQ=FORTNIGHTLY")
    end

    test "refuses COUNT and UNTIL together, which the standard forbids" do
      assert {:error, %{code: :conflicting_parts}} =
               RRule.parse("FREQ=DAILY;COUNT=5;UNTIL=20260101T000000Z")
    end

    test "refuses an unrecognised part rather than ignoring it" do
      assert {:error, %{code: :unknown_part, details: %{part: "BOGUS"}}} =
               RRule.parse("FREQ=DAILY;BOGUS=1")
    end

    test "refuses out-of-range and zero values" do
      assert {:error, %{code: :invalid_part}} = RRule.parse("FREQ=MONTHLY;BYMONTHDAY=0")
      assert {:error, %{code: :invalid_part}} = RRule.parse("FREQ=DAILY;BYHOUR=24")
      assert {:error, %{code: :invalid_part}} = RRule.parse("FREQ=YEARLY;BYMONTH=13")
    end

    test "refuses a malformed weekday" do
      assert {:error, %{code: :invalid_part, details: %{part: "BYDAY"}}} =
               RRule.parse("FREQ=WEEKLY;BYDAY=XX")
    end

    test "refuses malformed syntax" do
      assert {:error, %{code: :invalid_expression}} = RRule.parse("FREQ")
      assert {:error, %{code: :invalid_expression}} = RRule.parse("FREQ=")
    end
  end

  describe "rendering" do
    @round_trip [
      "FREQ=DAILY",
      "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE",
      "FREQ=MONTHLY;BYDAY=-1SU",
      "FREQ=MONTHLY;BYDAY=3MO",
      "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1",
      "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29",
      "FREQ=WEEKLY;WKST=SU;BYDAY=SU",
      "FREQ=DAILY;COUNT=10",
      "FREQ=DAILY;UNTIL=20260315T090000Z",
      "FREQ=HOURLY;BYMINUTE=0,30"
    ]

    test "renders every rule back to the text it was parsed from" do
      for expression <- @round_trip do
        assert {:ok, rule} = RRule.parse(expression)
        assert RRule.render(rule) == expression, "round trip failed for #{expression}"
      end
    end

    test "orders parts canonically regardless of input order" do
      assert {:ok, rule} = RRule.parse("BYDAY=MO,WE;FREQ=WEEKLY;INTERVAL=2")
      assert RRule.render(rule) == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE"
    end

    test "omits parts left at their default" do
      assert {:ok, rule} = RRule.parse("FREQ=DAILY;INTERVAL=1;WKST=MO")
      assert RRule.render(rule) == "FREQ=DAILY"
    end
  end
end
