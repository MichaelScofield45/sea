const std = @import("std");
const linux = std.os.linux;
const Sea = @import("sea.zig");

pub fn main() !void {
    const stdout_file = std.io.getStdOut();
    const config = std.io.tty.detectConfig(stdout_file);
    if (config == .no_color) {
        std.log.err("your terminal does not support ANSI escape code sequences", .{});
        std.process.exit(1);
    }

    var bw = std.io.bufferedWriter(stdout_file.writer());
    const stdout = bw.writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin_file = std.io.getStdIn();
    const stdin = stdin_file.reader();

    var sea = try Sea.init(allocator, stdin_file);
    defer sea.deinit();

    try sea.appendCwdEntries(allocator);

    var input_char: u8 = 0;
    try stdout.writeAll("\x1B[?25l");

    var cwd_buffer: [4096]u8 = undefined;
    const cwd_path = try std.process.getCwd(&cwd_buffer);
    sea.cwd_name = std.fs.path.basename(cwd_path);

    // Setup cd on quit if available
    var cd_quit: ?[]const u8 = null;
    defer if (cd_quit) |allocation| allocator.free(allocation);

    if (std.process.hasEnvVarConstant("SEA_TMPFILE"))
        cd_quit = try std.process.getEnvVarOwned(allocator, "SEA_TMPFILE");

    // Main loop
    while (sea.running) : (input_char = try stdin.readByte()) {
        var timer = try std.time.Timer.start();

        try sea.handleInput(allocator, input_char, &cwd_buffer);
        if (!sea.running) break;

        const end = timer.read();

        // Reset colors and clear screen
        try stdout.writeAll("\x1B[0m\x1B[2J\x1B[H");

        try stdout.print("Loop time: {}\x1B[1E", .{std.fmt.fmtDuration(end)});
        try stdout.print("Memory allocated: {d:.1}\x1B[1E", .{
            std.fmt.fmtIntSizeDec(sea.entries.names.allocatedSlice().len +
                sea.entries.indices.allocatedSlice().len),
        });
        try stdout.print("Terminal size: {} rows\x1B[1E", .{sea.s_win.height});
        try stdout.print("Scroll window: {}\x1B[1E", .{sea.s_win});
        try stdout.print("Cursor selection index: {}\x1B[2E", .{sea.cursor});

        try sea.printEntries(stdout);

        try bw.flush();
    }

    // Reset colors, clear screen, go home, and enable cursor again
    try stdout_file.writeAll("\x1B[0m\x1B[2J\x1B[H\x1B[?25h");

    if (cd_quit) |lastd_file| {
        const dirname = std.fs.path.dirname(lastd_file) orelse {
            std.log.err("could not get config directory for cd on quit, given" ++
                "directory is: {s}", .{lastd_file});
            std.process.exit(1);
        };

        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();

        try root.makePath(dirname);

        const file = try std.fs.createFileAbsolute(lastd_file, .{});
        defer file.close();
        try file.writer().print("cd {s}", .{try std.process.getCwd(&cwd_buffer)});
    }
}
