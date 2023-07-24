# Sea

A simple linux-only (for now) CLI file navigator inspired by
[`nnn`](https://github.com/jarun/nnn). It has **zero** dependencies (not even
ncurses) except for [Zig](https://ziglang.org/) itself, everything is part of
the Zig Standard Library or made from scratch. It is statically compiled and
ready to run on any linux distribution.

# Build from source

Clone the repository, and just one command to build:

```sh
zig build
```
To execute it, run:

```sh
zig build run
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
