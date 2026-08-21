defmodule Ephemeris do
  @moduledoc """
  Recurrence rules that read and write both RFC 5545 `RRULE` and plain English.

  An *ephemeris* is a table of recurring positions over time. This one holds
  recurrence rules: parse them from either syntax into one structure, compute
  occurrences from it, and render it back out in either syntax.

      iex> {:ok, rule} = Ephemeris.parse("every last Sunday of the month")
      iex> Ephemeris.to_rrule(rule)
      "FREQ=MONTHLY;BYDAY=-1SU"

      iex> {:ok, rule} = Ephemeris.parse("FREQ=MONTHLY;BYDAY=-1SU")
      iex> Ephemeris.to_sentence(rule)
      "every last Sunday of the month"

      iex> {:ok, rule} = Ephemeris.parse("every 3rd Monday of the month")
      iex> Ephemeris.next(rule, ~U[2026-01-01 09:00:00Z])
      {:ok, ~U[2026-01-19 09:00:00Z]}

  ## Why both syntaxes

  `RRULE` is the standard: portable, precise, and what a calendar application
  speaks. It is also unreadable in a configuration file. Plain English is the
  opposite on both counts. Holding one structure and rendering either means a
  rule can be written the readable way, stored the portable way, and shown back
  either way, without two implementations that can disagree.

  ## What a rule is not

  A rule says *when* something recurs and nothing else. It holds no process, no
  callback, no timer and no notion of the current time — every calculation takes
  an explicit reference `DateTime`. Scheduling belongs to whatever uses this.
  """

  alias Ephemeris.Error
  alias Ephemeris.Occurrence
  alias Ephemeris.RRule
  alias Ephemeris.Rule
  alias Ephemeris.Sentence

  ##
  ## Public API
  ##

  @doc """
  Parses either syntax into a rule.

  An expression containing `=` is read as `RRULE`, anything else as English.
  That is unambiguous rather than a guess: `RRULE` is always `KEY=VALUE` pairs
  and an English sentence never contains `=`.

  ## Examples

      iex> {:ok, rule} = Ephemeris.parse("FREQ=WEEKLY;BYDAY=MO")
      iex> rule.frequency
      :weekly

      iex> {:ok, rule} = Ephemeris.parse("every Monday")
      iex> rule.frequency
      :weekly
  """
  @spec parse(String.t()) :: {:ok, Rule.t()} | {:error, Error.t()}
  def parse(expression) when is_binary(expression) do
    if String.contains?(expression, "="),
      do: RRule.parse(expression),
      else: Sentence.parse(expression)
  end

  def parse(_expression), do: {:error, Error.invalid_expression(%{expected: :string})}

  @doc "Parses either syntax, raising `Ephemeris.Error` when it cannot."
  @spec parse!(String.t()) :: Rule.t()
  def parse!(expression) do
    case parse(expression) do
      {:ok, rule} -> rule
      {:error, error} -> raise error
    end
  end

  @doc "Renders a rule as RFC 5545 `RRULE` text."
  @spec to_rrule(Rule.t()) :: String.t()
  defdelegate to_rrule(rule), to: RRule, as: :render

  @doc "Renders a rule as an English sentence."
  @spec to_sentence(Rule.t()) :: String.t()
  defdelegate to_sentence(rule), to: Sentence, as: :render

  @doc """
  Returns the first occurrence strictly after `reference`.

  Strictly after, so feeding an occurrence back in yields the following one.
  """
  @spec next(Rule.t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, Error.t()}
  defdelegate next(rule, reference), to: Occurrence

  @doc """
  Streams occurrences strictly after `reference`, in order.

  Lazy: a rule with no `COUNT` or `UNTIL` is unbounded, so take what you need.
  """
  @spec stream(Rule.t(), DateTime.t()) :: Enumerable.t()
  defdelegate stream(rule, reference), to: Occurrence
end
