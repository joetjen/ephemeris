defmodule Ephemeris.Error do
  @moduledoc """
  The stable, typed failures Ephemeris returns.

  Every failure carries a machine-readable `:code`, a fixed human-readable
  `:message`, and `:details` describing the specific occurrence. Match on the
  code; the message is for people.
  """

  @typedoc "An error owned by Ephemeris."
  @type t :: %__MODULE__{code: atom(), message: String.t(), details: term()}

  defexception [:code, :message, details: %{}]

  @messages [
    conflicting_parts: "Rule parts contradict each other",
    invalid_expression: "Recurrence expression is malformed",
    invalid_frequency: "Recurrence frequency is not one of the supported values",
    invalid_part: "Rule part has an invalid value",
    missing_frequency: "Recurrence rule has no frequency",
    no_occurrence: "Rule has no occurrence after the given reference",
    unknown_part: "Rule part is not recognised",
    unsupported_expression: "Expression is not one this parser understands"
  ]

  for {code, message} <- @messages do
    @doc "Builds the `#{inspect(code)}` error: #{message}."
    @spec unquote(code)(term()) :: t()
    def unquote(code)(details \\ %{}),
      do: %__MODULE__{code: unquote(code), message: unquote(message), details: details}
  end

  @doc "Returns every code this module defines."
  @spec codes() :: [atom()]
  def codes, do: unquote(Keyword.keys(@messages))

  @impl true
  @spec exception(keyword()) :: t()
  def exception(options) when is_list(options) do
    %__MODULE__{
      code: Keyword.get(options, :code, :invalid_expression),
      message: Keyword.get(options, :message, "Recurrence expression is malformed"),
      details: Keyword.get(options, :details, %{})
    }
  end

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{message: message}), do: message
end
