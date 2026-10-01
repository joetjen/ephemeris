# Ephemeris

Recurrence rules that read and write both RFC 5545 `RRULE` and plain English.

An *ephemeris* is a table of recurring positions over time. This one holds
recurrence rules: parse them from either syntax into one structure, compute
occurrences from it, and render it back out in either syntax.

```elixir
{:ok, rule} = Ephemeris.parse("FREQ=MONTHLY;BYDAY=-1SU")
{:ok, rule} = Ephemeris.parse("every last sunday of the month")

Ephemeris.to_rrule(rule)     #=> "FREQ=MONTHLY;BYDAY=-1SU"
Ephemeris.to_sentence(rule)  #=> "every last Sunday of the month"

Ephemeris.next(rule, ~U[2026-01-01 09:00:00Z])
#=> {:ok, ~U[2026-01-25 09:00:00Z]}
```

## Why both syntaxes

`RRULE` is the standard: portable, precise, and what a calendar application
speaks. It is also unreadable in a configuration file. Plain English is the
opposite on every count. Holding one structure and rendering either means a
rule can be written the readable way, stored the portable way, and shown back
either way — without two implementations that disagree.

## Status

The `RRULE` reader and writer, the English reader and writer, and the
occurrence engine are complete: 44 tests and 13 doctests, no runtime
dependencies.

The occurrence engine supports `FREQ`, `INTERVAL`, `COUNT`, `UNTIL`, `WKST`,
`BYSECOND`, `BYMINUTE`, `BYHOUR`, `BYDAY` including ordinals such as `-1SU`,
`BYMONTHDAY`, `BYYEARDAY`, `BYWEEKNO`, `BYMONTH` and `BYSETPOS`.

A date that does not exist in a period is skipped, not clamped, as
RFC 5545 §3.3.10 requires: `FREQ=MONTHLY;BYMONTHDAY=31` yields 31 January and
31 March, never 28 February.

## Scope

A rule says *when* something recurs and nothing else — no process, no callback,
no timer, no implicit current time. Every calculation takes an explicit
reference `DateTime`. Scheduling belongs to whatever uses this.

## Licence

MIT. See [LICENSE](LICENSE).
