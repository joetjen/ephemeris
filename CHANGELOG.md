# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
