const std = @import("std");
const linux = std.os.linux;
const Sea = @import("sea.zig");

pub fn main() !void {
    const stdout_file = std.io.getStdOut();
    const config = std.io.tty.detectConfig(stdout_file);

    var bw = std.io.bufferedWriter(stdout_file.writer());
    const stdout = bw.writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin_file = std.io.getStdIn();
    const stdin = stdin_file.reader();

    var sea = try Sea.init(allocator, stdin_file);
    defer sea.deinit();

    try sea.appendCwdEntries();

    var input_char: u8 = 0;
    try stdout.writeAll("\x1B[?25l");

    var cwd_buffer: [4096]u8 = undefined;
    const cwd_path = try std.process.getCwd(&cwd_buffer);
    sea.cwd_name = std.fs.path.basename(cwd_path);

    // Main loop
    while (sea.running) : (input_char = try stdin.readByte()) {
        var timer = try std.time.Timer.start();

        try sea.handleInput(input_char, &cwd_buffer);
        if (!sea.running) break;

        const end = timer.read();

        // Reset colors and clear screen
        try stdout.writeAll("\x1B[0m\x1B[2J\x1B[H");

        try stdout.print("Loop time: {}\x1B[1E", .{std.fmt.fmtDuration(end)});
        try stdout.print("Memory allocated: {d:.1}\x1B[1E", .{
            std.fmt.fmtIntSizeDec(sea.dirs.names.allocatedSlice().len +
                sea.dirs.end_indices.allocatedSlice().len +
                sea.files.names.allocatedSlice().len +
                sea.files.end_indices.allocatedSlice().len),
        });

        try stdout.print("Terminal size: {} rows\x1B[1E", .{sea.s_win.height});
        try stdout.print("Scroll window: {}\x1B[1E", .{sea.s_win});

        try stdout.print("Cursor selection index: {}\x1B[2E", .{sea.cursor});

        try config.setColor(stdout, .blue);
        try config.setColor(stdout, .bold);

        // TODO: Handle logic for scrolling
        try sea.printEntries(stdout);

        try bw.flush();
    }

    // Reset colors, clear screen, go home, and enable cursor again
    try stdout_file.writeAll("\x1B[0m\x1B[2J\x1B[H\x1B[?25h");
}
