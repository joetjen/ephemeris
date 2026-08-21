defmodule EphemerisTest do
  use ExUnit.Case, async: true

  doctest Ephemeris

  describe "parse/1" do
    test "reads either syntax into the same rule" do
      assert {:ok, from_rrule} = Ephemeris.parse("FREQ=MONTHLY;BYDAY=-1SU")
      assert {:ok, from_english} = Ephemeris.parse("every last Sunday of the month")
      assert from_rrule == from_english
    end

    test "raises through parse!/1 rather than returning an error" do
      assert_raise Ephemeris.Error, fn -> Ephemeris.parse!("every blursday") end
    end
  end

  describe "rendering both ways" do
    test "a rule survives a full round trip through either syntax" do
      original = "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"
      assert {:ok, rule} = Ephemeris.parse(original)

      assert Ephemeris.to_rrule(rule) == original
      assert {:ok, reparsed} = rule |> Ephemeris.to_sentence() |> Ephemeris.parse()
      assert reparsed == rule
    end
  end

  describe "next/2" do
    test "computes occurrences from a rule written in English" do
      assert {:ok, rule} = Ephemeris.parse("every 3rd Monday of the month")
      assert {:ok, ~U[2026-01-19 09:00:00Z]} = Ephemeris.next(rule, ~U[2026-01-01 09:00:00Z])
    end
  end
end
