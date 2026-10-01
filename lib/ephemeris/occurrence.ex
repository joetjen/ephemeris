defmodule Ephemeris.Occurrence do
  @moduledoc """
  Computes when a rule fires.

  ## How it works

  Occurrences are produced one *period* at a time — a year for `FREQ=YEARLY`, a
  month for `FREQ=MONTHLY`, and so on — rather than by stepping forward instant
  by instant. For each period the whole candidate set is built, sorted, and only
  then filtered.

  That order is not an implementation detail: `BYSETPOS` selects the *nth
  candidate of the period*, so the set must exist before the selection can be
  made. `BYSETPOS=-1` on weekdays means the last weekday of that month, which
  cannot be known while walking days one at a time.

  ## Time of day

  RFC 5545 takes the time of day from the event's `DTSTART` when no `BYHOUR`,
  `BYMINUTE` or `BYSECOND` narrows it. A rule here has no `DTSTART` — it is a
  rule, not an event — so the reference instant supplies it. Asking for the next
  occurrence after `09:00` of a daily rule gives `09:00` the following day.

  ## Bounds

  A rule matching nothing would search forever, so the search stops after a
  fixed number of periods and reports that there is no occurrence. `COUNT` and
  `UNTIL` are honoured relative to the reference: an exhausted rule reports the
  same.
  """

  alias Ephemeris.Error
  alias Ephemeris.Rule

  # Enough to step over the longest realistic gap -- `FREQ=YEARLY` restricted to
  # 29 February skips three years at a time, and a `BYWEEKNO`/`BYDAY` pair can
  # skip several more.
  @period_limit 1_000

  ##
  ## Public API
  ##

  @doc """
  Returns the first occurrence strictly after `reference`.

  Strictly after, so feeding an occurrence back in yields the following one
  rather than the same instant forever.
  """
  @spec next(Rule.t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, Error.t()}
  def next(%Rule{} = rule, %DateTime{} = reference) do
    case rule |> stream(reference) |> Enum.take(1) do
      [occurrence] -> {:ok, occurrence}
      [] -> {:error, Error.no_occurrence(%{reference: reference})}
    end
  end

  @doc """
  Streams occurrences strictly after `reference`, in order.

  Lazy: a rule with no `COUNT` or `UNTIL` produces an unbounded stream, so take
  what you need.
  """
  @spec stream(Rule.t(), DateTime.t()) :: Enumerable.t()
  def stream(%Rule{} = rule, %DateTime{} = reference) do
    rule
    |> periods(reference)
    |> Stream.flat_map(&candidates(rule, &1, reference))
    |> Stream.filter(&(DateTime.compare(&1, reference) == :gt))
    |> limit_by_until(rule)
    |> limit_by_count(rule)
  end

  ##
  ## Private Functions
  ##

  # Period generation

  # Streams the start of each period the rule could fire in, honouring INTERVAL.
  @spec periods(Rule.t(), DateTime.t()) :: Enumerable.t()
  defp periods(rule, reference) do
    start = period_start(rule, reference)

    Stream.unfold({start, 0}, fn
      {_current, count} when count >= @period_limit -> nil
      {current, count} -> {current, {advance(rule, current), count + 1}}
    end)
  end

  # Truncates the reference to the beginning of the period containing it.
  @spec period_start(Rule.t(), DateTime.t()) :: DateTime.t()
  defp period_start(%Rule{frequency: :yearly}, reference),
    do: %{reference | month: 1, day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

  defp period_start(%Rule{frequency: :monthly}, reference),
    do: %{reference | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

  defp period_start(%Rule{frequency: :weekly} = rule, reference) do
    day = %{reference | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    offset = Integer.mod(Date.day_of_week(day) - Rule.day_number(rule.week_start), 7)
    DateTime.add(day, -offset, :day)
  end

  defp period_start(%Rule{frequency: :daily}, reference),
    do: %{reference | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

  defp period_start(%Rule{frequency: :hourly}, reference),
    do: %{reference | minute: 0, second: 0, microsecond: {0, 0}}

  defp period_start(%Rule{frequency: :minutely}, reference),
    do: %{reference | second: 0, microsecond: {0, 0}}

  defp period_start(%Rule{frequency: :secondly}, reference),
    do: %{reference | microsecond: {0, 0}}

  # Moves to the start of the next period the interval selects.
  @spec advance(Rule.t(), DateTime.t()) :: DateTime.t()
  defp advance(%Rule{frequency: :yearly, interval: interval}, current),
    do: shift_months(current, 12 * interval)

  defp advance(%Rule{frequency: :monthly, interval: interval}, current),
    do: shift_months(current, interval)

  defp advance(%Rule{frequency: :weekly, interval: interval}, current),
    do: DateTime.add(current, 7 * interval, :day)

  defp advance(%Rule{frequency: :daily, interval: interval}, current),
    do: DateTime.add(current, interval, :day)

  defp advance(%Rule{frequency: :hourly, interval: interval}, current),
    do: DateTime.add(current, interval, :hour)

  defp advance(%Rule{frequency: :minutely, interval: interval}, current),
    do: DateTime.add(current, interval, :minute)

  defp advance(%Rule{frequency: :secondly, interval: interval}, current),
    do: DateTime.add(current, interval, :second)

  # Adds whole months, clamping to the last valid day so the period start stays
  # real. Period starts are always day 1, so this never actually clamps -- it is
  # here so the function is total rather than partial.
  @spec shift_months(DateTime.t(), integer()) :: DateTime.t()
  defp shift_months(datetime, months) do
    total = datetime.year * 12 + (datetime.month - 1) + months
    year = div(total, 12)
    month = rem(total, 12) + 1
    day = min(datetime.day, Date.days_in_month(%Date{year: year, month: month, day: 1}))
    %{datetime | year: year, month: month, day: day}
  end

  # Candidate construction

  # Builds every instant the rule could fire at within one period, in order.
  @spec candidates(Rule.t(), DateTime.t(), DateTime.t()) :: [DateTime.t()]
  defp candidates(rule, period_start, reference) do
    rule
    |> dates(period_start)
    |> Enum.flat_map(&times(rule, &1, period_start, reference))
    |> Enum.sort(DateTime)
    |> apply_set_position(rule)
  end

  # The dates within a period that survive the rule's date-level parts.
  @spec dates(Rule.t(), DateTime.t()) :: [Date.t()]
  defp dates(rule, period_start) do
    period_start
    |> period_dates(rule)
    |> Enum.filter(&matches_date?(rule, &1))
  end

  # Every date the period spans, before filtering.
  @spec period_dates(DateTime.t(), Rule.t()) :: [Date.t()]
  defp period_dates(period_start, %Rule{frequency: frequency}) do
    date = DateTime.to_date(period_start)

    case frequency do
      :yearly -> Date.range(date, %{date | month: 12, day: 31}) |> Enum.to_list()
      :monthly -> Date.range(date, %{date | day: Date.days_in_month(date)}) |> Enum.to_list()
      :weekly -> Date.range(date, Date.add(date, 6)) |> Enum.to_list()
      _shorter -> [date]
    end
  end

  # Applies every date-level restriction the rule carries.
  @spec matches_date?(Rule.t(), Date.t()) :: boolean()
  defp matches_date?(rule, date) do
    matches_month?(rule, date) and matches_month_day?(rule, date) and
      matches_year_day?(rule, date) and matches_week_number?(rule, date) and
      matches_day?(rule, date)
  end

  @spec matches_month?(Rule.t(), Date.t()) :: boolean()
  defp matches_month?(%Rule{by_month: []}, _date), do: true
  defp matches_month?(%Rule{by_month: months}, date), do: date.month in months

  # A negative day counts back from the end of the month, so -1 is the last day.
  @spec matches_month_day?(Rule.t(), Date.t()) :: boolean()
  defp matches_month_day?(%Rule{by_month_day: []}, _date), do: true

  defp matches_month_day?(%Rule{by_month_day: days}, date) do
    in_month = Date.days_in_month(date)
    Enum.any?(days, fn day -> day == date.day or day == date.day - in_month - 1 end)
  end

  @spec matches_year_day?(Rule.t(), Date.t()) :: boolean()
  defp matches_year_day?(%Rule{by_year_day: []}, _date), do: true

  defp matches_year_day?(%Rule{by_year_day: days}, date) do
    ordinal = Date.day_of_year(date)
    in_year = if Date.leap_year?(date), do: 366, else: 365
    Enum.any?(days, fn day -> day == ordinal or day == ordinal - in_year - 1 end)
  end

  @spec matches_week_number?(Rule.t(), Date.t()) :: boolean()
  defp matches_week_number?(%Rule{by_week_number: []}, _date), do: true

  defp matches_week_number?(%Rule{by_week_number: numbers}, date) do
    {_year, week} = :calendar.iso_week_number(Date.to_erl(date))
    Enum.any?(numbers, fn number -> number == week or number == week - 53 - 1 end)
  end

  # `BYDAY` entries may carry an ordinal, which counts occurrences of that
  # weekday within the period rather than within the whole calendar.
  @spec matches_day?(Rule.t(), Date.t()) :: boolean()
  defp matches_day?(%Rule{by_day: []}, _date), do: true

  defp matches_day?(%Rule{by_day: specs} = rule, date) do
    Enum.any?(specs, fn
      weekday when is_atom(weekday) -> Date.day_of_week(date) == Rule.day_number(weekday)
      {ordinal, weekday} -> ordinal_matches?(rule, date, ordinal, weekday)
    end)
  end

  @spec ordinal_matches?(Rule.t(), Date.t(), integer(), Rule.weekday()) :: boolean()
  defp ordinal_matches?(rule, date, ordinal, weekday) do
    if Date.day_of_week(date) == Rule.day_number(weekday) do
      {first, last} = ordinal_bounds(rule, date)

      same =
        first
        |> Date.range(last)
        |> Enum.filter(&(Date.day_of_week(&1) == Date.day_of_week(date)))

      index = Enum.find_index(same, &(&1 == date))
      positive = index + 1
      negative = positive - length(same) - 1
      ordinal == positive or ordinal == negative
    else
      false
    end
  end

  # An ordinal counts within the year for `FREQ=YEARLY` and within the month
  # otherwise, which is what makes `BYDAY=-1SU` mean different things under each.
  @spec ordinal_bounds(Rule.t(), Date.t()) :: {Date.t(), Date.t()}
  defp ordinal_bounds(%Rule{frequency: :yearly, by_month: []}, date),
    do: {%{date | month: 1, day: 1}, %{date | month: 12, day: 31}}

  defp ordinal_bounds(_rule, date),
    do: {%{date | day: 1}, %{date | day: Date.days_in_month(date)}}

  # Time construction

  # The times of day a date should produce.
  #
  # Where a `BY*` part names the values, those are used. Otherwise the value
  # comes from whichever source actually varies it: for a frequency shorter than
  # a day the period itself already steps that part, so it comes from the period
  # start; for daily and longer the rule says nothing about time of day, so it
  # comes from the reference.
  @spec times(Rule.t(), Date.t(), DateTime.t(), DateTime.t()) :: [DateTime.t()]
  defp times(rule, date, period_start, reference) do
    source = time_source(rule, period_start, reference)
    hours = defaulted(rule.by_hour, source.hour)
    minutes = defaulted(rule.by_minute, source.minute)
    seconds = defaulted(rule.by_second, source.second)

    for hour <- hours, minute <- minutes, second <- seconds, reduce: [] do
      acc ->
        time = %Time{hour: hour, minute: minute, second: second, microsecond: {0, 0}}

        case DateTime.new(date, time, reference.time_zone) do
          {:ok, datetime} -> [datetime | acc]
          _skipped -> acc
        end
    end
  end

  # Sub-daily frequencies step the clock themselves, so the period start holds
  # the time. Daily and longer step whole days, leaving the reference to supply
  # the time of day the way `DTSTART` would in a calendar event.
  @spec time_source(Rule.t(), DateTime.t(), DateTime.t()) :: DateTime.t()
  defp time_source(%Rule{frequency: frequency}, period_start, _reference)
       when frequency in [:secondly, :minutely, :hourly],
       do: period_start

  defp time_source(_rule, _period_start, reference), do: reference

  @spec defaulted([integer()], integer()) :: [integer()]
  defp defaulted([], fallback), do: [fallback]
  defp defaulted(values, _fallback), do: Enum.sort(values)

  # Selection and bounds

  # `BYSETPOS` keeps only the numbered candidates of the period, counting from
  # either end.
  @spec apply_set_position([DateTime.t()], Rule.t()) :: [DateTime.t()]
  defp apply_set_position(candidates, %Rule{by_set_position: []}), do: candidates

  defp apply_set_position(candidates, %Rule{by_set_position: positions}) do
    total = length(candidates)

    positions
    |> Enum.map(fn position -> if position > 0, do: position - 1, else: total + position end)
    |> Enum.filter(&(&1 >= 0 and &1 < total))
    |> Enum.sort()
    |> Enum.map(&Enum.at(candidates, &1))
  end

  @spec limit_by_until(Enumerable.t(), Rule.t()) :: Enumerable.t()
  defp limit_by_until(stream, %Rule{until: nil}), do: stream

  defp limit_by_until(stream, %Rule{until: until}),
    do: Stream.take_while(stream, &(DateTime.compare(&1, until) != :gt))

  @spec limit_by_count(Enumerable.t(), Rule.t()) :: Enumerable.t()
  defp limit_by_count(stream, %Rule{count: nil}), do: stream
  defp limit_by_count(stream, %Rule{count: count}), do: Stream.take(stream, count)
end
