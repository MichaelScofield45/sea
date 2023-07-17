const std = @import("std");
const linux = std.os.linux;
const EntryList = @import("entry_list.zig");

pub const State = struct {
    cursor: usize,
    running: bool,
    cwd_name: []const u8,
    original_termios: std.os.termios,
};

pub fn init(stdin: std.fs.File, state: *State) !void {
    state.original_termios = try std.os.tcgetattr(stdin.handle);

    var new = state.original_termios;
    new.iflag &= ~(linux.BRKINT | linux.ICRNL | linux.INPCK | linux.ISTRIP | linux.IXON);
    new.oflag &= ~(linux.OPOST);
    new.cflag |= (linux.CS8);
    new.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN | linux.ISIG);
    try std.os.tcsetattr(stdin.handle, .FLUSH, new);
}

pub fn deinit(stdin: std.fs.File, state: State) void {
    std.os.tcsetattr(stdin.handle, .FLUSH, state.original_termios) catch |err| {
        std.log.err("unexpected error at shutdown: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

pub fn handleInput(input: u8, state: *State, dir_list: *EntryList, file_list: *EntryList) !void {
    const total_items = dir_list.getTotalEntries() + file_list.getTotalEntries();
    const total_items_index = if (total_items != 0) total_items - 1 else 0;

    switch (input) {
        'q' => state.running = false,
        'h' => {
            // state.cursor = 0;
            clearEntries(dir_list, file_list);
            state.cursor = try appendAboveEntries(dir_list, file_list, state.cwd_name);
            try std.process.changeCurDir("..");
        },
        'j' => state.cursor += if (state.cursor != total_items_index) 1 else 0,
        'k' => state.cursor -= if (state.cursor != 0) 1 else 0,
        'l' => {
            if (state.cursor < dir_list.getTotalEntries()) {
                const name = dir_list.getNameAtEntryIndex(state.cursor);
                state.cursor = 0;
                try std.process.changeCurDir(name);
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
