# Changelog

## 0.4.0 — 2026-09-06

Sections. The gateway reads each list's section headings, which section
every reminder belongs to and its manual position from the Reminders store
(`sections` on lists, `section` and `position` on reminders). Window and
panel show the headings with the reminders under them in the Mac's order,
unsectioned ones first, as Reminders.app does; the cursor skips headings.
New IPC `open_list <name>` opens the window on a list. Adding into a section
is not possible through EventKit; new reminders land unsectioned.

## 0.3.0 — 2026-09-06

Keyboard navigation follows the platform convention. Window: Tab between
sidebar, list and the new-reminder field; arrows (j/k) within a region;
Left/Right (h/l) between sidebar and list and to fold groups; Enter opens a
list or ticks; Space ticks; 1 2 3 jump to Today / Scheduled / All and 4–9 to
lists in sidebar order (also Alt+digit); `c` toggles completed (was `h`);
g/G top/bottom; a theme focus ring shows the active region; the window opens
on Today. Panel: Tab now moves to the neighbouring bar panel as in every
Omarchy panel; Left/Right (h/l) switch list; `n` also opens the add field.

## 0.2.1 — 2026-09-06

- `allow_verbs` in `~/.tikk/config`: the dispatcher refuses any verb outside
  the set with exit 77 and an audit line, before the verb tool starts; the
  verb tool checks again. `check` stays reachable. The plugin reads
  `check --json` and hides delete when the gateway forbids it.

## 0.2.0 — 2026-09-06

Gateway hardening after a review of the Mac side.

- reminders-cli is always called as `subcommand, options (--name=value), --,
  positionals`. A list or reminder named `--format` or `-h` is data, never a
  flag. stdin is closed for the child; output is decoded as UTF-8.
- The Reminders store is read in place (`mode=ro`), no longer copied per
  poll (it was 100 MB every 30 seconds).
- New `~/.tikk/config`: `allow_lists` scopes the key to named lists;
  `audit_log` (on by default) records every write, failed write and refused
  command with timestamp and client address.
- `check` reports version, store access, allowlist and audit log.
- Dates tolerate fractional seconds and offsets; malformed records are a
  clean error instead of a traceback; usage errors exit 64 everywhere.
- Deleting a completed reminder re-completes it if the delete fails after the
  necessary uncomplete.
- `tikk-reminders` restructured (one function per verb) with a 28-case
  standard-library test suite, green on Python 3.9 and 3.12.
- `gateway/install.sh`, `docs/gateway.md`, `SECURITY.md`.

## 0.1.0 — 2026-09-06

First working version: dispatcher, EventKit verbs, Linux shim, Omarchy bar
pill, panel and Reminders.app-style window, groups and colours from the
Reminders store, demo mode.
