# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-01

### Added

- `Ephemeris.Rule`, the structure both syntaxes parse into and render from,
  following RFC 5545 §3.3.10 field for field.
- `Ephemeris.RRule.parse/1` and `Ephemeris.RRule.render/1`, reading and writing
  RFC 5545 `RRULE` text. Every supported rule round-trips to the exact string it
  was parsed from, and parts are rendered in the order the standard lists them
  so two rules can be compared as text.

  Parsing is strict: an unknown part, a malformed value, a zero or out-of-range
  number, or `COUNT` together with `UNTIL` is an error rather than something
  quietly dropped.

- `Ephemeris.Occurrence.next/2` and `Ephemeris.Occurrence.stream/2`, computing
  when a rule fires. Occurrences are built one period at a time — the whole
  candidate set, sorted, then filtered — because `BYSETPOS` selects the *nth
  candidate of a period* and cannot be evaluated while walking forward.

  Supports `FREQ`, `INTERVAL`, `COUNT`, `UNTIL`, `WKST`, `BYSECOND`, `BYMINUTE`,
  `BYHOUR`, `BYDAY` including ordinals such as `-1SU`, `BYMONTHDAY`,
  `BYYEARDAY`, `BYWEEKNO`, `BYMONTH` and `BYSETPOS`.

  A date that does not exist in a period is skipped rather than clamped, as
  RFC 5545 §3.3.10 requires: `FREQ=MONTHLY;BYMONTHDAY=31` yields 31 January and
  31 March, never 28 February. Clamping there is what makes a scheduler fire on
  the wrong day without saying so.

- `Ephemeris.Sentence.parse/1` and `Ephemeris.Sentence.render/1`, reading and
  writing rules as plain English: `every last Sunday of the month`,
  `every 2 weeks on Monday`, `every last weekday of the month`,
  `every 1st of the month at 8:00 am`. Every supported sentence renders back to
  itself, so a rule can be shown to a person and read back without loss.

  Unrecognised phrasing is refused rather than approximated. A sentence that
  parses into *almost* the right rule is worse than one that fails outright:
  the failure is visible, the near-miss fires at the wrong time.

- `Ephemeris.parse/1`, which reads either syntax. An expression containing `=`
  is `RRULE` and anything else is English — unambiguous rather than a guess,
  since `RRULE` is always `KEY=VALUE` pairs and no English sentence contains
  `=`. Plus `to_rrule/1`, `to_sentence/1`, `next/2` and `stream/2`.

