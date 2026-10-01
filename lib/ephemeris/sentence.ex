defmodule Ephemeris.Sentence do
  @moduledoc """
  Reads and writes recurrence rules as plain English.

  The same rules `RRULE` expresses, in a form a person can read in a
  configuration file:

      every 30 seconds
      every 2 weeks on Monday and Wednesday
      every last Sunday of the month
      every 3rd Monday of the month at 9:30 am
      every last weekday of the month
      every 29 February

  ## What it accepts

  A sentence is `every` followed by *what recurs*, optionally narrowed by a
  time:

  | Shape | Example | Becomes |
  | --- | --- | --- |
  | interval and unit | `every 2 weeks` | `FREQ=WEEKLY;INTERVAL=2` |
  | weekdays | `every Monday and Friday` | `FREQ=WEEKLY;BYDAY=MO,FR` |
  | ordinal weekday of a period | `every last Sunday of the month` | `FREQ=MONTHLY;BYDAY=-1SU` |
  | ordinal weekday set | `every last weekday of the month` | `FREQ=MONTHLY;BYDAY=MO,…,FR;BYSETPOS=-1` |
  | day of the month | `every 1st of the month` | `FREQ=MONTHLY;BYMONTHDAY=1` |
  | date in the year | `every 29 February` | `FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29` |
  | time of day | `… at 9:30 am` | `BYHOUR=9;BYMINUTE=30` |

  Case and the words `on`, `of`, `the` and `and` are ignored where they read
  naturally, so `every last sunday of the month` and
  `Every Last Sunday Of The Month` are the same sentence.

  ## What it refuses

  Anything it does not recognise, rather than guessing. A sentence that parses
  into *almost* the right rule is worse than one that fails to parse: the
  failure is visible, the near-miss fires at the wrong time.
  """

  alias Ephemeris.Error
  alias Ephemeris.Rule

  @units %{
    "second" => :secondly,
    "seconds" => :secondly,
    "minute" => :minutely,
    "minutes" => :minutely,
    "hour" => :hourly,
    "hours" => :hourly,
    "day" => :daily,
    "days" => :daily,
    "week" => :weekly,
    "weeks" => :weekly,
    "month" => :monthly,
    "months" => :monthly,
    "year" => :yearly,
    "years" => :yearly
  }

  @weekdays %{
    "monday" => :monday,
    "tuesday" => :tuesday,
    "wednesday" => :wednesday,
    "thursday" => :thursday,
    "friday" => :friday,
    "saturday" => :saturday,
    "sunday" => :sunday
  }

  @months %{
    "january" => 1,
    "february" => 2,
    "march" => 3,
    "april" => 4,
    "may" => 5,
    "june" => 6,
    "july" => 7,
    "august" => 8,
    "september" => 9,
    "october" => 10,
    "november" => 11,
    "december" => 12
  }

  @ordinals %{
    "first" => 1,
    "second" => 2,
    "third" => 3,
    "fourth" => 4,
    "fifth" => 5,
    "last" => -1
  }

  @weekday_set [:monday, :tuesday, :wednesday, :thursday, :friday]
  @month_names Map.new(@months, fn {name, number} -> {number, String.capitalize(name)} end)
  @unit_names %{
    secondly: {"second", "seconds"},
    minutely: {"minute", "minutes"},
    hourly: {"hour", "hours"},
    daily: {"day", "days"},
    weekly: {"week", "weeks"},
    monthly: {"month", "months"},
    yearly: {"year", "years"}
  }

  # Noise words that carry no meaning where they appear, so a sentence can read
  # naturally without the parser needing a grammar rule for each.
  @ignored ~w(on of the and at)

  ##
  ## Public API
  ##

  @doc """
  Parses an English sentence into a rule.

  ## Examples

      iex> {:ok, rule} = Ephemeris.Sentence.parse("every 2 weeks on Monday")
      iex> {rule.frequency, rule.interval, rule.by_day}
      {:weekly, 2, [:monday]}

      iex> {:ok, rule} = Ephemeris.Sentence.parse("every last Sunday of the month")
      iex> rule.by_day
      [{-1, :sunday}]

      iex> {:error, error} = Ephemeris.Sentence.parse("sometimes, whenever")
      iex> error.code
      :unsupported_expression
  """
  @spec parse(String.t()) :: {:ok, Rule.t()} | {:error, Error.t()}
  def parse(sentence) when is_binary(sentence) do
    with {:ok, words} <- words(sentence),
         {:ok, {body, time}} <- split_time(words),
         {:ok, rule} <- interpret(body) do
      {:ok, apply_time(rule, time)}
    end
  end

  def parse(_sentence), do: {:error, Error.invalid_expression(%{expected: :string})}

  @doc """
  Renders a rule as an English sentence.

  The result parses back to the same rule, so a rule can be shown to a person
  and read back without loss.

  ## Examples

      iex> {:ok, rule} = Ephemeris.RRule.parse("FREQ=MONTHLY;BYDAY=-1SU")
      iex> Ephemeris.Sentence.render(rule)
      "every last Sunday of the month"
  """
  @spec render(Rule.t()) :: String.t()
  def render(%Rule{} = rule) do
    ["every", subject(rule), time_phrase(rule)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  ##
  ## Private Functions
  ##

  # Tokenising

  # Splits into comparable words, dropping punctuation but keeping digits and
  # colons so times and ordinals survive.
  @spec words(String.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  defp words(sentence) do
    case sentence |> String.downcase() |> String.replace(~r/[,\.]/, " ") |> String.split() do
      ["every" | rest] when rest != [] -> {:ok, rest}
      _other -> {:error, Error.unsupported_expression(%{sentence: sentence})}
    end
  end

  # Separates a trailing time phrase from the subject it qualifies.
  @spec split_time([String.t()]) :: {:ok, {[String.t()], [String.t()]}} | {:error, Error.t()}
  defp split_time(words) do
    case Enum.split_while(words, &(&1 != "at")) do
      {body, []} -> {:ok, {body, []}}
      {body, ["at" | time]} when time != [] -> {:ok, {body, time}}
      _dangling -> {:error, Error.unsupported_expression(%{reason: :incomplete_time})}
    end
  end

  # Interpretation

  # Reads the subject of the sentence -- what recurs, before any time of day.
  @spec interpret([String.t()]) :: {:ok, Rule.t()} | {:error, Error.t()}
  defp interpret(words) do
    meaningful = Enum.reject(words, &(&1 in @ignored))

    cond do
      rule = interval_unit(meaningful) -> {:ok, rule}
      rule = interval_unit_days(meaningful) -> {:ok, rule}
      rule = ordinal_weekday(meaningful) -> {:ok, rule}
      rule = ordinal_weekday_set(meaningful) -> {:ok, rule}
      rule = month_day(meaningful) -> {:ok, rule}
      rule = calendar_date(meaningful) -> {:ok, rule}
      rule = weekdays(meaningful) -> {:ok, rule}
      true -> {:error, Error.unsupported_expression(%{words: Enum.join(words, " ")})}
    end
  end

  # `every 30 seconds`, `every 2 weeks`, `every hour`.
  @spec interval_unit([String.t()]) :: Rule.t() | nil
  defp interval_unit([unit]), do: with_unit(unit, 1)

  defp interval_unit([count, unit]) do
    case Integer.parse(count) do
      {number, ""} when number > 0 -> with_unit(unit, number)
      _other -> nil
    end
  end

  defp interval_unit(_words), do: nil

  @spec with_unit(String.t(), pos_integer()) :: Rule.t() | nil
  defp with_unit(unit, interval) do
    case Map.fetch(@units, unit) do
      {:ok, frequency} -> %Rule{frequency: frequency, interval: interval}
      :error -> nil
    end
  end

  # `every 2 weeks on Monday and Friday` -- an interval narrowed to weekdays.
  @spec interval_unit_days([String.t()]) :: Rule.t() | nil
  defp interval_unit_days([count, unit | rest]) when rest != [] do
    with {number, ""} <- Integer.parse(count),
         true <- number > 0,
         %Rule{} = base <- with_unit(unit, number),
         %Rule{by_day: days} <- weekdays(rest) do
      %{base | by_day: days}
    else
      _other -> nil
    end
  end

  defp interval_unit_days(_words), do: nil

  # `every last Sunday of the month`, `every 3rd Monday of the year`.
  @spec ordinal_weekday([String.t()]) :: Rule.t() | nil
  defp ordinal_weekday([ordinal, weekday, period]) do
    with {:ok, number} <- fetch_ordinal(ordinal),
         {:ok, day} <- Map.fetch(@weekdays, weekday),
         {:ok, frequency} <- period_frequency(period) do
      %Rule{frequency: frequency, by_day: [{number, day}]}
    else
      _other -> nil
    end
  end

  defp ordinal_weekday(_words), do: nil

  # `every last weekday of the month` -- a set narrowed by position, which is
  # what `BYSETPOS` exists for.
  @spec ordinal_weekday_set([String.t()]) :: Rule.t() | nil
  defp ordinal_weekday_set([ordinal, "weekday", period]) do
    with {:ok, number} <- fetch_ordinal(ordinal),
         {:ok, frequency} <- period_frequency(period) do
      %Rule{frequency: frequency, by_day: @weekday_set, by_set_position: [number]}
    else
      _other -> nil
    end
  end

  defp ordinal_weekday_set(_words), do: nil

  # `every 1st of the month`.
  @spec month_day([String.t()]) :: Rule.t() | nil
  defp month_day([day, "month"]) do
    case day_number(day) do
      {:ok, number} -> %Rule{frequency: :monthly, by_month_day: [number]}
      :error -> nil
    end
  end

  defp month_day(_words), do: nil

  # `every 29 February`, `every February 29`.
  @spec calendar_date([String.t()]) :: Rule.t() | nil
  defp calendar_date([day, month]) do
    with {:ok, number} <- day_number(day), {:ok, index} <- Map.fetch(@months, month) do
      %Rule{frequency: :yearly, by_month: [index], by_month_day: [number]}
    else
      _other -> nil
    end
  end

  defp calendar_date(_words), do: nil

  # `every Monday`, `every Monday and Friday`, `every weekday`.
  @spec weekdays([String.t()]) :: Rule.t() | nil
  defp weekdays(["weekday"]), do: %Rule{frequency: :weekly, by_day: @weekday_set}

  defp weekdays(words) do
    days = Enum.map(words, &Map.get(@weekdays, &1))

    if words != [] and Enum.all?(days, &(&1 != nil)),
      do: %Rule{frequency: :weekly, by_day: days},
      else: nil
  end

  # Shared readers

  @spec fetch_ordinal(String.t()) :: {:ok, integer()} | :error
  defp fetch_ordinal(word) do
    case Map.fetch(@ordinals, word) do
      {:ok, number} -> {:ok, number}
      :error -> numeric_ordinal(word)
    end
  end

  # `1st`, `2nd`, `23rd` -- the suffix is not checked for agreement, since
  # `1th` is a typo rather than a different meaning.
  @spec numeric_ordinal(String.t()) :: {:ok, pos_integer()} | :error
  defp numeric_ordinal(word) do
    case Regex.run(~r/^(\d+)(st|nd|rd|th)$/, word) do
      [_all, digits, _suffix] -> {:ok, String.to_integer(digits)}
      _no_match -> :error
    end
  end

  @spec day_number(String.t()) :: {:ok, integer()} | :error
  defp day_number(word) do
    case numeric_ordinal(word) do
      {:ok, number} -> {:ok, number}
      :error -> plain_day(word)
    end
  end

  @spec plain_day(String.t()) :: {:ok, integer()} | :error
  defp plain_day(word) do
    case Integer.parse(word) do
      {number, ""} when number != 0 and abs(number) <= 31 -> {:ok, number}
      _other -> :error
    end
  end

  @spec period_frequency(String.t()) :: {:ok, Rule.frequency()} | :error
  defp period_frequency("month"), do: {:ok, :monthly}
  defp period_frequency("year"), do: {:ok, :yearly}
  defp period_frequency(_word), do: :error

  # Time of day

  # Applies a parsed time phrase, leaving the rule untouched when there is none.
  @spec apply_time(Rule.t(), [String.t()]) :: Rule.t()
  defp apply_time(rule, []), do: rule

  defp apply_time(rule, words) do
    case clock(words) do
      {:ok, {hour, minute}} -> %{rule | by_hour: [hour], by_minute: [minute], by_second: [0]}
      :error -> rule
    end
  end

  @spec clock([String.t()]) :: {:ok, {0..23, 0..59}} | :error
  defp clock(["midnight"]), do: {:ok, {0, 0}}
  defp clock(["noon"]), do: {:ok, {12, 0}}
  defp clock([time]), do: parse_clock(time, nil)
  defp clock([time, meridiem]) when meridiem in ["am", "pm"], do: parse_clock(time, meridiem)
  defp clock(_words), do: :error

  @spec parse_clock(String.t(), String.t() | nil) :: {:ok, {0..23, 0..59}} | :error
  defp parse_clock(text, meridiem) do
    parts = String.split(text, ":", parts: 2)

    with [hour_text | rest] <- parts,
         {hour, ""} <- Integer.parse(hour_text),
         {:ok, minute} <- clock_minute(rest),
         {:ok, adjusted} <- meridiem_hour(hour, meridiem),
         true <- minute in 0..59 do
      {:ok, {adjusted, minute}}
    else
      _other -> :error
    end
  end

  @spec clock_minute([String.t()]) :: {:ok, integer()} | :error
  defp clock_minute([]), do: {:ok, 0}

  defp clock_minute([text]) do
    case Integer.parse(text) do
      {minute, ""} -> {:ok, minute}
      _other -> :error
    end
  end

  @spec meridiem_hour(integer(), String.t() | nil) :: {:ok, 0..23} | :error
  defp meridiem_hour(hour, nil) when hour in 0..23, do: {:ok, hour}
  defp meridiem_hour(12, "am"), do: {:ok, 0}
  defp meridiem_hour(12, "pm"), do: {:ok, 12}
  defp meridiem_hour(hour, "am") when hour in 1..11, do: {:ok, hour}
  defp meridiem_hour(hour, "pm") when hour in 1..11, do: {:ok, hour + 12}
  defp meridiem_hour(_hour, _meridiem), do: :error

  # Rendering

  # The part of the sentence describing what recurs.
  @spec subject(Rule.t()) :: String.t()
  defp subject(%Rule{by_set_position: [position], by_day: days} = rule)
       when days == @weekday_set,
       do: "#{ordinal_word(position)} weekday of the #{period_word(rule.frequency)}"

  defp subject(%Rule{by_day: [{ordinal, weekday}]} = rule),
    do: "#{ordinal_word(ordinal)} #{capitalised(weekday)} of the #{period_word(rule.frequency)}"

  defp subject(%Rule{frequency: :yearly, by_month: [month], by_month_day: [day]}),
    do: "#{day} #{Map.fetch!(@month_names, month)}"

  defp subject(%Rule{frequency: :monthly, by_month_day: [day]}),
    do: "#{ordinal_suffix(day)} of the month"

  defp subject(%Rule{by_day: days, interval: interval} = rule) when days != [] do
    named =
      if days == @weekday_set and rule.by_set_position == [],
        do: "weekday",
        else: days |> Enum.map(&capitalised/1) |> sentence_join()

    if interval == 1,
      do: named,
      else: "#{interval} #{elem(Map.fetch!(@unit_names, rule.frequency), 1)} on #{named}"
  end

  defp subject(%Rule{interval: 1} = rule), do: elem(Map.fetch!(@unit_names, rule.frequency), 0)

  defp subject(%Rule{interval: interval} = rule),
    do: "#{interval} #{elem(Map.fetch!(@unit_names, rule.frequency), 1)}"

  # The trailing `at …` clause, when the rule fixes a time of day.
  @spec time_phrase(Rule.t()) :: String.t() | nil
  defp time_phrase(%Rule{by_hour: [hour], by_minute: [minute]}),
    do: "at " <> clock_text(hour, minute)

  defp time_phrase(_rule), do: nil

  @spec clock_text(0..23, 0..59) :: String.t()
  defp clock_text(0, 0), do: "midnight"
  defp clock_text(12, 0), do: "noon"

  defp clock_text(hour, minute) do
    meridiem = if hour < 12, do: "am", else: "pm"

    shown =
      case rem(hour, 12) do
        0 -> 12
        other -> other
      end

    "#{shown}:#{String.pad_leading(Integer.to_string(minute), 2, "0")} #{meridiem}"
  end

  @spec ordinal_word(integer()) :: String.t()
  defp ordinal_word(-1), do: "last"
  defp ordinal_word(number) when number < 0, do: "#{ordinal_suffix(abs(number))} from last"
  defp ordinal_word(number), do: ordinal_suffix(number)

  @spec ordinal_suffix(integer()) :: String.t()
  defp ordinal_suffix(number) do
    suffix =
      cond do
        rem(number, 100) in 11..13 -> "th"
        rem(number, 10) == 1 -> "st"
        rem(number, 10) == 2 -> "nd"
        rem(number, 10) == 3 -> "rd"
        true -> "th"
      end

    "#{number}#{suffix}"
  end

  @spec period_word(Rule.frequency()) :: String.t()
  defp period_word(:yearly), do: "year"
  defp period_word(_frequency), do: "month"

  @spec capitalised(atom()) :: String.t()
  defp capitalised(atom), do: atom |> Atom.to_string() |> String.capitalize()

  @spec sentence_join([String.t()]) :: String.t()
  defp sentence_join([single]), do: single

  defp sentence_join(items),
    do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)
end
