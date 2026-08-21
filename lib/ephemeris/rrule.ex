defmodule Ephemeris.RRule do
  @moduledoc """
  Reads and writes RFC 5545 `RRULE` text.

  The syntax is flat: semicolon-separated `KEY=VALUE` pairs, values
  comma-separated where a part accepts several.

      FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;BYHOUR=9

  A leading `RRULE:` is accepted and ignored, so a line lifted straight out of
  an iCalendar file parses without editing.

  Parsing is strict: an unknown part, a malformed value or a part that
  contradicts another is an error rather than something quietly dropped. A rule
  that silently loses a constraint fires at the wrong time, which is worse than
  one that refuses to load.
  """

  alias Ephemeris.Error
  alias Ephemeris.Rule

  @frequencies %{
    "SECONDLY" => :secondly,
    "MINUTELY" => :minutely,
    "HOURLY" => :hourly,
    "DAILY" => :daily,
    "WEEKLY" => :weekly,
    "MONTHLY" => :monthly,
    "YEARLY" => :yearly
  }

  @weekdays %{
    "MO" => :monday,
    "TU" => :tuesday,
    "WE" => :wednesday,
    "TH" => :thursday,
    "FR" => :friday,
    "SA" => :saturday,
    "SU" => :sunday
  }

  @frequency_names Map.new(@frequencies, fn {text, atom} -> {atom, text} end)
  @weekday_names Map.new(@weekdays, fn {text, atom} -> {atom, text} end)

  ##
  ## Public API
  ##

  @doc """
  Parses an `RRULE` expression into a rule.

  ## Examples

      iex> {:ok, rule} = Ephemeris.RRule.parse("FREQ=WEEKLY;BYDAY=MO,WE")
      iex> {rule.frequency, rule.by_day}
      {:weekly, [:monday, :wednesday]}

      iex> {:ok, rule} = Ephemeris.RRule.parse("RRULE:FREQ=MONTHLY;BYDAY=-1SU")
      iex> rule.by_day
      [{-1, :sunday}]

      iex> {:error, error} = Ephemeris.RRule.parse("FREQ=FORTNIGHTLY")
      iex> {error.code, error.details}
      {:invalid_frequency, %{value: "FORTNIGHTLY"}}
  """
  @spec parse(String.t()) :: {:ok, Rule.t()} | {:error, Error.t()}
  def parse(expression) when is_binary(expression) do
    with {:ok, pairs} <- split_pairs(strip_prefix(expression)),
         {:ok, parts} <- parse_pairs(pairs),
         {:ok, rule} <- build(parts) do
      {:ok, rule}
    end
  end

  def parse(_expression), do: {:error, Error.invalid_expression(%{expected: :string})}

  @doc """
  Renders a rule as `RRULE` text.

  Parts appear in the order RFC 5545 lists them, so the same rule always
  produces the same string and two rules can be compared as text.

  ## Examples

      iex> {:ok, rule} = Ephemeris.RRule.parse("BYDAY=MO,WE;FREQ=WEEKLY;INTERVAL=2")
      iex> Ephemeris.RRule.render(rule)
      "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE"
  """
  @spec render(Rule.t()) :: String.t()
  def render(%Rule{} = rule) do
    [
      {"FREQ", Map.fetch!(@frequency_names, rule.frequency)},
      {"INTERVAL", if(rule.interval != 1, do: Integer.to_string(rule.interval))},
      {"COUNT", rule.count && Integer.to_string(rule.count)},
      {"UNTIL", rule.until && render_until(rule.until)},
      {"WKST", if(rule.week_start != :monday, do: Map.fetch!(@weekday_names, rule.week_start))},
      {"BYMONTH", numbers(rule.by_month)},
      {"BYWEEKNO", numbers(rule.by_week_number)},
      {"BYYEARDAY", numbers(rule.by_year_day)},
      {"BYMONTHDAY", numbers(rule.by_month_day)},
      {"BYDAY", days(rule.by_day)},
      {"BYHOUR", numbers(rule.by_hour)},
      {"BYMINUTE", numbers(rule.by_minute)},
      {"BYSECOND", numbers(rule.by_second)},
      {"BYSETPOS", numbers(rule.by_set_position)}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map_join(";", fn {key, value} -> key <> "=" <> value end)
  end

  ##
  ## Private Functions
  ##

  # Parsing

  # Accepts the `RRULE:` prefix an iCalendar line carries.
  @spec strip_prefix(String.t()) :: String.t()
  defp strip_prefix("RRULE:" <> rest), do: rest
  defp strip_prefix(expression), do: expression

  # Splits the flat `KEY=VALUE;KEY=VALUE` form, rejecting anything malformed.
  @spec split_pairs(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, Error.t()}
  defp split_pairs(expression) do
    expression
    |> String.split(";", trim: true)
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, acc} ->
      case String.split(segment, "=", parts: 2) do
        [key, value] when value != "" ->
          {:cont, {:ok, [{key |> String.trim() |> String.upcase(), String.trim(value)} | acc]}}

        _malformed ->
          {:halt, {:error, Error.invalid_expression(%{segment: segment})}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _error} = error -> error
    end
  end

  # Turns each recognised part into its structured value.
  @spec parse_pairs([{String.t(), String.t()}]) :: {:ok, keyword()} | {:error, Error.t()}
  defp parse_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case parse_pair(key, value) do
        {:ok, {field, parsed}} -> {:cont, {:ok, [{field, parsed} | acc]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  @spec parse_pair(String.t(), String.t()) :: {:ok, {atom(), term()}} | {:error, Error.t()}
  defp parse_pair("FREQ", value) do
    case Map.fetch(@frequencies, String.upcase(value)) do
      {:ok, frequency} -> {:ok, {:frequency, frequency}}
      :error -> {:error, Error.invalid_frequency(%{value: value})}
    end
  end

  defp parse_pair("INTERVAL", value), do: positive(:interval, value)
  defp parse_pair("COUNT", value), do: positive(:count, value)

  defp parse_pair("UNTIL", value) do
    case parse_until(value) do
      {:ok, datetime} -> {:ok, {:until, datetime}}
      :error -> {:error, Error.invalid_part(%{part: "UNTIL", value: value})}
    end
  end

  defp parse_pair("WKST", value) do
    case Map.fetch(@weekdays, String.upcase(value)) do
      {:ok, weekday} -> {:ok, {:week_start, weekday}}
      :error -> {:error, Error.invalid_part(%{part: "WKST", value: value})}
    end
  end

  defp parse_pair("BYSECOND", value), do: integer_list(:by_second, "BYSECOND", value, 0..60)
  defp parse_pair("BYMINUTE", value), do: integer_list(:by_minute, "BYMINUTE", value, 0..59)
  defp parse_pair("BYHOUR", value), do: integer_list(:by_hour, "BYHOUR", value, 0..23)
  defp parse_pair("BYMONTH", value), do: integer_list(:by_month, "BYMONTH", value, 1..12)

  defp parse_pair("BYMONTHDAY", value),
    do: signed_list(:by_month_day, "BYMONTHDAY", value, 1..31)

  defp parse_pair("BYYEARDAY", value), do: signed_list(:by_year_day, "BYYEARDAY", value, 1..366)
  defp parse_pair("BYWEEKNO", value), do: signed_list(:by_week_number, "BYWEEKNO", value, 1..53)
  defp parse_pair("BYSETPOS", value), do: signed_list(:by_set_position, "BYSETPOS", value, 1..366)

  defp parse_pair("BYDAY", value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case parse_day(String.trim(entry)) do
        {:ok, day} -> {:cont, {:ok, [day | acc]}}
        :error -> {:halt, {:error, Error.invalid_part(%{part: "BYDAY", value: entry})}}
      end
    end)
    |> case do
      {:ok, days} -> {:ok, {:by_day, Enum.reverse(days)}}
      {:error, _error} = error -> error
    end
  end

  defp parse_pair(key, _value), do: {:error, Error.unknown_part(%{part: key})}

  # `BYDAY` entries may carry an ordinal: `MO`, `3MO`, `-1SU`.
  @spec parse_day(String.t()) :: {:ok, Rule.day_spec()} | :error
  defp parse_day(entry) do
    case Regex.run(~r/^([+-]?\d+)?([A-Za-z]{2})$/, entry) do
      [_all, "", code] -> weekday_atom(code)
      [_all, code] when is_binary(code) -> weekday_atom(code)
      [_all, ordinal, code] -> ordinal_day(ordinal, code)
      _no_match -> :error
    end
  end

  @spec weekday_atom(String.t()) :: {:ok, Rule.weekday()} | :error
  defp weekday_atom(code) do
    case Map.fetch(@weekdays, String.upcase(code)) do
      {:ok, weekday} -> {:ok, weekday}
      :error -> :error
    end
  end

  @spec ordinal_day(String.t(), String.t()) :: {:ok, {integer(), Rule.weekday()}} | :error
  defp ordinal_day(ordinal, code) do
    with {:ok, weekday} <- weekday_atom(code),
         {number, ""} when number != 0 <- Integer.parse(ordinal) do
      {:ok, {number, weekday}}
    else
      _invalid -> :error
    end
  end

  # `UNTIL` is a UTC instant in basic ISO 8601, with or without the time part.
  @spec parse_until(String.t()) :: {:ok, DateTime.t()} | :error
  defp parse_until(<<y::binary-4, m::binary-2, d::binary-2, "T", rest::binary>>) do
    with <<h::binary-2, min::binary-2, s::binary-2, _zone::binary>> <- rest,
         {:ok, date} <- Date.from_iso8601(y <> "-" <> m <> "-" <> d),
         {:ok, time} <- Time.from_iso8601(h <> ":" <> min <> ":" <> s) do
      DateTime.new(date, time, "Etc/UTC")
    else
      _invalid -> :error
    end
  end

  defp parse_until(<<y::binary-4, m::binary-2, d::binary-2>>) do
    case Date.from_iso8601(y <> "-" <> m <> "-" <> d) do
      {:ok, date} -> DateTime.new(date, ~T[00:00:00], "Etc/UTC")
      _invalid -> :error
    end
  end

  defp parse_until(_value), do: :error

  # Validation

  @spec positive(atom(), String.t()) :: {:ok, {atom(), pos_integer()}} | {:error, Error.t()}
  defp positive(field, value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, {field, number}}
      _invalid -> {:error, Error.invalid_part(%{part: field, value: value})}
    end
  end

  @spec integer_list(atom(), String.t(), String.t(), Range.t()) ::
          {:ok, {atom(), [integer()]}} | {:error, Error.t()}
  defp integer_list(field, part, value, range),
    do: bounded_list(field, part, value, &(&1 in range))

  # Negative values count backwards from the end of the period, so both signs
  # are accepted and zero never is.
  @spec signed_list(atom(), String.t(), String.t(), Range.t()) ::
          {:ok, {atom(), [integer()]}} | {:error, Error.t()}
  defp signed_list(field, part, value, range),
    do: bounded_list(field, part, value, &(&1 != 0 and abs(&1) in range))

  @spec bounded_list(atom(), String.t(), String.t(), (integer() -> boolean())) ::
          {:ok, {atom(), [integer()]}} | {:error, Error.t()}
  defp bounded_list(field, part, value, valid?) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case Integer.parse(String.trim(entry)) do
        {number, ""} ->
          if valid?.(number),
            do: {:cont, {:ok, [number | acc]}},
            else: {:halt, {:error, Error.invalid_part(%{part: part, value: entry})}}

        _invalid ->
          {:halt, {:error, Error.invalid_part(%{part: part, value: entry})}}
      end
    end)
    |> case do
      {:ok, numbers} -> {:ok, {field, Enum.reverse(numbers)}}
      {:error, _error} = error -> error
    end
  end

  # Assembly

  # Builds the rule, enforcing the constraints the standard places across parts.
  @spec build(keyword()) :: {:ok, Rule.t()} | {:error, Error.t()}
  defp build(parts) do
    cond do
      not Keyword.has_key?(parts, :frequency) ->
        {:error, Error.missing_frequency(%{})}

      Keyword.has_key?(parts, :count) and Keyword.has_key?(parts, :until) ->
        {:error, Error.conflicting_parts(%{parts: ["COUNT", "UNTIL"]})}

      true ->
        {:ok, struct!(Rule, parts)}
    end
  end

  # Rendering

  @spec numbers([integer()]) :: String.t() | nil
  defp numbers([]), do: nil
  defp numbers(values), do: Enum.map_join(values, ",", &Integer.to_string/1)

  @spec days([Rule.day_spec()]) :: String.t() | nil
  defp days([]), do: nil
  defp days(values), do: Enum.map_join(values, ",", &day/1)

  @spec day(Rule.day_spec()) :: String.t()
  defp day({ordinal, weekday}),
    do: Integer.to_string(ordinal) <> Map.fetch!(@weekday_names, weekday)

  defp day(weekday), do: Map.fetch!(@weekday_names, weekday)

  @spec render_until(DateTime.t()) :: String.t()
  defp render_until(datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end
