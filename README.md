# tikk

Tick your Apple Reminders from Linux — over an SSH gateway to your Mac.

iCloud Reminders have no server API: since the 2019 "upgrade" they live in a
private CloudKit store that only Apple's own frameworks can reach. So tikk
does the only thing that works: a Mac you own answers a tightly confined SSH
key and runs the verbs for you. Your Mac syncs to iCloud, iCloud syncs to
your phone.

```
Linux box ──ssh (one restricted key, verbs only)──▶ Mac gateway ──EventKit──▶ Reminders ──iCloud──▶ everywhere
```

**Scope:** remote control plus a mirror, not two-way sync. You list, add,
complete and delete; conflict resolution and offline queues are deliberately
out of scope.

## Status

Gateway done and measured. Omarchy plugin: pill, keyboard panel, and an app window laid out like Reminders.app (smart lists, My Lists with counts, completed section, new-reminder row).

| Verb | Latency (Mac mini M2, macOS 26.6) |
|---|---|
| `lists`, `show <list>` | 0.1–0.3 s (0.6 s for a shared list) |
| `add`, `complete`, `uncomplete`, `delete` | 0.2–0.4 s |

## Gateway (the Mac)

Requirements: macOS with Reminders signed into iCloud, Remote Login enabled,
[reminders-cli](https://github.com/keith/reminders-cli)
(`brew install keith/formulae/reminders-cli`), Python 3 (Xcode CLT is enough).

1. Copy `gateway/tikk-dispatch` and `gateway/tikk-reminders` to
   `~/.tikk/bin/` on the Mac and `chmod +x` them.
2. On the Linux box, make a dedicated key: `ssh-keygen -t ed25519 -f ~/.ssh/tikk_ed25519 -N ""`.
3. Enroll it on the Mac in `~/.ssh/authorized_keys`, confined to the
   dispatcher and to your Linux box's address:

   ```
   restrict,command="$HOME/.tikk/bin/tikk-dispatch",from="<linux-box-ip>" ssh-ed25519 AAAA… tikk@linux-box
   ```

   `restrict` turns off pty, forwarding, X11 and agent; `command=` means the
   key can run tikk verbs and nothing else, whatever the client asks for.
4. Grant access once. From the Linux box run
   `ssh -i ~/.ssh/tikk_ed25519 user@mac check`. If it reports missing
   Reminders access, trigger the prompt from any SSH session on the Mac:

   ```
   osascript -e 'tell application "Reminders" to get name of lists'
   ```

   A dialog appears **on the Mac's screen** (use Screen Sharing if it is
   headless): allow `sshd-keygen-wrapper` to control Reminders. On current
   macOS this also records the Reminders data grant that EventKit needs, and
   `check` turns green. The grant applies to every SSH session on that Mac,
   not just the tikk key — that is macOS's granularity, not ours.

Then, from the Linux box:

```
ssh -i ~/.ssh/tikk_ed25519 user@mac lists
ssh -i ~/.ssh/tikk_ed25519 user@mac show Groceries
ssh -i ~/.ssh/tikk_ed25519 user@mac add Groceries "Oat milk" --due 2026-09-10 --priority 5
ssh -i ~/.ssh/tikk_ed25519 user@mac complete Groceries "Oat milk"
ssh -i ~/.ssh/tikk_ed25519 user@mac delete Groceries 6F1D…-UUID
```

`snapshot` returns every list with its open count plus every open reminder
in one round trip; the plugin polls that. Every verb takes `--json`. `add` accepts `--body`, `--due YYYY-MM-DD`
(all-day) or `--due "YYYY-MM-DD HH:MM"`, and `--priority 0|1|5|9`
(Reminders' own scale: none, high, medium, low). `complete`, `uncomplete`
and `delete` take an id or an exact name; an ambiguous name is refused.
Exit codes follow `sysexits.h` (64 usage, 65 ambiguous, 66 not found,
69 backend failure, 77 no permission, 78 tool missing).

### Why EventKit and not AppleScript

`gateway/tikk-reminders-applescript` is the same interface driven through
Reminders.app with osascript. It works, and it needs no extra install, but
on macOS 26 every `make new reminder` takes about 28 seconds (Reminders.app
spins on its main thread after the save and answers nothing else meanwhile),
every change to a shared list takes as long, and AppleScript only sees the
default account's lists. EventKit does all of it in a fraction of a second
and does not need Reminders.app running. The file stays as a documented
dead end and a fallback.

## Security model

- The Linux box holds one key that can only run the verbs above; no shell,
  no file transfer, no forwarding. Anything else is refused with exit 64.
- The dispatcher parses the command with shell-style quoting and `exec`s
  the verb tool directly; no shell is ever involved on the Mac.
- The verb tool looks for `reminders` in fixed locations and runs with a
  fixed system `PATH`.

## License

MIT.

## Omarchy plugin (the Linux box)

`plugin/` is an Omarchy shell plugin: a bar pill with the number of open
reminders in one list, and a keyboard-driven panel to tick them off and add
new ones. It talks to the Mac through `bridge/linux/tikk-shim`.

1. Install the shim: `install -m 755 bridge/linux/tikk-shim ~/.local/bin/tikk`
   and write `~/.config/tikk/bridge.conf`:

   ```
   host = user@mac-hostname-or-ip
   key  = ~/.ssh/tikk_ed25519
   ```

   `tikk check` should now answer from the Mac.
2. Install the plugin: `omarchy plugin add <this repo url>` once it is on
   main; until then, copy `plugin/` to `~/.config/omarchy/plugins/fileri.tikk/`.
3. Put it on the bar: add `{ "id": "fileri.tikk", "list": "Groceries" }` to
   `bar.layout.right` in `~/.config/omarchy/shell.json`, then
   `omarchy-restart-shell`. Leave `list` empty to take the first list the Mac
   reports.

Panel keys: Up/Down or j/k move, Enter or click ticks off, Delete deletes,
`a` or `/` jumps to the add field, Tab cycles lists, Esc closes.
Double-click the pill (or `ipc call fileri.tikk app`) for the window: sidebar
with Today / Scheduled / All and your lists, main pane with tick circles,
notes and due dates, `h` shows completed, `n` starts a new reminder.
The pill dims when the Mac is unreachable. Polling is every 30 s; every
action re-polls immediately. Writes only ever happen on your keypress.

IPC for keybinds and scripts:

```
omarchy-shell ipc call fileri.tikk toggle
omarchy-shell ipc call fileri.tikk add "Oat milk"
omarchy-shell ipc call fileri.tikk complete "Oat milk"
omarchy-shell ipc call fileri.tikk status
```
