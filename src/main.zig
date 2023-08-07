const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const page_allocator = std.heap.page_allocator;

pub const PastDir = struct {
    sels: []const bool,
    names: []const u8,
};

pub const Action = enum {
    quit,
    left,
    down,
    up,
    right,
    top,
    bottom,
    select_toggle,
    select_all,
    select_invert,
    delete,
    move,
    paste,
    hidden_toggle,

    pub fn fromInput(input: [3]u8) ?Action {
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

            ' ' => .select_toggle,
            'a' => .select_all,
            'A' => .select_invert,

            'd' => .delete,
            'v' => .move,
            'p' => .paste,

            '.' => .hidden_toggle,

            else => null,
        };
    }
};

const Entry = struct {
    name: []const u8,
    sel: bool,
    ft: enum(u8) {
        dir,
        file,
        symlink,
    },
};

const ScrollWin = struct {
    top: usize,
    max_lines: usize,

    fn scroll(self: *ScrollWin, cursor_pos: usize) void {
        if (cursor_pos > self.top)
            self.top += 1
        else if (cursor_pos < self.top)
            self.top -= 1;
    }
};

const EntryList = std.MultiArrayList(Entry);

pub fn main() !void {
    const stdout_f = std.io.getStdOut();

    // Enable alternative buffer
    try stdout_f.writeAll("\x1B[?1049h");

    var bw = std.io.bufferedWriter(stdout_f.writer());
    const stdout = bw.writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_alloc = gpa.allocator();

    const stdin_f = std.io.getStdIn();
    const stdin = stdin_f.reader();

    const original_termios = try std.os.tcgetattr(stdin_f.handle);
    defer std.os.tcsetattr(stdin_f.handle, .FLUSH, original_termios) catch unreachable;

    {
        var new = original_termios;
        new.iflag &= ~(linux.BRKINT | linux.ICRNL | linux.INPCK | linux.ISTRIP | linux.IXON);
        new.oflag &= ~(linux.OPOST);
        new.cflag |= (linux.CS8);
        new.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN | linux.ISIG);
        try std.os.tcsetattr(stdin_f.handle, .FLUSH, new);
    }

    var arena_instance = std.heap.ArenaAllocator.init(page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    try stdout.writeAll("\x1B[?25l");

    var cwd = try std.process.getCwdAlloc(arena);

    // Setup cd on quit if available
    var cd_quit: ?[]const u8 = null;
    defer if (cd_quit) |allocation| gpa_alloc.free(allocation);

    if (std.process.hasEnvVarConstant("SEA_TMPFILE"))
        cd_quit = try std.process.getEnvVarOwned(gpa_alloc, "SEA_TMPFILE");

    var past_dirs = std.StringArrayHashMap(PastDir).init(gpa_alloc);
    defer {
        var it = past_dirs.iterator();
        while (it.next()) |entry| {
            gpa_alloc.free(entry.key_ptr.*);
            gpa_alloc.free(entry.value_ptr.sels);
            gpa_alloc.free(entry.value_ptr.names);
        }
        past_dirs.deinit();
    }

    var files = EntryList{};
    defer files.deinit(gpa_alloc);
    var files_len: usize = 0;
    var show_hidden = false;

    {
        var dir = try std.fs.cwd().openIterableDir(".", .{});
        defer dir.close();

        files_len = try iterateDirAndIndex(
            dir,
            &files,
            gpa_alloc,
            arena,
            show_hidden,
        );
    }

    var running = true;
    var input: [3]u8 = .{ 0, 0, 0 };
    var cursor: usize = 0;
    var win = ScrollWin{
        .top = 0,
        .max_lines = 35,
    };

    // Main loop
    while (running) : (_ = try stdin.read(&input)) {
        var timer = try std.time.Timer.start();

        const event_opt = Action.fromInput(input);
        if (event_opt) |event| switch (event) {
            .quit => running = false,
            .top => cursor = 0,
            .bottom => cursor = files_len - 1,
            // .left => {},
            .left => {
                try std.process.changeCurDir("..");
                // FIXME: Something here does not work
                try past_dirs.put(
                    try gpa_alloc.dupe(u8, cwd),
                    blk: {
                        const slice = files.slice();
                        const names = slice.items(.name);
                        const sels = slice.items(.sel);

                        break :blk .{
                            .sels = try gpa_alloc.dupe(bool, sels),
                            .names = brk: {
                                var list = std.ArrayList(u8).init(gpa_alloc);
                                for (names) |name| {
                                    try list.appendSlice(name);
                                    try list.append(0);
                                }
                                _ = list.popOrNull();
                                break :brk try list.toOwnedSlice();
                            },
                        };
                    },
                );

                std.debug.assert(arena_instance.reset(.retain_capacity));
                files.shrinkRetainingCapacity(0);

                cwd = try std.process.getCwdAlloc(arena);
                const dir = try std.fs.cwd().openIterableDir(".", .{});
                files_len = try iterateDirAndIndex(
                    dir,
                    &files,
                    gpa_alloc,
                    arena,
                    show_hidden,
                );

                if (past_dirs.get(std.fs.path.basename(cwd))) |past_dir| {
                    for (past_dir.sels, files.items(.sel)) |past_sel, *curr_sel|
                        curr_sel.* = past_sel;

                    // gpa_alloc.free()
                }
            },

            .down, .up => |direction| moveCursor(&cursor, direction, files_len),
            .right => {},

            .select_toggle => {
                const selection = files.items(.sel);
                selection[cursor] = !selection[cursor];
            },

            .select_all => {
                const selection = files.items(.sel);
                for (selection) |*sel_item| sel_item.* = true;
            },

            .select_invert => {
                const selection = files.items(.sel);
                for (selection) |*sel_item| sel_item.* = !sel_item.*;
            },

            .delete => {},
            .move => {},
            .paste => {},

            .hidden_toggle => show_hidden = !show_hidden,
        };

        scroll(&win, cursor);
        if (!running) break;

        const end = timer.read();

        // Clear screen, and go to top left corner
        try stdout.writeAll("\x1B[2J\x1B[H");

        if (true or builtin.mode == .Debug) {
            try stdout.print("Loop time: {}\x1B[1E", .{std.fmt.fmtDuration(end)});
            try stdout.print("Arena memory allocated: {d:.1}\x1B[1E", .{
                std.fmt.fmtIntSizeDec(arena_instance.queryCapacity()),
            });
            try stdout.print("Cursor selection index: {}\x1B[1E", .{cursor});
            try stdout.print("Scroll window: {}\x1B[1E", .{win});
        }

        // TODO: Print total selected
        try stdout.print(
            "{s}\x1B[1E" ++ "{} / {}\x1B[2E",
            .{ cwd, cursor + 1, files_len },
        );

        try printEntries(stdout, files, files_len, cursor, win);
        try bw.flush();
    }

    // Reset colors, clear screen, go home, and enable cursor again
    try stdout_f.writeAll("\x1B[0m\x1B[?25h");

    if (cd_quit) |lastd_path| {
        const dirname = std.fs.path.dirname(lastd_path) orelse {
            std.log.err("could not get config directory for cd on quit, given" ++
                "directory was: {s}", .{lastd_path});
            std.process.exit(1);
        };

        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();

        try root.makePath(dirname);

        const file = try std.fs.createFileAbsolute(lastd_path, .{});
        defer file.close();
        try file.writer().print("cd {s}", .{cwd});
    }

    // Disable alternative buffer
    try stdout_f.writeAll("\x1B[?1049l");
}

fn moveCursor(cursor: *usize, direction: Action, total_items: usize) void {
    const current_pos = cursor.*;
    cursor.* = switch (direction) {
        .up => if (current_pos == 0) total_items - 1 else current_pos - 1,
        .down => if (current_pos == total_items -| 1) 0 else current_pos + 1,
        else => unreachable,
    };
}

fn scroll(win: *ScrollWin, cursor: usize) void {
    const win_end_pos = win.top + win.max_lines;
    if (cursor >= win_end_pos)
        win.top = cursor - win.max_lines + 1
    else if (cursor < win.top)
        win.top = cursor;
}

fn printEntries(
    w: anytype,
    entries: EntryList,
    total: usize,
    cursor: usize,
    win: ScrollWin,
) !void {
    const slice = entries.slice();
    const number_of_lines = std.math.clamp(win.max_lines, 0, total - win.top);
    const names = slice.items(.name)[win.top..][0..number_of_lines];
    const sels = slice.items(.sel)[win.top..][0..number_of_lines];
    const fts = slice.items(.ft)[win.top..][0..number_of_lines];

    const styles_array = [_][]const u8{
        "\x1B[38;5;4m",
        "",
        "\x1B[38;5;14m",
    };

    for (names, sels, fts, win.top..) |name, sel, ft, idx| {
        if (sel)
            try w.writeAll("\x1B[30;42m>\x1B[0m")
        else
            try w.writeByte(' ');

        try w.writeAll(styles_array[@intFromEnum(ft)]);

        if (cursor == idx)
            try w.writeAll("\x1B[7m");

        try w.print("{s}\x1B[0m\x1B[1E", .{name});
    }
}

/// Returns the amount of entries that were iterated over in the diretory.
fn iterateDirAndIndex(
    dir: std.fs.IterableDir,
    entries: *EntryList,
    gpa: Allocator,
    arena: Allocator,
    hidden: bool,
) !usize {
    var it = dir.iterate();

    var total: usize = 0;
    while (try it.next()) |file| {
        if (!hidden and file.name[0] == '.') continue;
        const str_mem = try arena.dupe(u8, file.name);
        try entries.append(gpa, .{
            .name = str_mem,
            .sel = false,
            .ft = switch (file.kind) {
                .directory => .dir,
                .file => .file,
                .sym_link => .symlink,
                else => .file,
            },
        });
        total += 1;
    }

    return total;
}
