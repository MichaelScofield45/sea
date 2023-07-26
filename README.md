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

| Key | Action |
|-----|--------|
| <kbd>q</kbd>                      | quit |
| <kbd>h</kbd> or <kbd>&larr;</kbd> | go left (go to the above directory) |
| <kbd>j</kbd> or <kbd>&darr;</kbd> | go down one entry in current directory |
| <kbd>k</kbd> or <kbd>&uarr;</kbd> | go up one entry in current directory |
| <kbd>l</kbd> or <kbd>&rarr;</kbd> | go right (enter directory selected) |
| <kbd>g</kbd>                      | go to top |
| <kbd>G</kbd>                      | go to bottom |

# Planned Features

The following are ordered by priority:
- [x] Support `cd` on quit
- [ ] Selections, probably with <kbd>Space</kbd>
- [ ] Delete selections
- [ ] Create selections
- [ ] Move selections
- [ ] macOS support
