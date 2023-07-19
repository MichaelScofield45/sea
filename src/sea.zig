const std = @import("std");
const linux = std.os.linux;
const EntryList = @import("entry_list.zig");

pub const State = struct {
    cursor: usize,
    running: bool,
    cwd_name: []const u8,
    original_termios: std.os.termios,
    dims: struct {
        cols: u32,
        rows: u32,
    },
};

pub fn init(stdin: std.fs.File, state: *State) !void {
    state.original_termios = try std.os.tcgetattr(stdin.handle);

    var new = state.original_termios;
    new.iflag &= ~(linux.BRKINT | linux.ICRNL | linux.INPCK | linux.ISTRIP | linux.IXON);
    new.oflag &= ~(linux.OPOST);
    new.cflag |= (linux.CS8);
    new.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN | linux.ISIG);
    try std.os.tcsetattr(stdin.handle, .FLUSH, new);

    state.dims = try getTerminalSize(stdin.handle);
}

pub fn deinit(stdin: std.fs.File, state: State) void {
    std.os.tcsetattr(stdin.handle, .FLUSH, state.original_termios) catch |err| {
        std.log.err("unexpected error at shutdown: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

// Using std.meta things seems sketchy
fn getTerminalSize(stdin_handle: std.os.fd_t) !std.meta.FieldType(State, .dims) {
    var size: linux.winsize = undefined;
    // TODO: Handle error with errno
    _ = linux.ioctl(stdin_handle, linux.T.IOCGWINSZ, @intFromPtr(&size));

    return .{
        .cols = size.ws_col,
        .rows = size.ws_row,
    };
}

pub fn printEntries(writer: anytype, state: State, dir_list: EntryList, file_list: EntryList) !void {
    const height = state.dims.rows - 6;
    const total_items = dir_list.getTotalEntries() + file_list.getTotalEntries();

    var d_start: usize = 0;
    var d_end: usize = dir_list.getTotalEntries();
    var f_start: usize = 0;
    var f_end: usize = file_list.getTotalEntries();

    if (state.cursor > height) {
        // This works because integer division loses fractional information.
        // Normal math would dictate that this is redundant.
        const start = height * (state.cursor / height);
        const end = if (total_items - start < height) total_items - start else start + height;
        if (start > dir_list.getTotalEntries()) {
            d_start = 0;
            d_end = 0;
            f_start = start;
            f_end = end;
        } else {
            d_start = start;
            d_end = dir_list.getTotalEntries();
            f_start = end - dir_list.getTotalEntries();
            f_end = end;
        }
    }

    for (dir_list.getEndIndices()[d_start..d_end], 0..) |_, entry_idx| {
        if (entry_idx == state.cursor)
            try writer.writeAll("\x1B[30;44m")
        else
            try writer.writeAll("\x1B[1;34;49m");

        try writer.print("{s}\x1B[1E", .{dir_list.getNameAtEntryIndex(entry_idx)});
    }

    try writer.writeAll("\x1B[0m");
    for (file_list.getEndIndices()[f_start..f_end], 0..) |_, entry_idx| {
        if (entry_idx + dir_list.getTotalEntries() == state.cursor)
            try writer.writeAll("\x1B[30;47m")
        else
            try writer.writeAll("\x1B[0m");

        try writer.print("{s}\x1B[1E", .{file_list.getNameAtEntryIndex(entry_idx)});
    }
}

pub fn handleInput(input: u8, state: *State, dir_list: *EntryList, file_list: *EntryList, buffer: []u8) !void {
    const total_items = dir_list.getTotalEntries() + file_list.getTotalEntries();
    const total_items_index = if (total_items != 0) total_items - 1 else 0;

    switch (input) {
        'q' => state.running = false,
        'h' => {
            // state.cursor = 0;
            clearEntries(dir_list, file_list);
            state.cursor = try appendAboveEntries(dir_list, file_list, state.cwd_name);
            try std.process.changeCurDir("..");

            const path = try std.process.getCwd(buffer);
            state.cwd_name = std.fs.path.basename(path);
        },
        'j' => state.cursor += if (state.cursor != total_items_index) 1 else 0,
        'k' => state.cursor -= if (state.cursor != 0) 1 else 0,
        'l' => {
            if (state.cursor < dir_list.getTotalEntries()) {
                const name = dir_list.getNameAtEntryIndex(state.cursor);
                state.cursor = 0;

                try std.process.changeCurDir(name);
                const path = try std.process.getCwd(buffer);
                state.cwd_name = std.fs.path.basename(path);

                clearEntries(dir_list, file_list);
                try appendCwdEntries(dir_list, file_list);
            }
        },
        else => {},
    }
}

pub fn clearEntries(dir_list: *EntryList, file_list: *EntryList) void {
    dir_list.names.clearRetainingCapacity();
    dir_list.end_indices.clearRetainingCapacity();
    file_list.names.clearRetainingCapacity();
    file_list.end_indices.clearRetainingCapacity();
}

pub fn appendCwdEntries(dir_list: *EntryList, file_list: *EntryList) !void {
    var iterable_dir = try std.fs.cwd().openIterableDir(".", .{});
    defer iterable_dir.close();

    // Store in ArrayLists
    {
        // Iter current dir
        var it = iterable_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .directory) {
                try dir_list.append(entry.name);
            } else {
                try file_list.append(entry.name);
            }
        }
    }
}

/// Appends all entries of the above directory, returning which entry matches the
/// current working directory
pub fn appendAboveEntries(dir_list: *EntryList, file_list: *EntryList, cwd: []const u8) !usize {
    var iterable_dir = try std.fs.cwd().openIterableDir("..", .{});
    defer iterable_dir.close();

    var match: ?usize = null;

    var it = iterable_dir.iterate();
    var count: usize = 0;

    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            try dir_list.append(entry.name);
            if (std.mem.eql(u8, cwd, entry.name)) match = count;
            count += 1;
        } else {
            try file_list.append(entry.name);
        }
    }

    if (match) |index|
        return index
    else
        return error.NoMatchingDirFound;
}
