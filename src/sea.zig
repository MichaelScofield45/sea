const std = @import("std");
const linux = std.os.linux;
const EntryList = @import("entry_list.zig");

stdin: std.fs.File,
dirs: EntryList,
files: EntryList,
cursor: usize,
/// Scroll window for smooth scrolling and rendering
s_win: struct {
    height: u32,
    end: u32,
},
running: bool,
cwd_name: []const u8,
original_termios: std.os.termios,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, stdin: std.fs.File) !Self {
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
        .cwd_name = undefined,
        .original_termios = original_termios,
        .s_win = .{
            .height = try getTerminalSize(stdin.handle) - 7,
            .end = 0,
        },
        .dirs = try EntryList.initCapacity(allocator, 1024),
        .files = try EntryList.initCapacity(allocator, 1024),
    };
}

pub fn deinit(self: *Self) void {
    std.os.tcsetattr(self.stdin.handle, .FLUSH, self.original_termios) catch |err| {
        std.log.err("unexpected error at shutdown: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    self.dirs.deinit();
    self.files.deinit();
}

fn getTerminalSize(stdin_handle: std.os.fd_t) !u32 {
    var size: linux.winsize = undefined;
    // TODO: Handle error with errno
    if (linux.ioctl(stdin_handle, linux.T.IOCGWINSZ, @intFromPtr(&size)) != 0)
        return error.IoctlError;

    return @as(u32, size.ws_row);
}

fn getScrollSlices(self: Self) !struct {
    dirs: ?[]const usize,
    files: ?[]const usize,
    dir_start: usize,
    file_start: usize,
} {
    const items_len = self.dirs.len() + self.files.len();
    const height = if (self.s_win.height > items_len) items_len else self.s_win.height;
    const end = self.s_win.end;

    if (end < self.dirs.len()) {
        return .{
            .dirs = self.dirs.getEndIndices()[end - height .. end],
            .files = null,
            .dir_start = end - height,
            .file_start = 0,
        };
    } else if (end - height > self.dirs.len()) {
        const dir_len = self.dirs.len();
        const start = end - height - dir_len;
        return .{
            .dirs = null,
            .files = self.files.getEndIndices()[start..][0..height],
            .dir_start = 0,
            .file_start = start,
        };
    } else {
        const start = end - height;
        const n_dirs = self.dirs.len() - start;
        const n_files = height - n_dirs;
        std.debug.print("{}, {}, {}\n", .{ start, n_dirs, n_files });

        return .{
            .dirs = self.dirs.getEndIndices()[start..][0..n_dirs],
            .files = self.files.getEndIndices()[0..][0..n_files],
            .dir_start = start,
            .file_start = 0,
        };
    }
}

pub fn printEntries(self: Self, writer: anytype) !void {
    const idxs = try self.getScrollSlices();

    if (idxs.dirs) |dirs| {
        for (dirs, idxs.dir_start..) |_, entry_idx| {
            if (entry_idx == self.cursor)
                try writer.writeAll("\x1B[30;44m")
            else
                try writer.writeAll("\x1B[1;34;49m");

            try writer.print("{s}\x1B[1E", .{self.dirs.getNameAtEntryIndex(entry_idx)});
        }
    }

    try writer.writeAll("\x1B[0m");
    if (idxs.files) |files| {
        for (files, idxs.file_start..) |_, entry_idx| {
            if (entry_idx + self.dirs.len() == self.cursor)
                try writer.writeAll("\x1B[30;47m")
            else
                try writer.writeAll("\x1B[0m");

            try writer.print("{s}\x1B[1E", .{self.files.getNameAtEntryIndex(entry_idx)});
        }
    }
}

pub fn clearEntries(self: *Self) void {
    self.dirs.names.clearRetainingCapacity();
    self.dirs.end_indices.clearRetainingCapacity();
    self.files.names.clearRetainingCapacity();
    self.files.end_indices.clearRetainingCapacity();
}

pub fn handleInput(self: *Self, input: u8, buffer: []u8) !void {
    const total_items = self.dirs.len() + self.files.len();
    const total_items_index = if (total_items != 0) total_items - 1 else 0;

    switch (input) {
        'q' => self.running = false,
        'h' => {
            self.clearEntries();
            self.cursor = try self.appendAboveEntries();
            try std.process.changeCurDir("..");

            const path = try std.process.getCwd(buffer);
            self.cwd_name = std.fs.path.basename(path);
        },
        'j' => self.cursor = if (self.cursor != total_items_index)
            self.cursor + 1
        else
            0,
        'k' => {
            self.cursor = if (self.cursor != 0)
                self.cursor - 1
            else
                total_items_index;
        },
        'l' => {
            if (self.cursor < self.dirs.len()) {
                const name = self.dirs.getNameAtEntryIndex(self.cursor);
                self.cursor = 0;

                try std.process.changeCurDir(name);
                const path = try std.process.getCwd(buffer);
                self.cwd_name = std.fs.path.basename(path);

                self.clearEntries();
                try self.appendCwdEntries();
            }
        },
        'g' => self.cursor = 0,
        'G' => self.cursor = total_items_index,
        else => return,
    }

    const len = self.dirs.len() + self.files.len();
    const relative_height = if (self.s_win.height > len) len else self.s_win.height;

    if (len == 0) return;
    if (self.cursor >= self.s_win.end) {
        self.s_win.end = @intCast(self.cursor + 1);
    } else if (self.cursor < self.s_win.end - relative_height) {
        self.s_win.end = @as(u32, @intCast(self.cursor)) + self.s_win.height;
    }
}

pub fn appendCwdEntries(self: *Self) !void {
    var iterable_dir = try std.fs.cwd().openIterableDir(".", .{});
    defer iterable_dir.close();

    var it = iterable_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory and !std.mem.startsWith(u8, entry.name, ".")) {
            try self.dirs.append(entry.name);
        } else {
            if (!std.mem.startsWith(u8, entry.name, "."))
                try self.files.append(entry.name);
        }
    }

    self.s_win.end = blk: {
        const len = self.dirs.len() + self.files.len();
        if (len < self.s_win.height) {
            break :blk @intCast(len);
        } else {
            break :blk self.s_win.height;
        }
    };
}

/// Appends all entries of the above directory, returning which entry matches the
/// current working directory
pub fn appendAboveEntries(self: *Self) !usize {
    var iterable_dir = try std.fs.cwd().openIterableDir("..", .{});
    defer iterable_dir.close();

    var match: ?usize = null;

    var it = iterable_dir.iterate();
    var count: usize = 0;

    while (try it.next()) |entry| {
        if (entry.kind == .directory and !std.mem.startsWith(u8, entry.name, ".")) {
            try self.dirs.append(entry.name);
            if (std.mem.eql(u8, self.cwd_name, entry.name)) match = count;
            count += 1;
        } else {
            if (!std.mem.startsWith(u8, entry.name, "."))
                try self.files.append(entry.name);
        }
    }

    self.s_win.end = blk: {
        const len = self.dirs.len() + self.files.len();
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
