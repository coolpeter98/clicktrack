const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Tracker = struct {
    file: std.fs.File,
    next_id: u64,
    last_release_ns: ?i128,
    down_ts: ?i128,
    down_interval: ?f64,
    down_device: []const u8,
    epoch_offset_ns: i128,

    pub fn init(path: []const u8) !Tracker {
        const mono = std.time.nanoTimestamp();
        const epoch_ms = std.time.milliTimestamp();
        const epoch_offset = @as(i128, epoch_ms) * 1_000_000 - mono;

        const file = try std.fs.cwd().createFile(path, .{});
        errdefer file.close();
        try file.writeAll("id,timestamp_ms,hold_time_ms,interval_ms,device\n");

        return .{
            .file = file,
            .next_id = 1,
            .last_release_ns = null,
            .down_ts = null,
            .down_interval = null,
            .down_device = "",
            .epoch_offset_ns = epoch_offset,
        };
    }

    pub fn onDown(self: *Tracker, ts_ns: i128, device: []const u8) void {
        self.down_ts = ts_ns;
        self.down_device = device;
        self.down_interval = if (self.last_release_ns) |lr| nsToMs(ts_ns - lr) else null;
    }

    pub fn onUp(self: *Tracker, ts_ns: i128, device: []const u8) void {
        const press_ts = self.down_ts orelse return;
        const hold_ms = nsToMs(ts_ns - press_ts);
        const epoch_ns = press_ts + self.epoch_offset_ns;
        const ts_ms = nsToMs(epoch_ns);
        const interval = self.down_interval;
        const dev = if (self.down_device.len > 0) self.down_device else device;

        var buf: [512]u8 = undefined;
        const line = if (interval) |iv|
            std.fmt.bufPrint(&buf, "{d},{d:.6},{d:.3},{d:.3},{s}\n", .{ self.next_id, ts_ms, hold_ms, iv, dev }) catch return
        else
            std.fmt.bufPrint(&buf, "{d},{d:.6},{d:.3},,{s}\n", .{ self.next_id, ts_ms, hold_ms, dev }) catch return;

        self.file.writeAll(line) catch return;
        self.next_id += 1;
        self.last_release_ns = ts_ns;
        self.down_ts = null;
    }

    pub fn deinit(self: *Tracker) void {
        self.file.close();
    }

    fn nsToMs(ns: i128) f64 {
        const f: f64 = @floatFromInt(ns);
        return f / 1_000_000.0;
    }
};

export fn on_mouse_event(button: u8, is_down: c_int, device: [*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
    if (button != 0) return;
    const ts = std.time.nanoTimestamp();
    const tracker: *Tracker = @ptrCast(@alignCast(userdata.?));
    const dev = std.mem.sliceTo(device, 0);
    if (is_down != 0) tracker.onDown(ts, dev) else tracker.onUp(ts, dev);
}

const linux_impl = if (builtin.os.tag == .linux) struct {
    const EV_KEY: u16 = 0x01;
    const BTN_LEFT: u16 = 0x110;
    const EVIOCGBIT_KEY: u32 = 0x80604521; // EVIOCGBIT(EV_KEY, 96)
    const EVIOCGNAME: u32 = 0x80FF4506;
    const EPOLL_CTL_ADD: u32 = 1;
    const EPOLL_CTL_DEL: u32 = 2;
    const EPOLLIN: u32 = 0x001;

    const InputEvent = extern struct {
        tv_sec: isize,
        tv_usec: isize,
        type: u16,
        code: u16,
        value: i32,
    };

    const Device = struct {
        fd: posix.fd_t,
        name: []const u8,
    };

    fn findMouseDevices(allocator: std.mem.Allocator) ![]Device {
        var list = std.ArrayList(Device){};
        errdefer {
            for (list.items) |d| {
                posix.close(d.fd);
                allocator.free(d.name);
            }
            list.deinit(allocator);
        }

        var dir = std.fs.openDirAbsolute("/dev/input", .{ .iterate = true }) catch return &.{};
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "event")) continue;
            const path = try std.fmt.allocPrint(allocator, "/dev/input/{s}", .{entry.name});
            defer allocator.free(path);

            const fd = posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch continue;

            var key_bits: [96]u8 = std.mem.zeroes([96]u8);
            const key_rc = std.os.linux.ioctl(fd, EVIOCGBIT_KEY, @intFromPtr(&key_bits));
            if (@as(isize, @bitCast(key_rc)) < 0) {
                posix.close(fd);
                continue;
            }
            const byte_idx = BTN_LEFT / 8;
            const bit_idx: u3 = @intCast(BTN_LEFT % 8);
            if (key_bits[byte_idx] & (@as(u8, 1) << bit_idx) == 0) {
                posix.close(fd);
                continue;
            }

            var name_buf: [255]u8 = undefined;
            const name_rc = std.os.linux.ioctl(fd, EVIOCGNAME, @intFromPtr(&name_buf));
            const raw_name: []const u8 = if (@as(isize, @bitCast(name_rc)) >= 0) std.mem.sliceTo(&name_buf, 0) else "unknown";
            const name = try allocator.dupe(u8, raw_name);
            errdefer allocator.free(name);

            try list.append(allocator, .{ .fd = fd, .name = name });
        }

        return list.toOwnedSlice(allocator);
    }

    fn readEvents(buf: []u8, tracker: *Tracker, device_name: []const u8) void {
        const ev_size = @sizeOf(InputEvent);
        var offset: usize = 0;
        while (offset + ev_size <= buf.len) : (offset += ev_size) {
            const ev: *const InputEvent = @ptrCast(@alignCast(buf[offset..][0..ev_size]));
            if (ev.type != EV_KEY or ev.code != BTN_LEFT) continue;
            if (ev.value == 2) continue;
            const ts = std.time.nanoTimestamp();
            if (ev.value == 1) tracker.onDown(ts, device_name) else tracker.onUp(ts, device_name);
        }
    }

    pub fn run(tracker: *Tracker, device_path: ?[]const u8, allocator: std.mem.Allocator) !void {
        if (device_path) |path| {
            const fd = try posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
            defer posix.close(fd);

            var name_buf: [255]u8 = undefined;
            const name_rc = std.os.linux.ioctl(fd, EVIOCGNAME, @intFromPtr(&name_buf));
            const device_name: []const u8 = if (@as(isize, @bitCast(name_rc)) >= 0) std.mem.sliceTo(&name_buf, 0) else "unknown";

            std.debug.print("Listening on {s} ({s}) ...\n", .{ path, device_name });

            const ev_size = @sizeOf(InputEvent);
            var read_buf: [ev_size * 64]u8 align(@alignOf(InputEvent)) = undefined;

            while (true) {
                const n = posix.read(fd, read_buf[0..]) catch |err| {
                    if (err == error.Interrupted) continue;
                    return err;
                };
                if (n == 0) break;
                readEvents(read_buf[0..n], tracker, device_name);
            }
        }

        const devices = try findMouseDevices(allocator);
        defer {
            for (devices) |d| {
                posix.close(d.fd);
                allocator.free(d.name);
            }
            allocator.free(devices);
        }

        if (devices.len == 0) {
            std.debug.print("Error: no mouse device found.\n", .{});
            std.debug.print("Run this command and see if it fixes it (reboot after):\n", .{});
            std.debug.print("\x1b[1msudo usermod -a -G input $USER\x1b[0m\n", .{});
            return;
        }

        for (devices) |d| {
            std.debug.print("Listening on {s}\n", .{d.name});
        }

        const epfd_raw = std.os.linux.epoll_create1(0);
        if (@as(isize, @bitCast(epfd_raw)) < 0) return error.EpollCreateFailed;
        const epfd: i32 = @intCast(epfd_raw);
        defer _ = std.posix.close(@intCast(epfd));

        for (devices) |*d| {
            var ev: std.os.linux.epoll_event = .{
                .events = EPOLLIN,
                .data = .{ .ptr = @intFromPtr(d) },
            };
            if (std.os.linux.epoll_ctl(epfd, EPOLL_CTL_ADD, d.fd, &ev) < 0) {
                return error.EpollCtlFailed;
            }
        }

        const ev_size = @sizeOf(InputEvent);
        var read_buf: [ev_size * 64]u8 align(@alignOf(InputEvent)) = undefined;
        var events: [16]std.os.linux.epoll_event = undefined;

        while (true) {
            const nfds = std.os.linux.epoll_wait(epfd, &events, events.len, -1);
            if (nfds < 0) {
                if (@as(isize, @bitCast(nfds)) == -@as(isize, @intCast(posix.E.INTR))) continue;
                return error.EpollWaitFailed;
            }

            for (events[0..@intCast(nfds)]) |ep_ev| {
                const dev: *Device = @ptrFromInt(ep_ev.data.ptr);

                const n = posix.read(dev.fd, read_buf[0..]) catch |err| {
                    if (err == error.Interrupted) continue;
                    if (err == error.WouldBlock) continue;
                    _ = std.os.linux.epoll_ctl(epfd, EPOLL_CTL_DEL, dev.fd, null);
                    continue;
                };
                if (n == 0) {
                    _ = std.os.linux.epoll_ctl(epfd, EPOLL_CTL_DEL, dev.fd, null);
                    continue;
                }

                readEvents(read_buf[0..n], tracker, dev.name);
            }
        }
    }
} else struct {};

extern fn platform_run_windows(userdata: ?*anyopaque) callconv(.c) c_int;
extern fn platform_run_macos(userdata: ?*anyopaque) callconv(.c) c_int;

fn generateFilename(buf: []u8) ![]const u8 {
    const ts = std.time.milliTimestamp();
    var h: u64 = @bitCast(@as(i64, @intCast(ts)));
    h ^= @bitCast(@as(i64, @truncate(std.time.nanoTimestamp())));
    h ^= h >> 13;
    h *%= 0x2545F4914F6CDD1D;
    h ^= h >> 27;
    return std.fmt.bufPrint(buf, "clicks_{d}_{x:0>8}.csv", .{ ts, @as(u32, @truncate(h)) });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var device_path: ?[]const u8 = null;
    var custom_output: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "/dev/") or std.mem.endsWith(u8, arg, ".csv")) {
            if (std.mem.endsWith(u8, arg, ".csv")) {
                custom_output = arg;
            } else {
                device_path = arg;
            }
        } else {
            if (custom_output == null) custom_output = arg else device_path = arg;
        }
    }

    var name_buf: [128]u8 = undefined;
    const output_path = custom_output orelse try generateFilename(&name_buf);

    var tracker = try Tracker.init(output_path);
    defer tracker.deinit();

    std.debug.print("clicktrack – writing to {s}  (Ctrl+C to stop)\n", .{output_path});

    switch (builtin.os.tag) {
        .windows => {
            const rc = platform_run_windows(@ptrCast(&tracker));
            if (rc != 0) {
                std.debug.print("Windows platform init failed (code {d})\n", .{rc});
                return error.PlatformInit;
            }
        },
        .macos => {
            const rc = platform_run_macos(@ptrCast(&tracker));
            if (rc != 0) {
                std.debug.print("macOS platform init failed. Grant Accessibility permissions.\n", .{});
                return error.PlatformInit;
            }
        },
        .linux => {
            try linux_impl.run(&tracker, device_path, allocator);
        },
        else => @compileError("Unsupported OS. Supported: Windows, macOS, Linux."),
    }
}
