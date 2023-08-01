const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const Sea = @import("sea.zig");
const Event = Sea.Event;
const PastDir = Sea.PastDir;

pub fn main() !void {
    const stdout_file = std.io.getStdOut();

    // FIXME: This errors out when using a pipe, which it should not since we are
    // using the alternative buffer.
    const config = std.io.tty.detectConfig(stdout_file);
    if (config == .no_color) {
        std.log.err("your terminal does not support ANSI escape code sequences", .{});
        std.process.exit(1);
    }

    // Enable alternative buffer
    try stdout_file.writeAll("\x1B[?1049h");

    var bw = std.io.bufferedWriter(stdout_file.writer());
    const stdout = bw.writer();

    // Cold allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin_file = std.io.getStdIn();
    const stdin = stdin_file.reader();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var sea = try Sea.init(allocator, stdin_file);
    defer sea.deinit(stdin_file);

    try sea.indexFilesCwd(allocator);
    try sea.resetSelectionAndResize();

    try stdout.writeAll("\x1B[?25l");

    // This buffer stays alive the whole program
    var cwd_buffer: [4096]u8 = undefined;
    sea.cwd = try std.process.getCwd(&cwd_buffer);

    // Setup cd on quit if available
    var cd_quit: ?[]const u8 = null;
    defer if (cd_quit) |allocation| allocator.free(allocation);

    if (std.process.hasEnvVarConstant("SEA_TMPFILE"))
        cd_quit = try std.process.getEnvVarOwned(allocator, "SEA_TMPFILE");

    var past_dirs = std.StringArrayHashMap(PastDir).init(allocator);
    defer {
        var it = past_dirs.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.idxs);
            allocator.free(entry.value_ptr.names);
        }
        past_dirs.deinit();
    }

    // Main loop
    var running = true;
    var input: [3]u8 = .{ 0, 0, 0 };
    while (running) : (_ = try stdin.read(&input)) {
        var timer = try std.time.Timer.start();

        const event = Event.fromInput(input);
        try sea.handleEvent(allocator, event, &running, &past_dirs, &cwd_buffer);
        if (!running) break;

        const end = timer.read();

        // Reset colors, clear screen, and go to top left corner
        try stdout.writeAll("\x1B[0m\x1B[2J\x1B[H");

        // Debug info
        if (builtin.mode == .Debug) {
            try stdout.print("Loop time: {}\x1B[1E", .{std.fmt.fmtDuration(end)});
            try stdout.print("Memory allocated: {d:.1}\x1B[1E", .{
                std.fmt.fmtIntSizeDec(sea.entries.names.allocatedSlice().len +
                    sea.entries.indices.allocatedSlice().len +
                    sea.selection.items.len),
            });
            try stdout.print("Terminal size: {} rows\x1B[1E", .{sea.s_win.height});
            try stdout.print("Scroll window: {}\x1B[1E", .{sea.s_win});
            try stdout.print("Cursor selection index: {}\x1B[1E", .{sea.cursor});
        }

        try sea.printStatus(stdout, blk: {
            var total: usize = 0;
            for (past_dirs.values()) |value|
                total += value.idxs.len;

            break :blk total;
        });

        try sea.printEntries(stdout);

        try bw.flush();
    }

    // Reset colors, clear screen, go home, and enable cursor again
    try stdout_file.writeAll("\x1B[0m\x1B[?25h");

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
        try file.writer().print("cd {s}", .{sea.cwd});
    }

    // Disable alternative buffer
    try stdout_file.writeAll("\x1B[?1049l");
}
