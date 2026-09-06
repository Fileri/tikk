# Security

tikk lets a Linux machine change data on a Mac over SSH, so its security
model is the product. It is described in full in [docs/gateway.md](docs/gateway.md).
The short version:

- The Linux box holds one dedicated key that macOS's `sshd` confines to a
  single command (`restrict,command=…,from=…`). No shell, no forwarding.
- That command is an allowlist of verbs, checked before any argument parsing.
- Verbs call reminders-cli with a fixed argument shape (`--` before data) and
  a fixed system `PATH`; no shell is involved on the Mac.
- An optional per-list allowlist and an always-on audit log of writes and
  refusals live on the Mac, out of the key holder's reach.
- Nothing about your reminders is stored on the Linux side.

## Reporting a vulnerability

Please open a GitHub issue if the problem is not sensitive, or use GitHub's
private vulnerability reporting on this repository if it is. Include the
macOS and Omarchy versions and, if you can, a way to reproduce. You will get
an answer within a week.

## Out of scope

- Anything that requires the Mac account itself to be compromised. Whoever
  can write to `~/.tikk/bin` or `~/.ssh/authorized_keys` on the Mac already
  owns the data.
- macOS granting TCC permissions to every SSH session rather than to one
  key. That is macOS's granularity; the document above explains the impact.
