defmodule Ephemeris.Rule do
  @moduledoc """
  One recurrence rule, held in the structure both representations share.

  A rule says *when* something recurs and nothing else: it carries no start
  instant, no process, no callback and no notion of the current time. Every
  calculation takes an explicit reference `DateTime`, which is what makes a rule
  a value you can compare, store and render rather than a live thing.

  The field names follow RFC 5545 §3.3.10, because that is the standard both
  representations describe. `Ephemeris.parse/1` builds one from either syntax,
  and `Ephemeris.to_rrule/1` and `Ephemeris.to_sentence/1` render it back.

  ## Fields

  | Field | RRULE part | Meaning |
  | --- | --- | --- |
  | `:frequency` | `FREQ` | The base period the rule repeats over |
  | `:interval` | `INTERVAL` | How many of those periods between occurrences |
  | `:count` | `COUNT` | Stop after this many occurrences |
  | `:until` | `UNTIL` | Stop at this instant, inclusive |
  | `:week_start` | `WKST` | Which weekday a week begins on, affecting weekly intervals |
  | `:by_second` | `BYSECOND` | Seconds within the minute |
  | `:by_minute` | `BYMINUTE` | Minutes within the hour |
  | `:by_hour` | `BYHOUR` | Hours within the day |
  | `:by_day` | `BYDAY` | Weekdays, optionally with an ordinal such as `{-1, :sunday}` |
  | `:by_month_day` | `BYMONTHDAY` | Days of the month, negative counting from the end |
  | `:by_year_day` | `BYYEARDAY` | Days of the year, negative counting from the end |
  | `:by_week_number` | `BYWEEKNO` | ISO week numbers |
  | `:by_month` | `BYMONTH` | Months of the year |
  | `:by_set_position` | `BYSETPOS` | Which of a period's candidate occurrences to keep |

  `:count` and `:until` are mutually exclusive, as the standard requires.
  """

  @typedoc "The base period a rule repeats over."
  @type frequency :: :secondly | :minutely | :hourly | :daily | :weekly | :monthly | :yearly

  @typedoc "A weekday, spelled out rather than numbered."
  @type weekday :: :monday | :tuesday | :wednesday | :thursday | :friday | :saturday | :sunday

  @typedoc """
  A weekday, optionally restricted to one occurrence within the period.

  `{-1, :sunday}` is the last Sunday, `{3, :monday}` the third Monday. A bare
  weekday means every one of them.
  """
  @type day_spec :: weekday() | {integer(), weekday()}

  @typedoc "A recurrence rule."
  @type t :: %__MODULE__{
          frequency: frequency(),
          interval: pos_integer(),
          count: pos_integer() | nil,
          until: DateTime.t() | nil,
          week_start: weekday(),
          by_second: [0..60],
          by_minute: [0..59],
          by_hour: [0..23],
          by_day: [day_spec()],
          by_month_day: [integer()],
          by_year_day: [integer()],
          by_week_number: [integer()],
          by_month: [1..12],
          by_set_position: [integer()]
        }

  @enforce_keys [:frequency]
  defstruct frequency: nil,
            interval: 1,
            count: nil,
            until: nil,
            week_start: :monday,
            by_second: [],
            by_minute: [],
            by_hour: [],
            by_day: [],
            by_month_day: [],
            by_year_day: [],
            by_week_number: [],
            by_month: [],
            by_set_position: []

  @frequencies [:secondly, :minutely, :hourly, :daily, :weekly, :monthly, :yearly]
  @weekdays [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]

  @doc "Returns every supported frequency, in ascending period order."
  @spec frequencies() :: [frequency()]
  def frequencies, do: @frequencies

  @doc "Returns every weekday, Monday first."
  @spec weekdays() :: [weekday()]
  def weekdays, do: @weekdays

  @doc """
  Returns the ISO day number for a weekday, Monday being 1.

  ## Examples

      iex> Ephemeris.Rule.day_number(:monday)
      1

      iex> Ephemeris.Rule.day_number(:sunday)
      7
  """
  @spec day_number(weekday()) :: 1..7
  for {day, number} <- Enum.with_index(@weekdays, 1) do
    def day_number(unquote(day)), do: unquote(number)
  end

  @doc """
  Returns the weekday for an ISO day number.

  ## Examples

      iex> Ephemeris.Rule.weekday(1)
      :monday
  """
  @spec weekday(1..7) :: weekday()
  for {day, number} <- Enum.with_index(@weekdays, 1) do
    def weekday(unquote(number)), do: unquote(day)
  end
end
