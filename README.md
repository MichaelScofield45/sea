# Sea

A simple linux-only (for now) CLI file navigator inspired by
[`nnn`](https://github.com/jarun/nnn). It has **zero** dependencies (not even
ncurses) except for Zig itself, everything is part of the Zig Standard Library
or made from scratch. It is statically compiled and ready to run on any linux
distribution.

# Build from source

Just one command to build:

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
| `q` | quit |
| `h` | go left (go to the above directory) |
| `j` | go down one entry in current directory |
| `k` | go up one entry in current directory |
| `l` | go right (enter directory selected) |
| `g` | go to top |
| `G` | go to bottom |
