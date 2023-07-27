# Sea

A simple linux-only (for now) CLI file navigator inspired by
[`nnn`](https://github.com/jarun/nnn). It has **zero** dependencies (not even
ncurses) except for [Zig](https://ziglang.org/) itself, everything is part of
the Zig Standard Library or made from scratch. It is statically compiled and
ready to run on any linux distribution.

# Building from source

## Requirements

The only requirement to build is the Zig compiler itself. This project follows
the main branch and is up-to-date with features, and sometimes bugs. The latest
tested version of the compiler that compiles correctly was
`0.11.0-dev.4191+1bf16b172`. Anything more recent than this version should work 
without problems.

If you are unsure of what version is in your system, run the following command:

```sh
zig version
```

You can download the latest official compiler binaries from the Zig
[downloads](https://ziglang.org/downloads/) page.

## Once you have the compiler

Clone the repository, and just one command to build:

```sh
zig build -Doptimize=ReleaseSafe
```
To execute it, run:

```sh
zig build -Doptimize=ReleaseSafe run
```

Or add `zig-out/bin/` to your `$PATH` environment variable.

# Keymappings

## Movement

| Key | Action |
|-----|--------|
| <kbd>q</kbd> | quit |
| <kbd>h</kbd> | go left (go to the above directory) |
| <kbd>j</kbd> | go down one entry in current directory |
| <kbd>k</kbd> | go up one entry in current directory |
| <kbd>l</kbd> | go right (enter directory selected) |
| <kbd>g</kbd> | go to top |
| <kbd>G</kbd> | go to bottom |

## Selections

| Key | Action |
|-----|--------|
| <kbd>Space</kbd> | toggle select  |
| <kbd>a</kbd>     | select everything in current directory |
| <kbd>A</kbd>     | invert selection |

# Planned Features

The following are ordered by priority:
1. [x] Support `cd` on quit
1. [x] Select with <kbd>Space</kbd>
    - [x] Deselect
    - [ ] Save selections between directory changes
1. [x] Select all with <kbd>a</kbd>
1. [x] Invert selection with <kbd>A</kbd>
1. [ ] Delete selections
1. [ ] Move selections
1. [ ] Create files and directories
1. [ ] Properly handle arrow keys (they were removed because of overlap with
   other keys when reading byte by byte)
1. [ ] macOS support
