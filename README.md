# mac-cleaner

A small Zig program that finds and frees the space a long-lived developer Mac
accumulates: container images, VM disks, Xcode device support, toolchain caches,
`node_modules` folders from projects you forgot about, and Time Machine
snapshots.

The goal is a machine that can install a macOS update again, without
reinstalling the OS and without losing work.

## Safety

The rule is simple and enforced in code, not by convention:

> **mac-cleaner only ever deletes inside your home directory.**

- Everything owned by macOS (`/Library`, `/private/var`, `/System`,
  `/Applications`, `/Volumes`, ...) is **reported for information only and never
  modified**. Those rules are marked `info only`, are excluded from the deletion
  plan even with `--only`, and there is no code path that runs a `sudo rm`.
- `~/Library`, `~/Desktop`, `~/Documents`, `~/Downloads`, `~/Movies`, `~/Music`,
  `~/Pictures`, `~/Applications` and cloud folders (`Dropbox`, `OneDrive`, ...)
  are never deleted themselves.
- Developer source roots (`~/code`, `~/src`, `~/dev`, `~/Developer`,
  `~/projects`, `~/repos`, `~/work`, `~/Documents/GitHub`) are never deleted
  themselves — the artifact scanner only removes build output *inside* them.
- Credentials and personal data are protected: `~/.ssh`, `~/.gnupg`, `~/.aws`,
  `~/.config`, `~/.kube/config`, `~/.docker/config.json`, `~/Library/Keychains`,
  `~/Library/Preferences`, `~/Library/Mail`, `~/Library/Messages`,
  `~/Library/Safari`, `~/Library/Group Containers`, `~/Library/CloudStorage` and
  browser profiles.
- Every path is checked **twice**: lexically, and again after resolving
  symlinks. A symlinked parent can never redirect a deletion somewhere else, and
  paths containing `.` or `..` are rejected outright.
- Symlinks are unlinked, never followed. A directory rule never empties a
  directory that is itself a symlink.
- The artifact scanner only matches a fixed list of known build-output names,
  and refuses to delete a matched folder if that folder *itself* contains a git
  repository (or submodule) within four levels. A project being a git repo is
  fine: its `node_modules` is still removable.
- Nothing is deleted without `--apply` (and `--dry-run` always wins over it), and
  every run prints the full plan first.

The worst case is re-pulling container images or rebuilding a project, never a
broken system.

### These guarantees are tested

`zig build test` runs 42 tests, including property tests over the whole rule
table: every user rule must resolve to a path the policy allows, every
system rule must be refused, every artifact pattern must be deletable, and a
real temporary "home" is populated with junk plus secrets/documents before
`removePath` is exercised and the survivors are asserted on disk.

## Run it on the Mac without building

`dist/` holds release binaries built from this source, committed on purpose:
the machine that needs the cleanup has no room to install a compiler.

```sh
git clone <repo> && cd mac-cleaner

./dist/mac-cleaner-arm64 audit   # Apple Silicon
./dist/mac-cleaner-amd64 audit   # Intel
```

They are stored with the executable bit set, so a fresh clone can run them
directly. If your shell still refuses, `chmod +x dist/mac-cleaner-*`.

Rebuild them after any code change:

```sh
zig build dist        # writes dist/mac-cleaner-arm64 and dist/mac-cleaner-amd64
```

## Build from source

Requires Zig 0.16.0.

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/mac_cleaner --help
```

Cross-compile for one macOS architecture:

```sh
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-macos  -Doptimize=ReleaseFast
```

## Commands

```
mac-cleaner audit         read-only sweep: rules + project output + disk summary
mac-cleaner scan          measure every known space hog (default, read only)
mac-cleaner clean         delete reclaimable data; dry run unless --apply
mac-cleaner artifacts     find node_modules, target, .zig-cache, ... in projects
mac-cleaner big [path]    list the largest files under a path
mac-cleaner du [path]     show the size of each entry in a directory
mac-cleaner disk          total, used and available space on the startup volume
mac-cleaner doctor        disk summary and a suggested order of operations
mac-cleaner list          show every rule and what it removes
```

### How much space is there?

```sh
mac-cleaner disk
```

prints the startup volume's total, used and available space as a usage bar and
in bytes, and counts local Time Machine snapshots. It reads `df` and nothing
else, so it is instant and read only. `--json` returns one object:
`{"total_bytes": ..., "used_bytes": ..., "available_bytes": ..., "used_percent": ..., "snapshots": ...}`.

### Check everything, delete nothing

```sh
mac-cleaner audit
```

`audit` is the "what would I get back?" command. It runs the full rule scan and
the project artifact scan, adds them up, and ends with a single number. It has
no deletion code on its path, and `--apply` is explicitly ignored:

```
Audit (read only)
    nothing in this report deletes anything
...
   8.0 MB  reclaimable in total
    known locations 4.0 MB + project build output 4.0 MB
```

`audit --json` returns the same data as one object:
`{"read_only": true, "disk": {...}, "rules": {"total_bytes": ...}, "artifacts": {...}, "reclaimable_bytes": ...}`.

To go further without deleting, `du ~` shows folder sizes and `big ~` lists
individual files; both are read-only too.

A typical first run on a full machine:

```sh
mac-cleaner audit                      # everything, read only, one total
mac-cleaner disk                       # total, used and available right now
mac-cleaner doctor                     # what is going on, what to do first
mac-cleaner scan                       # sizes for ~110 known locations
mac-cleaner clean                      # dry run at the "recreatable" level
mac-cleaner clean --level safe --apply # junk only: caches, logs, trash
mac-cleaner artifacts                  # node_modules / target / .zig-cache ...
mac-cleaner artifacts --apply --min-size 100M
mac-cleaner du ~ --top 15              # which home folder is huge?
mac-cleaner big ~/Downloads --top 10   # biggest individual files
```

### Looking without touching anything

`audit`, `scan`, `artifacts`, `du`, `big`, `disk` and `doctor` are read-only.
They only open directories and read file metadata; there is no deletion code on
those paths at all. `scan` ends with the amount you could reclaim at each safety
level:

```
  if you delete:   safe 4.0 MB   + caches 8.0 MB   everything 24.6 GB
```

`clean` and `artifacts` are also read-only unless you pass `--apply`, and
`--dry-run` is accepted on every command (it always wins over `--apply`), so a
typo can never delete anything:

```sh
mac-cleaner clean --dry-run --apply   # still a dry run
mac-cleaner scan --json | jq .total_bytes
```

## Safety levels

| level | meaning | examples |
| --- | --- | --- |
| `safe` | pure junk, nothing is lost | logs, `~/Library/Logs`, npm/deno/go caches |
| `recreatable` | rebuilt on the next run | DerivedData, device support, `~/Library/Caches`, Gradle caches |
| `risky` | real data, re-created manually | Docker image store, VMs, iPhone backups, rustup toolchains |

`scan` shows everything, `clean` defaults to `recreatable`, and `risky` items
require `--level risky` or an explicit `--only <id>`.

## Options

```
--level <safe|recreatable|risky>   how much you are willing to delete
--group <name>                     only rules in one group
--only <id,id>                     only these rules
--exclude <id,id>                  never these rules
--apply                            actually delete (clean, artifacts; ignored by audit)
--dry-run                          never delete, just report (wins over --apply)
--root <path>                      search path (artifacts, repeatable)
--depth <n>                        max recursion depth (artifacts, default 8)
--include <name,name>              also match dist, build, vendor, bin, obj
--top <n>                          rows to show (big, du; default 25)
--min-size <10M>                   ignore smaller files
--json                             machine readable output
--no-color, --color                force colour off or on
--no-paths                         hide paths in tables
-v, --verbose                      explain each rule and all its locations
-q, --quiet                        no progress output
```

## Layout

| file | purpose |
| --- | --- |
| `src/main.zig` | process setup and command dispatch (including the read-only `audit`) |
| `src/cli.zig` | argument parsing and help text |
| `src/rules.zig` | the rule database: paths, commands, safety levels |
| `src/scan.zig` | measures every rule, de-duplicates overlapping rules |
| `src/measure.zig` | directory walking and size accounting |
| `src/clean.zig` | deletion with the safety policy |
| `src/artifacts.zig` | per-project build output discovery |
| `src/big.zig` | largest files and directory breakdowns |
| `src/doctor.zig` | `df`, Time Machine snapshots, suggested order |
| `src/pathx.zig` | `~` and `*` expansion for rule patterns |
| `src/report.zig` | table and JSON rendering |
| `src/ui.zig` | colours, columns, progress |
| `src/humanize.zig` | byte formatting helpers |
| `src/proc.zig` | running external commands |
| `dist/` | committed release binaries for macOS (arm64 + amd64) |

Tests cover the safety policy, rule table integrity, path expansion, size
formatting, JSON output and CLI parsing:

```sh
zig build test
```
