# The gateway (Mac side)

This document is for whoever runs the Mac: what the two scripts do, what the
SSH key can and cannot do, what is logged, how to scope or revoke access, and
what every verb returns. The Linux side is described in the main README.

## What runs where

```
Linux box                                 Mac
─────────                                 ───
tikk (shim) ──ssh key──▶ sshd ──forced command──▶ tikk-dispatch ──execv──▶ tikk-reminders ──▶ reminders-cli ──▶ EventKit
                                                  (verb allowlist)         (arguments, config,    (keith/reminders-cli)
                                                                            audit, allowlist)
```

Two files live in `~/.tikk/bin/` on the Mac:

| File | Role |
|---|---|
| `tikk-dispatch` | Forced-command entry point. Reads `SSH_ORIGINAL_COMMAND`, splits it with shell quoting rules, checks the first word against the verb allowlist, sets a fixed system `PATH`, and `exec`s `tikk-reminders` with the words as argv. No shell is ever involved. Anything else is refused with exit 64 and one audit line. |
| `tikk-reminders` | The verbs. Validates arguments, enforces the per-list allowlist, calls reminders-cli with a fixed argv shape, normalises its JSON, reads list metadata from Reminders' store, writes the audit log. |

`~/.tikk/` also holds the optional `config` and the `audit.log`.

## Trust model

**Who is trusted:** the person at the Mac (they own the account, the data and
the key enrolment), and the operating system's own boundaries (sshd, TCC).

**Who is not trusted:** the holder of the SSH key. The Linux box may be
stolen, compromised, or simply buggy. Everything on the Mac side is designed
so that the worst such a holder can do is what the verbs allow, on the lists
the config allows, with every write on record.

**What the key can do**

- Read lists, open and completed reminders, and (with Full Disk Access) list
  groups, colours, emblems and the shared flag.
- Create reminders with a title, notes, due date and priority.
- Complete, uncomplete and delete reminders, by id or exact unique name.

**What the key cannot do**

- Get a shell, a pty, port forwarding, agent forwarding or X11 (`restrict`).
- Run anything but the verbs (the allowlist in `tikk-dispatch` is checked
  before any argument parsing happens).
- Pass flags to reminders-cli through data: list and reminder names are
  always placed after a literal `--`, option values use `--name=value`.
- Reach lists outside `allow_lists`, or run verbs outside `allow_verbs`, if
  you set them. `allow_verbs` without `delete` makes the key non-destructive.
- Connect from anywhere but the address in `from=`.
- Read or write anything on the Mac except through reminders-cli and the
  read-only store query. The scripts never open a shell, never write outside
  `~/.tikk/`, and never touch the network.

**What the key can do that you should know about**

- Delete reminders. That is the point, but it is destructive, so it is
  logged. Apple keeps deleted reminders recoverable for a while in
  Reminders.app.
- Add many reminders quickly. There is no rate limit; the audit log shows it.

**What macOS grants, wider than tikk asks for**

TCC identifies SSH sessions as `sshd-keygen-wrapper`. The Reminders grant and
Full Disk Access therefore apply to every SSH session on that Mac, not only
the tikk key. If other keys can log in to the same account, they inherit it.
That is macOS's granularity; tikk cannot narrow it. Keep the Mac's SSH access
list short.

## Enrolment

Generate the key on the Linux box, never on the Mac, and never reuse a key
that can log in anywhere else:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/tikk_ed25519 -N "" -C tikk@$(hostname)
```

Enroll it on the Mac, one line in `~/.ssh/authorized_keys`:

```
restrict,command="$HOME/.tikk/bin/tikk-dispatch",from="<linux-box-ip>" ssh-ed25519 AAAA… tikk@linux-box
```

`gateway/install.sh` prints this line for you with the right paths. Use a
stable address in `from=` (a Tailscale or LAN IP, or a hostname pattern).

**Revoke:** delete that line. Nothing else needs to change. To rotate,
generate a new key, add its line, test with `check`, then delete the old line.

## Configuration: `~/.tikk/config`

Optional. `key = value`, one per line, `#` comments. Parsed, never sourced.

```
allow_lists = Groceries, Household                                # the key may only see and touch these
allow_verbs = lists, show, snapshot, add, complete, uncomplete    # e.g. everything but delete
audit_log   = ~/.tikk/audit.log                                   # default; "off" disables
```

With `allow_lists` set, `lists` and `snapshot` return only those lists (and
only groups that still have a visible member), and every other verb on a
different list exits 77 before touching reminders-cli.

With `allow_verbs` set, the dispatcher refuses any other verb with exit 77
and an audit line before the verb tool even starts; the verb tool checks
again itself. `check` is always reachable so you can diagnose from the Linux
side, and it reports the effective values. The plugin reads them and hides
the delete affordances when `delete` is not allowed. A sensible default for a
box you do not fully trust is the line above: it can add and tick, it cannot
destroy.

## Audit log

`~/.tikk/audit.log`, created `0600`, one line per event, append only:

```
2026-09-06T19:53:44+02:00 client=203.0.113.5 event=add list="Groceries" id="7B92…" name="Oat milk" priority="0"
2026-09-06T19:53:45+02:00 client=203.0.113.5 event=delete list="Groceries" id="7B92…" name="Oat milk"
2026-09-06T19:53:46+02:00 client=203.0.113.5 event=refused why="'bogus' is not a tikk verb" cmd="'bogus'"
2026-09-06T19:53:48+02:00 client=203.0.113.5 event=add-failed list="Work" key="x" code="77" error="list 'Work' is not in allow_lists on the gateway"
```

Logged: every successful write (`add`, `complete`, `uncomplete`, `delete`),
every failed write (`<verb>-failed` with the exit code), and every command
the dispatcher refused. Reads are not logged. `client` is the address sshd
reports. Values are JSON-quoted so names with spaces or quotes stay on one
line. Rotate it like any log file; the scripts only append.

## Full Disk Access and the Reminders store

`snapshot` opens Reminders' Core Data store
(`~/Library/Group Containers/group.com.apple.reminders/…/Data-*.sqlite`)
read-only, in place, to learn list groups, colours, emblems and sharing,
which EventKit does not expose. It reads one table, writes nothing, and holds
a shared lock for a few milliseconds. That needs Full Disk Access for
`sshd-keygen-wrapper`. Without it, `snapshot` returns the same data minus
those fields, `check` says so, and the client shows a flat list. If you would
rather not grant FDA to SSH, that is a fully supported configuration.

## Verbs and their output

All verbs accept `--json`. Text output is for humans and may change; the JSON
is the contract.

| Verb | Arguments | JSON |
|---|---|---|
| `lists` | | `["Groceries", …]` |
| `show` | `<list> [--all\|--done]` | `[reminder, …]` |
| `snapshot` | | `{"lists": [{name, open, group, color, emblem, shared, order}], "groups": [{name, lists:[…]}], "reminders": [reminder, …]}` |
| `add` | `<list> <name> [--body …] [--due YYYY-MM-DD \| "YYYY-MM-DD HH:MM"] [--priority 0\|1\|5\|9]` | the created `reminder` |
| `complete` / `uncomplete` / `delete` | `<list> <id-or-exact-name>` | `{"id": …, "completed": true}` etc. |
| `check` | | `{"ok", "version", "lists", "ms", "backend", "tool", "store_meta", "allow_lists", "audit_log"}` |

A `reminder`:

```json
{"id": "UUID", "name": "…", "body": "…" | null, "due": "2026-09-10T18:00:00+02:00" | null,
 "allday": false, "priority": 0, "completed": false, "completed_at": null, "list": "Groceries"}
```

Dates are ISO 8601 in the Mac's local zone; `allday` is true when the due
date is a local midnight, which is how EventKit stores date-only reminders.
Priority uses Reminders' own scale: 0 none, 1 high, 5 medium, 9 low.

`complete` matches names among open reminders, `uncomplete` among completed
ones, `delete` among all. A name that matches more than one reminder is
refused (65); use the id. Names that start with `-` go after a literal `--`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | done |
| 64 | usage: unknown verb, bad arguments, unparseable command |
| 65 | ambiguous name |
| 66 | no such list or reminder |
| 69 | reminders-cli failed, timed out, or returned something unexpected; also what the Linux shim returns when the Mac is unreachable |
| 77 | no permission: the Reminders grant is missing, the list is outside `allow_lists`, or the verb is outside `allow_verbs` |
| 78 | reminders-cli is not installed |

## Testing

```sh
python3 -m unittest discover gateway/tests
```

Standard library only; runs on the Mac's own Python 3.9 and on Linux. The
tests never call reminders-cli or touch your data: the backend is mocked, the
store test builds a throwaway sqlite file, and the dispatcher test runs it as
a subprocess against a fake verb tool in a temporary `HOME`.

On a live Mac, `tikk-reminders check` (or `tikk check` from Linux) is the
smoke test: it verifies the tool, the grant, the store access and the config.

## Updating

Copy the two files again (or rerun `gateway/install.sh`). There is no daemon
to restart; every invocation is a fresh process. `tikk-reminders --version`
tells you what is installed.
