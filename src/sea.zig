const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

cursor: usize,
render_idx: usize,
term_height: u16,
str_arena: *std.heap.ArenaAllocator,
names: std.ArrayList([]const u8),
selection: std.ArrayList(bool),
n_selected: usize,
n_dirs: usize,
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
        // 0x1b is the escape character in terminals
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

pub fn init(arena: *std.heap.ArenaAllocator, cold_alloc: Allocator, stdin: std.fs.File) !Self {
    var original_termios = try std.os.tcgetattr(stdin.handle);

    var new = original_termios;
    new.iflag &= ~(linux.BRKINT | linux.ICRNL | linux.INPCK | linux.ISTRIP | linux.IXON);
    new.oflag &= ~(linux.OPOST);
    new.cflag |= (linux.CS8);
    new.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN | linux.ISIG);
    try std.os.tcsetattr(stdin.handle, .FLUSH, new);

    return .{
        .cursor = 0,
        .render_idx = 0,
        .term_height = try getTerminalHeight(stdin.handle) - 7,
        .cwd = undefined,
        .original_termios = original_termios,
        .str_arena = arena,
        .names = try std.ArrayList([]const u8).initCapacity(cold_alloc, 1024),
        .selection = try std.ArrayList(bool).initCapacity(cold_alloc, 1024),
        .n_selected = 0,
        .n_dirs = undefined,
    };
}

pub fn deinit(self: *Self, stdin: std.fs.File) void {
    std.os.tcsetattr(stdin.handle, .FLUSH, self.original_termios) catch |err| {
        std.log.err("unexpected error at shutdown: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    // self.entries.deinit();
    self.names.deinit();
    self.selection.deinit();
}

fn getTerminalHeight(handle: std.os.fd_t) !u16 {
    var size: linux.winsize = undefined;
    // TODO: Handle error with errno
    if (linux.ioctl(handle, linux.T.IOCGWINSZ, @intFromPtr(&size)) != 0)
        return error.IoctlError;

    return size.ws_row;
}

pub fn printStatus(self: Self, writer: anytype, past_selected: usize) !void {
    try writer.print("\x1B[34m{s}\x1B[0m\x1B[1E", .{self.cwd});

    const entries_len = self.names.items.len;
    try writer.print("{} / {}", .{ self.cursor + 1, entries_len });

    const total_selected = self.n_selected + past_selected;
    if (total_selected != 0)
        try writer.print("  \x1B[1;30;42m {} ", .{total_selected});

    try writer.writeAll("\x1B[2E");
}

pub fn printEntries(self: Self, writer: anytype) !void {
    const start = self.render_idx;
    const height = self.term_height;
    // NOTE: Verify this math is correct
    const len = if (height > self.names.items.len - start)
        self.names.items.len
    else
        height;

    for (
        self.names.items[start..][0..len],
        self.selection.items[start..][0..len],
        start..,
    ) |name, bool_item, n_entry| {
        if (bool_item)
            try writer.writeAll("\x1B[30;42m>\x1B[0m")
        else
            try writer.writeAll("\x1B[0m ");

        if (n_entry < self.n_dirs)
            try writer.writeAll("\x1B[1;34;49m");

        if (n_entry == self.cursor)
            try writer.writeAll("\x1B[7m");

        try writer.writeAll(name);

        try writer.writeAll("\x1B[0m\x1B[1E");
    }
}

pub fn clearEntries(self: *Self) void {
    self.names.clearRetainingCapacity();
}

pub const PastDir = struct {
    idxs: []const u32,
    names: []const u8,
};

fn moveCursorPos(self: Self, offset: i32, clamp: bool) usize {
    const abs: usize = std.math.absCast(offset);
    const new_pos = blk: {
        if (offset < 0) {
            break :blk if (clamp)
                self.cursor -| abs
            else
                std.math.sub(usize, self.cursor, abs) catch self.names.items.len -| 1;
        } else {
            if (self.cursor + abs > self.names.items.len - 1)
                break :blk if (clamp) self.names.items.len - 1 else 0
            else
                break :blk self.cursor + abs;
        }
    };
    return new_pos;
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

            _ = self.str_arena.reset(.retain_capacity);
            self.clearEntries();
            self.appendAboveEntries() catch |err| switch (err) {
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

        .down => self.cursor = self.moveCursorPos(1, false),

        .up => self.cursor = self.moveCursorPos(-1, false),

        .right => {
            if (self.cursor > self.n_dirs) return;

            const name = self.names.items[@intCast(self.cursor)];
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
            // FixedBufferStream
            const path = try std.process.getCwd(buffer);
            self.cwd = path;

            _ = self.str_arena.reset(.retain_capacity);
            self.clearEntries();
            try self.indexFilesCwd();

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

        .bottom => self.cursor = @intCast(self.names.items.len - 1),

        // Selections
        .select_entry => {
            if (self.names.items.len == 0) return;
            const casted: usize = @intCast(self.cursor);
            self.selection.items[casted] = !self.selection.items[casted];
            if (self.selection.items[casted])
                self.n_selected += 1
            else
                self.n_selected -= 1;
            self.cursor = self.moveCursorPos(1, true);
        },

        .select_all => {
            for (self.selection.items) |*item|
                item.* = true;

            self.n_selected = self.names.items.len;
        },

        .select_invert => {
            for (self.selection.items) |*item|
                item.* = !item.*;

            self.n_selected = self.names.items.len - self.n_selected;
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

                // NOTE: Have to delete each entry as it is iterated over,
                // otherwise this is a memory leak. This could be handled by an
                // arena but it would mean piling up memory when a single entry
                // is removed from the hashmap when moving left or right.

                hash_map.allocator.free(entry.key_ptr.*);
                hash_map.allocator.free(entry.value_ptr.idxs);
                hash_map.allocator.free(entry.value_ptr.names);
            }
            hash_map.clearRetainingCapacity();

            // TODO: Make this a function
            // Iterate on current directory selection
            fbs.reset();

            if (self.n_selected == 0) return;

            try fbs_writer.writeAll(self.cwd);
            try fbs_writer.writeByte('/');
            const write_pos = try fbs.getPos();

            var new_list = try std.ArrayList([]const u8).initCapacity(allocator, self.names.items.len);
            for (self.selection.items, 0..) |selected, idx| {
                if (!selected) {
                    new_list.appendAssumeCapacity(self.names.items[idx]);
                    continue;
                }

                try fbs.seekTo(write_pos);
                try fbs_writer.writeAll(self.names.items[idx]);
                try std.fs.deleteTreeAbsolute(fbs.getWritten());
            }

            self.names.deinit();
            const slice = try new_list.toOwnedSlice();
            self.names = std.ArrayList([]const u8).fromOwnedSlice(allocator, slice);

            try self.resetSelectionAndResize();
            self.resetSelection();
            self.cursor = std.math.clamp(
                self.cursor,
                0,
                self.names.items.len -| 1,
            );
            self.n_selected = 0;

        },
        .move => {},
        .paste => {},
    }

    if (self.cursor >= self.render_idx + self.term_height)
        self.render_idx = @as(usize, @intCast(self.cursor)) - self.term_height + 1
    else if (self.cursor < self.render_idx)
        self.render_idx = @as(usize, @intCast(self.cursor));
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
            try names.appendSlice(self.names.items[idx]);
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
    try self.selection.resize(self.names.items.len);
    for (self.selection.items) |*item|
        item.* = false;
}

pub fn indexFilesCwd(self: *Self) !void {
    var iterable_dir = try std.fs.cwd().openIterableDir(".", .{});
    defer iterable_dir.close();

    const arena_alloc = self.str_arena.allocator();

    var files = try std.ArrayList([]const u8).initCapacity(arena_alloc, 1024);
    defer files.deinit();

    var it = iterable_dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".")) continue;

        const mem = try arena_alloc.dupe(u8, entry.name);
        if (entry.kind == .directory) {
            try self.names.append(mem);
        } else {
            try files.append(mem);
        }
    }

    self.n_dirs = self.names.items.len;

    try self.names.ensureTotalCapacity(self.names.items.len + files.items.len);
    self.names.appendSliceAssumeCapacity(files.items);
}

/// Appends all entries of the above directory, returning which entry matches the
/// current working directory
pub fn appendAboveEntries(self: *Self) !void {
    var iterable_dir = try std.fs.cwd().openIterableDir("..", .{});
    defer iterable_dir.close();

    const arena_alloc = self.str_arena.allocator();

    var files = try std.ArrayList([]const u8).initCapacity(arena_alloc, 1024);
    defer files.deinit();

    var match: ?usize = null;

    var it = iterable_dir.iterate();
    var count: usize = 0;

    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".")) continue;

        const mem = try arena_alloc.dupe(u8, entry.name);
        if (entry.kind == .directory) {
            try self.names.append(mem);
            if (std.mem.eql(u8, std.fs.path.basename(self.cwd), entry.name))
                match = count;

            count += 1;
        } else {
            try files.append(mem);
        }
    }

    self.n_dirs = self.names.items.len;

    try self.names.ensureTotalCapacity(self.names.items.len + files.items.len);
    self.names.appendSliceAssumeCapacity(files.items);

    if (match) |index|
        self.cursor = @intCast(index)
    else
        return error.NoMatchingDirFound;
}
