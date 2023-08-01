const std = @import("std");
const linux = std.os.linux;
const EntryList = @import("entry_list.zig");
const Allocator = std.mem.Allocator;

cursor: i32,
entries: EntryList,
selection: std.ArrayList(bool),
n_selected: usize,
n_dirs: usize,

/// Scroll window for smooth scrolling and rendering
s_win: struct {
    height: u32,
    end: u32,
},
cwd: []const u8,
original_termios: std.os.termios,

const Self = @This();

pub const Event = enum {
    quit,
    left,
    down,
    up,
    right,
    top,
    bottom,
    select_entry,
    select_all,
    select_invert,
    delete,
    move,
    paste,

    pub fn fromInput(input: [3]u8) ?Event {
        if (input[0] == 0x1b)
            return switch (std.mem.readIntSliceBig(u16, input[1..])) {
                0x5b41 => .up,
                0x5b42 => .down,
                0x5b44 => .left,
                0x5b43 => .right,
                else => null,
            };

        return switch (input[0]) {
            'q' => .quit,
            'h' => .left,
            'j' => .down,
            'k' => .up,
            'l' => .right,
            'g' => .top,
            'G' => .bottom,

            ' ' => .select_entry,
            'a' => .select_all,
            'A' => .select_invert,

            'd' => .delete,
            'v' => .move,
            'p' => .paste,

            else => null,
        };
    }
};

pub fn init(allocator: Allocator, stdin: std.fs.File) !Self {
    var original_termios = try std.os.tcgetattr(stdin.handle);

    var new = original_termios;
    new.iflag &= ~(linux.BRKINT | linux.ICRNL | linux.INPCK | linux.ISTRIP | linux.IXON);
    new.oflag &= ~(linux.OPOST);
    new.cflag |= (linux.CS8);
    new.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN | linux.ISIG);
    try std.os.tcsetattr(stdin.handle, .FLUSH, new);

    return .{
        .cursor = 0,
        .cwd = undefined,
        .original_termios = original_termios,
        .s_win = .{
            .height = try getTerminalSize(stdin.handle) - 8,
            .end = 0,
        },
        .entries = try EntryList.initCapacity(allocator, 2048),
        .selection = try std.ArrayList(bool).initCapacity(allocator, 1024),
        .n_selected = 0,
        .n_dirs = undefined,
    };
}

pub fn deinit(self: *Self, stdin: std.fs.File) void {
    std.os.tcsetattr(stdin.handle, .FLUSH, self.original_termios) catch |err| {
        std.log.err("unexpected error at shutdown: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    self.entries.deinit();
    self.selection.deinit();
}

fn getTerminalSize(stdin_handle: std.os.fd_t) !u32 {
    var size: linux.winsize = undefined;
    // TODO: Handle error with errno
    if (linux.ioctl(stdin_handle, linux.T.IOCGWINSZ, @intFromPtr(&size)) != 0)
        return error.IoctlError;

    return @as(u32, size.ws_row);
}

pub fn printStatus(self: Self, writer: anytype, past_selected: usize) !void {
    try writer.print("\x1B[34m{s}\x1B[0m\x1B[1E", .{self.cwd});

    const entries_len = self.entries.len();
    try writer.print("{} / {}", .{ self.cursor + 1, entries_len });

    const total_selected = self.n_selected + past_selected;
    if (total_selected != 0)
        try writer.print("  \x1B[1;30;42m {} ", .{total_selected});

    try writer.writeAll("\x1B[2E");
}

pub fn printEntries(self: Self, writer: anytype) !void {
    const height = if (self.s_win.height > self.entries.len())
        self.entries.len()
    else
        self.s_win.height;
    const end = self.s_win.end;
    const start = end - height;

    for (self.entries.getIndices()[start..][0..height], start..) |_, n_entry| {
        const under_cursor = n_entry == self.cursor;

        if (self.selection.items[n_entry])
            try writer.writeAll("\x1B[30;42m>\x1B[0m")
        else
            try writer.writeAll("\x1B[0m ");

        if (n_entry < self.n_dirs) {
            try writer.print("{s}{s}\x1B[0m/\x1B[1E", .{
                if (under_cursor) "\x1B[1;30;44m" else "\x1B[1;34;49m",
                self.entries.getNameAtEntryIndex(n_entry),
            });
        } else {
            try writer.print("{s}{s}\x1B[1E", .{
                if (under_cursor) "\x1B[30;47m" else "",
                self.entries.getNameAtEntryIndex(n_entry),
            });
        }
    }
}

pub fn clearEntries(self: *Self) void {
    self.entries.names.clearRetainingCapacity();
    self.entries.indices.clearRetainingCapacity();
}

pub const PastDir = struct {
    idxs: []const u32,
    names: []const u8,
};

fn moveCursor(self: *Self, new_pos: i32, clamp: bool) void {
    if (new_pos < 0)
        self.cursor = @intCast(self.entries.len() - 1)
    else if (new_pos > self.entries.len() - 1)
        self.cursor = if (clamp) @intCast(self.entries.len() - 1) else 0
    else
        self.cursor = new_pos;
}

pub fn handleEvent(
    self: *Self,
    allocator: Allocator,
    event: ?Event,
    running: *bool,
    hash_map: *std.StringArrayHashMap(PastDir),
    buffer: []u8,
) !void {
    if (event == null) return;
    switch (event.?) {
        .quit => running.* = false,

        // Movement
        .left => {
            const curr_selection = try self.findTruesAndNames(allocator);

            if (self.n_selected != 0) {
                try hash_map.put(
                    try allocator.dupe(u8, self.cwd),
                    .{
                        .idxs = curr_selection.true_idxs,
                        .names = curr_selection.names,
                    },
                );
            }

            self.clearEntries();
            self.appendAboveEntries(allocator) catch |err| switch (err) {
                error.NoMatchingDirFound => {},
                else => return err,
            };

            try std.process.changeCurDir("..");

            const path = try std.process.getCwd(buffer);
            self.cwd = path;

            try self.resetSelectionAndResize();

            if (hash_map.getIndex(self.cwd)) |idx| {
                const values = hash_map.values();
                self.n_selected = values[idx].idxs.len;

                for (values[idx].idxs) |bool_idx|
                    self.selection.items[bool_idx] = true;

                allocator.free(values[idx].idxs);
                allocator.free(values[idx].names);
                allocator.free(hash_map.keys()[idx]);
                hash_map.swapRemoveAt(idx);
            } else {
                self.n_selected = 0;
            }
        },

        .down => self.moveCursor(self.cursor + 1, false),

        .up => self.moveCursor(self.cursor - 1, false),

        .right => {
            if (self.cursor > self.n_dirs) return;

            const name = self.entries.getNameAtEntryIndex(@intCast(self.cursor));
            self.cursor = 0;

            const curr_selection = try self.findTruesAndNames(allocator);

            if (self.n_selected != 0) {
                try hash_map.put(
                    try allocator.dupe(u8, self.cwd),
                    .{
                        .idxs = curr_selection.true_idxs,
                        .names = curr_selection.names,
                    },
                );
            }

            try std.process.changeCurDir(name);
            // TODO: This is a syscall, this can be fixed to be handled only by
            // application logic, just append whatever 'name' is to the path using
            // FixedSizedStream
            const path = try std.process.getCwd(buffer);
            self.cwd = path;

            self.clearEntries();
            try self.indexFilesCwd(allocator);

            try self.resetSelectionAndResize();

            if (hash_map.getIndex(self.cwd)) |idx| {
                const values = hash_map.values();
                self.n_selected = values[idx].idxs.len;

                for (values[idx].idxs) |bool_idx|
                    self.selection.items[bool_idx] = true;

                allocator.free(values[idx].idxs);
                allocator.free(values[idx].names);
                allocator.free(hash_map.keys()[idx]);
                hash_map.swapRemoveAt(idx);
            } else {
                self.n_selected = 0;
            }
        },

        .top => self.cursor = 0,

        .bottom => self.cursor = @intCast(self.entries.len() - 1),

        // Selections
        .select_entry => {
            if (self.entries.len() == 0) return;
            const casted: usize = @intCast(self.cursor);
            self.selection.items[casted] = !self.selection.items[casted];
            if (self.selection.items[casted])
                self.n_selected += 1
            else
                self.n_selected -= 1;
            self.moveCursor(self.cursor + 1, true);
        },

        .select_all => {
            for (self.selection.items) |*item|
                item.* = true;

            self.n_selected = self.entries.len();
        },

        .select_invert => {
            for (self.selection.items) |*item|
                item.* = !item.*;

            self.n_selected = self.entries.len() - self.n_selected;
        },

        // Actions
        .delete => {
            if (self.n_selected == 0) return;

            var tmp: [4096]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&tmp);
            const fbs_writer = fbs.writer();

            // TODO: Make this a function that accepts iterator
            // Iterate on past directories
            var past_it = hash_map.iterator();
            while (past_it.next()) |entry| {
                try fbs_writer.writeAll(entry.key_ptr.*);
                try fbs_writer.writeByte('/');
                const write_pos = try fbs.getPos();

                var str_it = std.mem.splitScalar(u8, entry.value_ptr.names, 0);
                while (str_it.next()) |str| {
                    try fbs.seekTo(write_pos);
                    try fbs_writer.writeAll(str);
                    try std.fs.deleteTreeAbsolute(fbs.getWritten());
                }

                // FIXME: Have to delete each entry as it is iterated over,
                // otherwise this is a memory leak. This could be handled by an
                // arena but it would mean piling up memory when a single entry
                // is removed from the hashmap when moving left or right.

                hash_map.allocator.free(entry.key_ptr.*);
                hash_map.allocator.free(entry.value_ptr.idxs);
                hash_map.allocator.free(entry.value_ptr.names);
            }
            hash_map.clearRetainingCapacity();

            // TODO: Make this a function that accepts iterator
            // Iterate on current directory selection
            fbs.reset();
            try fbs_writer.writeAll(self.cwd);
            try fbs_writer.writeByte('/');
            const write_pos = try fbs.getPos();

            var rev_it = std.mem.reverseIterator(self.selection.items);
            var idx: usize = self.selection.items.len - 1;
            while (rev_it.next()) |selected| : (if (idx > 0) {
                idx -= 1;
            }) {
                if (!selected) continue;

                try fbs.seekTo(write_pos);
                try fbs_writer.writeAll(self.entries.getNameAtEntryIndex(idx));
                try std.fs.deleteTreeAbsolute(fbs.getWritten());

                // NOTE: There could be a way to remove elements without having to
                // iterate over the current directory again, the problem with that
                // is the current way to store entries would require multiple stages
                // of reordering, and moving the indices and doing math on them at
                // the same time. Definitely possible, just don't know if worth it.

                // TODO: There IS a better and more efficient way. Use an arena
                // only for allocating the names in bulk, store an ArrayList of
                // slices using a "cold" allocator (general purpose) to keep
                // them alive past the arena resetting. That way when removing
                // things you only need to make a new list without some items.
                // Will have to benchmark to see if it is worth changing the
                // whole system.
            }

            self.clearEntries();
            try self.indexFilesCwd(allocator);
            try self.resetSelectionAndResize();
            self.resetSelection();
            self.cursor = std.math.clamp(
                self.cursor,
                0,
                @as(i32, @intCast(self.selection.items.len -| 1)),
            );
            self.n_selected = 0;
        },
        .move => {},
        .paste => {},
    }

    const new_len = self.entries.len();
    const relative_height = if (self.s_win.height > new_len) new_len else self.s_win.height;

    if (new_len == 0) return;

    if (self.cursor >= self.s_win.end) {
        self.s_win.end = @intCast(self.cursor + 1);
    } else if (self.cursor < self.s_win.end - relative_height) {
        self.s_win.end = @as(u32, @intCast(self.cursor)) + self.s_win.height;
    }
}

pub fn findTruesAndNames(self: Self, allocator: Allocator) !struct {
    true_idxs: []const u32,
    names: []const u8,
} {
    var names = std.ArrayList(u8).init(allocator);
    var idxs = std.ArrayList(u32).init(allocator);
    for (self.selection.items, 0..) |single_bool, idx| {
        if (single_bool) {
            try idxs.append(@intCast(idx));
            try names.appendSlice(self.entries.getNameAtEntryIndex(idx));
            try names.append(0);
        }
    }

    _ = names.popOrNull(); // Remove last null character

    return .{
        .true_idxs = try idxs.toOwnedSlice(),
        .names = try names.toOwnedSlice(),
    };
}

pub fn resetSelection(self: *Self) void {
    for (self.selection.items) |*item|
        item.* = false;
}

pub fn resetSelectionAndResize(self: *Self) !void {
    try self.selection.resize(self.entries.len());
    for (self.selection.items) |*item|
        item.* = false;
}

pub fn indexFilesCwd(self: *Self, allocator: Allocator) !void {
    var iterable_dir = try std.fs.cwd().openIterableDir(".", .{});
    defer iterable_dir.close();

    var files = try EntryList.initCapacity(allocator, 1024);
    defer files.deinit();

    var it = iterable_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory and !std.mem.startsWith(u8, entry.name, ".")) {
            try self.entries.append(entry.name);
        } else {
            if (!std.mem.startsWith(u8, entry.name, "."))
                try files.append(entry.name);
        }
    }

    self.n_dirs = self.entries.len();

    const last = if (self.entries.indices.getLastOrNull()) |last| last else 0;
    for (files.indices.items) |*idx|
        idx.* += last;

    try self.entries.ensureTotalCapacity(self.entries.names.items.len + files.names.items.len);
    self.entries.names.appendSliceAssumeCapacity(files.names.items);

    // FIXME: This does not apply universally, it may be the case that the amount of
    // end indices is less than the entries. It is safer to append the slice, for
    // now at least.
    // self.entries.indices.appendSliceAssumeCapacity(files.indices.items);

    try self.entries.indices.appendSlice(files.indices.items);

    self.s_win.end = blk: {
        const len = self.entries.len();
        if (len < self.s_win.height) {
            break :blk @intCast(len);
        } else {
            break :blk self.s_win.height;
        }
    };
}

/// Appends all entries of the above directory, returning which entry matches the
/// current working directory
pub fn appendAboveEntries(self: *Self, allocator: Allocator) !void {
    var iterable_dir = try std.fs.cwd().openIterableDir("..", .{});
    defer iterable_dir.close();

    var files = try EntryList.initCapacity(allocator, 1024);
    defer files.deinit();

    var match: ?usize = null;

    var it = iterable_dir.iterate();
    var count: usize = 0;

    while (try it.next()) |entry| {
        if (entry.kind == .directory and !std.mem.startsWith(u8, entry.name, ".")) {
            try self.entries.append(entry.name);
            if (std.mem.eql(u8, std.fs.path.basename(self.cwd), entry.name))
                match = count;

            count += 1;
        } else {
            if (!std.mem.startsWith(u8, entry.name, "."))
                try files.append(entry.name);
        }
    }

    self.n_dirs = self.entries.len();

    const last = if (self.entries.indices.getLastOrNull()) |last| last else 0;
    for (files.indices.items) |*idx|
        idx.* += last;

    try self.entries.ensureTotalCapacity(self.entries.names.items.len + files.names.items.len);
    self.entries.names.appendSliceAssumeCapacity(files.names.items);
    self.entries.indices.appendSliceAssumeCapacity(files.indices.items);

    self.s_win.end = blk: {
        const len = self.entries.len();
        if (len < self.s_win.height) {
            break :blk @intCast(len);
        } else {
            break :blk self.s_win.height;
        }
    };

    if (match) |index|
        self.cursor = @intCast(index)
    else
        return error.NoMatchingDirFound;
}
