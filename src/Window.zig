start: usize,
len: usize,

const Window = @This();

pub fn scroll(self: *Window, cursor: usize) void {
    if (cursor < self.start)
        self.start = cursor
    else if (cursor > self.start + self.len -| 1)
        self.start = cursor - (self.len -| 1);
}

pub fn reset(self: *Window) void {
    self.start = 0;
}
