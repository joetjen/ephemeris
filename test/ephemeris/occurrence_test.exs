defmodule Ephemeris.OccurrenceTest do
  use ExUnit.Case, async: true

  alias Ephemeris.Occurrence
  alias Ephemeris.RRule

  @reference ~U[2026-01-01 09:00:00Z]

  defp occurrences(expression, count, reference \\ @reference) do
    assert {:ok, rule} = RRule.parse(expression)

    rule
    |> Occurrence.stream(reference)
    |> Enum.take(count)
    |> Enum.map(&Calendar.strftime(&1, "%Y-%m-%d %H:%M:%S"))
  end

  describe "simple frequencies" do
    test "daily, with and without an interval" do
      assert occurrences("FREQ=DAILY", 3) ==
               ["2026-01-02 09:00:00", "2026-01-03 09:00:00", "2026-01-04 09:00:00"]

      assert occurrences("FREQ=DAILY;INTERVAL=2", 3) ==
               ["2026-01-03 09:00:00", "2026-01-05 09:00:00", "2026-01-07 09:00:00"]
    end

    test "weekly on named days" do
      assert occurrences("FREQ=WEEKLY;BYDAY=MO,WE", 3) ==
               ["2026-01-05 09:00:00", "2026-01-07 09:00:00", "2026-01-12 09:00:00"]
    end

    test "every other week keeps its cadence across month boundaries" do
      assert occurrences("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO", 3) ==
               ["2026-01-12 09:00:00", "2026-01-26 09:00:00", "2026-02-09 09:00:00"]
    end
  end

  describe "sub-daily frequencies" do
    # These step the clock rather than the calendar, so the time of day comes
    # from the period rather than the reference. Getting that backwards makes
    # every occurrence identical.
    test "hourly advances the hour" do
      assert occurrences("FREQ=HOURLY", 3) ==
               ["2026-01-01 10:00:00", "2026-01-01 11:00:00", "2026-01-01 12:00:00"]
    end

    test "hourly narrowed to certain minutes" do
      assert occurrences("FREQ=HOURLY;BYMINUTE=0,30", 4) ==
               [
                 "2026-01-01 09:30:00",
                 "2026-01-01 10:00:00",
                 "2026-01-01 10:30:00",
                 "2026-01-01 11:00:00"
               ]
    end

    test "minutely with an interval" do
      assert occurrences("FREQ=MINUTELY;INTERVAL=15", 3) ==
               ["2026-01-01 09:15:00", "2026-01-01 09:30:00", "2026-01-01 09:45:00"]
    end
  end

  describe "ordinal weekdays" do
    test "the last Sunday of each month" do
      assert occurrences("FREQ=MONTHLY;BYDAY=-1SU", 3) ==
               ["2026-01-25 09:00:00", "2026-02-22 09:00:00", "2026-03-29 09:00:00"]
    end

    test "the third Monday of each month" do
      assert occurrences("FREQ=MONTHLY;BYDAY=3MO", 3) ==
               ["2026-01-19 09:00:00", "2026-02-16 09:00:00", "2026-03-16 09:00:00"]
    end

    test "an ordinal counts within the year when the frequency is yearly" do
      assert occurrences("FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10", 2) ==
               ["2026-10-25 09:00:00", "2027-10-31 09:00:00"]
    end
  end

  describe "month lengths and leap years" do
    # RFC 5545 §3.3.10: a date that does not exist in a period is skipped, not
    # clamped. Clamping is the failure that makes a scheduler fire on the wrong
    # day, silently.
    test "the 31st skips months that have no 31st" do
      assert occurrences("FREQ=MONTHLY;BYMONTHDAY=31", 3) ==
               ["2026-01-31 09:00:00", "2026-03-31 09:00:00", "2026-05-31 09:00:00"]
    end

    test "a negative month day counts back from the real end of each month" do
      assert occurrences("FREQ=MONTHLY;BYMONTHDAY=-1", 3) ==
               ["2026-01-31 09:00:00", "2026-02-28 09:00:00", "2026-03-31 09:00:00"]
    end

    test "29 February occurs only in leap years" do
      assert occurrences("FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29", 2) ==
               ["2028-02-29 09:00:00", "2032-02-29 09:00:00"]
    end
  end

  describe "BYSETPOS" do
    # The whole period's candidates must exist before the nth can be chosen,
    # which is why occurrences are built a period at a time.
    test "the last weekday of each month" do
      assert occurrences("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", 3) ==
               ["2026-01-30 09:00:00", "2026-02-27 09:00:00", "2026-03-31 09:00:00"]
    end

    test "the first weekday of each month" do
      assert occurrences("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=1", 2) ==
               ["2026-02-02 09:00:00", "2026-03-02 09:00:00"]
    end
  end

  describe "bounds" do
    test "COUNT stops after the given number" do
      assert occurrences("FREQ=DAILY;COUNT=2", 5) ==
               ["2026-01-02 09:00:00", "2026-01-03 09:00:00"]
    end

    test "UNTIL stops at the given instant, inclusive" do
      assert occurrences("FREQ=DAILY;UNTIL=20260104T090000Z", 5) ==
               ["2026-01-02 09:00:00", "2026-01-03 09:00:00", "2026-01-04 09:00:00"]
    end

    test "an exhausted rule reports no occurrence rather than looping" do
      assert {:ok, rule} = RRule.parse("FREQ=DAILY;UNTIL=20251231T000000Z")
      assert {:error, %{code: :no_occurrence}} = Occurrence.next(rule, @reference)
    end

    test "a rule that can never match reports no occurrence" do
      assert {:ok, rule} = RRule.parse("FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30")
      assert {:error, %{code: :no_occurrence}} = Occurrence.next(rule, @reference)
    end
  end

  describe "next/2" do
    test "is strictly after the reference, so feeding it back advances" do
      assert {:ok, rule} = RRule.parse("FREQ=DAILY")
      assert {:ok, first} = Occurrence.next(rule, @reference)
      assert {:ok, second} = Occurrence.next(rule, first)
      assert DateTime.compare(first, @reference) == :gt
      assert DateTime.compare(second, first) == :gt
    end
  end
end
