const std = @import("std");

const max_reader_queue = 100;

pub const SnapshotSubscription = struct {
    snapshot: []u8,
    reader_id: usize,
};

const Reader = struct {
    id: usize,
    queue: std.array_list.Managed([]u8),

    fn init(allocator: std.mem.Allocator, id: usize) Reader {
        return .{
            .id = id,
            .queue = std.array_list.Managed([]u8).init(allocator),
        };
    }

    fn deinit(self: *Reader) void {
        const allocator = self.queue.allocator;
        for (self.queue.items) |item| allocator.free(item);
        self.queue.deinit();
    }

    fn enqueue(self: *Reader, data: []const u8) void {
        if (self.queue.items.len >= max_reader_queue) return;

        const allocator = self.queue.allocator;
        const owned = allocator.dupe(u8, data) catch return;
        self.queue.append(owned) catch {
            allocator.free(owned);
            return;
        };
    }

    fn readNext(self: *Reader) ?[]u8 {
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }
};

pub const RingBuffer = struct {
    allocator: std.mem.Allocator,
    buf: []u8,
    w: usize = 0,
    full: bool = false,
    mutex: std.Thread.Mutex = .{},
    readers: std.array_list.Managed(Reader),
    next_id: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !RingBuffer {
        if (capacity == 0) return error.InvalidCapacity;
        const buf = try allocator.alloc(u8, capacity);
        errdefer allocator.free(buf);
        return .{
            .allocator = allocator,
            .buf = buf,
            .readers = std.array_list.Managed(Reader).init(allocator),
        };
    }

    pub fn deinit(self: *RingBuffer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.readers.items) |*reader| reader.deinit();
        self.readers.deinit();
        self.allocator.free(self.buf);
        self.buf = &.{};
        self.w = 0;
        self.full = false;
    }

    pub fn write(self: *RingBuffer, data: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (data) |byte| {
            self.buf[self.w] = byte;
            self.w += 1;
            if (self.w >= self.buf.len) {
                self.w = 0;
                self.full = true;
            }
        }

        for (self.readers.items) |*reader| reader.enqueue(data);
        return data.len;
    }

    pub fn bytes(self: *RingBuffer, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.copyBytesLocked(allocator);
    }

    pub fn len(self: *RingBuffer) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.full) return self.buf.len;
        return self.w;
    }

    pub fn cap(self: *RingBuffer) usize {
        return self.buf.len;
    }

    pub fn clear(self: *RingBuffer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.w = 0;
        self.full = false;
    }

    pub fn newReader(self: *RingBuffer) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        self.next_id += 1;
        try self.readers.append(Reader.init(self.allocator, id));
        return id;
    }

    pub fn readNext(self: *RingBuffer, reader_id: usize) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.findReader(reader_id)) |reader| return reader.readNext();
        return null;
    }

    pub fn snapshotAndSubscribe(self: *RingBuffer, allocator: std.mem.Allocator) !SnapshotSubscription {
        self.mutex.lock();
        defer self.mutex.unlock();

        const snapshot = try self.copyBytesLocked(allocator);
        errdefer allocator.free(snapshot);

        const id = self.next_id;
        self.next_id += 1;
        try self.readers.append(Reader.init(self.allocator, id));

        return .{
            .snapshot = snapshot,
            .reader_id = id,
        };
    }

    pub fn removeReader(self: *RingBuffer, reader_id: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.readers.items, 0..) |*reader, index| {
            if (reader.id == reader_id) {
                var removed = self.readers.orderedRemove(index);
                removed.deinit();
                return;
            }
        }
    }

    fn findReader(self: *RingBuffer, reader_id: usize) ?*Reader {
        for (self.readers.items) |*reader| {
            if (reader.id == reader_id) return reader;
        }
        return null;
    }

    fn copyBytesLocked(self: *RingBuffer, allocator: std.mem.Allocator) ![]u8 {
        if (!self.full) return allocator.dupe(u8, self.buf[0..self.w]);

        var out = try allocator.alloc(u8, self.buf.len);
        @memcpy(out[0 .. self.buf.len - self.w], self.buf[self.w..]);
        @memcpy(out[self.buf.len - self.w ..], self.buf[0..self.w]);
        return out;
    }
};

test "ring buffer stores small writes and reports capacity" {
    var rb = try RingBuffer.init(std.testing.allocator, 100);
    defer rb.deinit();

    try std.testing.expectEqual(@as(usize, 100), rb.cap());
    try std.testing.expectEqual(@as(usize, 0), rb.len());
    try std.testing.expectEqual(@as(usize, 11), rb.write("hello world"));
    try std.testing.expectEqual(@as(usize, 11), rb.len());

    const out = try rb.bytes(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello world", out);
}

test "ring buffer keeps only newest data after overflow" {
    var rb = try RingBuffer.init(std.testing.allocator, 10);
    defer rb.deinit();

    _ = rb.write("0123456789abcde");

    const out = try rb.bytes(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("56789abcde", out);
    try std.testing.expectEqual(@as(usize, 10), rb.len());
}

test "ring buffer preserves chronological order across multiple wraps" {
    var rb = try RingBuffer.init(std.testing.allocator, 10);
    defer rb.deinit();

    _ = rb.write("abc");
    _ = rb.write("defg");
    _ = rb.write("hijk");
    _ = rb.write("lmn");

    const out = try rb.bytes(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("efghijklmn", out);
}

test "ring buffer clears and can be reused" {
    var rb = try RingBuffer.init(std.testing.allocator, 10);
    defer rb.deinit();

    _ = rb.write("first");
    rb.clear();
    try std.testing.expectEqual(@as(usize, 0), rb.len());

    _ = rb.write("second");
    const out = try rb.bytes(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("second", out);
}

test "bytes returns a copy" {
    var rb = try RingBuffer.init(std.testing.allocator, 100);
    defer rb.deinit();

    _ = rb.write("original");
    const first = try rb.bytes(std.testing.allocator);
    defer std.testing.allocator.free(first);
    const second = try rb.bytes(std.testing.allocator);
    defer std.testing.allocator.free(second);

    first[0] = 'X';
    try std.testing.expectEqualStrings("original", second);

    const third = try rb.bytes(std.testing.allocator);
    defer std.testing.allocator.free(third);
    try std.testing.expectEqualStrings("original", third);
}

test "readers receive live write copies" {
    var rb = try RingBuffer.init(std.testing.allocator, 100);
    defer rb.deinit();

    const first_id = try rb.newReader();
    const second_id = try rb.newReader();
    try std.testing.expect(first_id != second_id);

    _ = rb.write("broadcast");

    const first = rb.readNext(first_id) orelse return error.ExpectedReaderData;
    defer std.testing.allocator.free(first);
    const second = rb.readNext(second_id) orelse return error.ExpectedReaderData;
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings("broadcast", first);
    try std.testing.expectEqualStrings("broadcast", second);
}

test "snapshot and subscribe captures history and future writes" {
    var rb = try RingBuffer.init(std.testing.allocator, 1024);
    defer rb.deinit();

    _ = rb.write("historical data\n");
    const sub = try rb.snapshotAndSubscribe(std.testing.allocator);
    defer std.testing.allocator.free(sub.snapshot);

    try std.testing.expect(std.mem.indexOf(u8, sub.snapshot, "historical data") != null);

    _ = rb.write("live data\n");
    const live = rb.readNext(sub.reader_id) orelse return error.ExpectedReaderData;
    defer std.testing.allocator.free(live);
    try std.testing.expect(std.mem.indexOf(u8, live, "live data") != null);
}

test "removing reader stops future deliveries" {
    var rb = try RingBuffer.init(std.testing.allocator, 100);
    defer rb.deinit();

    const reader_id = try rb.newReader();
    rb.removeReader(reader_id);
    _ = rb.write("should not be received");

    try std.testing.expect(rb.readNext(reader_id) == null);
}

test "slow readers drop writes after queue capacity" {
    var rb = try RingBuffer.init(std.testing.allocator, 100);
    defer rb.deinit();

    const reader_id = try rb.newReader();
    var i: usize = 0;
    while (i < max_reader_queue + 5) : (i += 1) {
        _ = rb.write("x");
    }

    i = 0;
    while (i < max_reader_queue) : (i += 1) {
        const item = rb.readNext(reader_id) orelse return error.ExpectedReaderData;
        defer std.testing.allocator.free(item);
        try std.testing.expectEqualStrings("x", item);
    }
    try std.testing.expect(rb.readNext(reader_id) == null);
}
