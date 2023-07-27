const std = @import("std");
const linux = std.os.linux;
const EntryList = @import("entry_list.zig");
const Allocator = std.mem.Allocator;

stdin: std.fs.File,
entries: EntryList,
selection: std.ArrayList(bool),
n_dirs: usize,
cursor: usize,

/// Scroll window for smooth scrolling and rendering
s_win: struct {
    height: u32,
    end: u32,
},
running: bool,
cwd: []const u8,
original_termios: std.os.termios,

const Self = @This();

pub fn init(allocator: Allocator, stdin: std.fs.File) !Self {
    var original_termios = try std.os.tcgetattr(stdin.handle);

    var new = original_termios;
    new.iflag &= ~(linux.BRKINT | linux.ICRNL | linux.INPCK | linux.ISTRIP | linux.IXON);
    new.oflag &= ~(linux.OPOST);
    new.cflag |= (linux.CS8);
    new.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN | linux.ISIG);
    try std.os.tcsetattr(stdin.handle, .FLUSH, new);

    return .{
        .stdin = stdin,
        .cursor = 0,
        .running = true,
        .cwd = undefined,
        .original_termios = original_termios,
        .s_win = .{
            .height = try getTerminalSize(stdin.handle) - 7,
            .end = 0,
        },
        .entries = try EntryList.initCapacity(allocator, 2048),
        .selection = try std.ArrayList(bool).initCapacity(allocator, 1024),
        .n_dirs = undefined,
    };
}

pub fn deinit(self: *Self) void {
    std.os.tcsetattr(self.stdin.handle, .FLUSH, self.original_termios) catch |err| {
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

pub fn printEntries(self: Self, writer: anytype) !void {
    const height = if (self.s_win.height > self.entries.len())
        self.entries.len()
    else
        self.s_win.height;
    const end = self.s_win.end;

    for (self.entries.getIndices()[end - height ..][0..height], end - height..) |_, n_entry| {
        const under_cursor = n_entry == self.cursor;
        const style = blk: {
            if (n_entry < self.n_dirs) {
                break :blk if (under_cursor)
                    "\x1B[30;44m"
                else
                    "\x1B[1;34;49m";
            } else {
                break :blk if (under_cursor)
                    "\x1B[30;47m"
                else
                    "\x1B[0m";
            }
        };

        try writer.writeAll(style);

        if (self.selection.items[n_entry])
            try writer.writeAll("> ");

        try writer.print("{s}\x1B[1E", .{self.entries.getNameAtEntryIndex(n_entry)});
    }

    try writer.writeAll("\x1B[0m");
}

pub fn clearEntries(self: *Self) void {
    self.entries.names.clearRetainingCapacity();
    self.entries.indices.clearRetainingCapacity();
}

pub fn handleInput(
    self: *Self,
    allocator: Allocator,
    stdin: anytype,
    input: u8,
    buffer: []u8,
) !void {
    const len = self.entries.len();
    const total_index = if (len != 0) len - 1 else 0;

    const Key = enum(u8) {
        ignore = 0,
        q = 'q',
        h = 'h',
        j = 'j',
        k = 'k',
        l = 'l',
        g = 'g',
        G = 'G',
        a = 'a',
        A = 'A',
        space = ' ',
        // arrow_up = 0x41,
        // arrow_down = 0x42,
        // arrow_right = 0x43,
        // arrow_left = 0x44,
    };

    const real_input = if (input == 0x1b and (try stdin.readByte() == 0x5b))
        try std.meta.intToEnum(Key, try stdin.readByte())
    else
        std.meta.intToEnum(Key, input) catch .ignore;

    switch (real_input) {
        .ignore => {},
        .q => self.running = false,
        .h => {
            self.clearEntries();
            self.cursor = self.appendAboveEntries(allocator) catch |err| if (err == error.NoMatchingDirFound)
                self.cursor
            else
                return err;

            try std.process.changeCurDir("..");

            const path = try std.process.getCwd(buffer);
            self.cwd = path;

            try self.resetSelectionAndResize(self.entries.len());
        },
        .j => self.cursor = if (self.cursor != total_index)
            self.cursor + 1
        else
            0,
        .k => {
            self.cursor = if (self.cursor != 0)
                self.cursor - 1
            else
                total_index;
        },
        .l => {
            if (self.cursor < self.n_dirs) {
                const name = self.entries.getNameAtEntryIndex(self.cursor);
                self.cursor = 0;

                try std.process.changeCurDir(name);
                const path = try std.process.getCwd(buffer);
                self.cwd = path;

                self.clearEntries();
                try self.appendCwdEntries(allocator);

                try self.resetSelectionAndResize(self.entries.len());
            }
        },
        .g => self.cursor = 0,
        .G => self.cursor = total_index,
        .space => {
            self.selection.items[self.cursor] = !self.selection.items[self.cursor];
        },
        .a => for (self.selection.items) |*item| {
            item.* = true;
        },
        .A => for (self.selection.items) |*item| {
            item.* = !item.*;
        },
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

pub fn resetSelectionAndResize(self: *Self, new_size: usize) !void {
    try self.selection.resize(new_size);
    for (self.selection.items) |*item|
        item.* = false;
}

pub fn appendCwdEntries(self: *Self, allocator: Allocator) !void {
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
    self.entries.indices.appendSliceAssumeCapacity(files.indices.items);

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
pub fn appendAboveEntries(self: *Self, allocator: Allocator) !usize {
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
        return index
    else
        return error.NoMatchingDirFound;
}
