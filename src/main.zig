const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Tracker = struct {
    file: std.fs.File,
    next_id: u64,
    last_release_ns: ?i128,
    down_ts: ?i128,
    down_interval: ?f64,
    down_injected: bool,
    epoch_offset_ns: i128,

    pub fn init(path: []const u8) !Tracker {
        const mono = std.time.nanoTimestamp();
        const epoch_ms = std.time.milliTimestamp();
        const epoch_offset = @as(i128, epoch_ms) * 1_000_000 - mono;

        const file = try std.fs.cwd().createFile(path, .{});
        errdefer file.close();
        try file.writeAll("id,timestamp_ms,hold_time_ms,interval_ms,injected\n");

        return .{
            .file = file,
            .next_id = 1,
            .last_release_ns = null,
            .down_ts = null,
            .down_interval = null,
            .down_injected = false,
            .epoch_offset_ns = epoch_offset,
        };
    }

    pub fn onDown(self: *Tracker, ts_ns: i128, injected: bool) void {
        self.down_ts = ts_ns;
        self.down_injected = injected;
        self.down_interval = if (self.last_release_ns) |lr| nsToMs(ts_ns - lr) else null;
    }

    pub fn onUp(self: *Tracker, ts_ns: i128, injected: bool) void {
        const press_ts = self.down_ts orelse return;
        const hold_ms = nsToMs(ts_ns - press_ts);
        const epoch_ns = press_ts + self.epoch_offset_ns;
        const ts_ms = nsToMs(epoch_ns);
        const interval = self.down_interval;
        // Flag as injected if either press or release was injected
        const was_injected = self.down_injected or injected;

        var buf: [256]u8 = undefined;
        const inj_str: []const u8 = if (was_injected) "true" else "false";
        const line = if (interval) |iv|
            std.fmt.bufPrint(&buf, "{d},{d:.6},{d:.3},{d:.3},{s}\n", .{ self.next_id, ts_ms, hold_ms, iv, inj_str }) catch return
        else
            std.fmt.bufPrint(&buf, "{d},{d:.6},{d:.3},,{s}\n", .{ self.next_id, ts_ms, hold_ms, inj_str }) catch return;

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

export fn on_mouse_event(button: u8, is_down: c_int, injected: c_int, userdata: ?*anyopaque) callconv(.c) void {
    if (button != 0) return;
    const ts = std.time.nanoTimestamp();
    const tracker: *Tracker = @ptrCast(@alignCast(userdata.?));
    const inj = injected != 0;
    if (is_down != 0) tracker.onDown(ts, inj) else tracker.onUp(ts, inj);
}

const linux_impl = if (builtin.os.tag == .linux) struct {
    const EV_KEY: u16 = 0x01;
    const BTN_LEFT: u16 = 0x110;

    const InputEvent = extern struct {
        tv_sec: isize,
        tv_usec: isize,
        type: u16,
        code: u16,
        value: i32,
    };

    fn findMouseDevice(allocator: std.mem.Allocator) !?[]const u8 {
        var dir = std.fs.openDirAbsolute("/dev/input", .{ .iterate = true }) catch return null;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "event")) continue;
            const path = try std.fmt.allocPrint(allocator, "/dev/input/{s}", .{entry.name});

            const fd = posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch {
                allocator.free(path);
                continue;
            };

            // EVIOCGBIT(EV_KEY, 96)
            var key_bits: [96]u8 = std.mem.zeroes([96]u8);
            const EVIOCGBIT_KEY: u32 = 0x80604521;
            const rc = std.os.linux.ioctl(fd, EVIOCGBIT_KEY, @intFromPtr(&key_bits));
            if (rc == 0 or @as(isize, @bitCast(rc)) < 0) {
                posix.close(fd);
                allocator.free(path);
                continue;
            }

            const byte_idx = BTN_LEFT / 8;
            const bit_idx: u3 = @intCast(BTN_LEFT % 8);
            if (key_bits[byte_idx] & (@as(u8, 1) << bit_idx) != 0) {
                posix.close(fd);
                return path;
            }

            posix.close(fd);
            allocator.free(path);
        }
        return null;
    }

    // evdev only receives events from physical hardware — injected clicks
    // via X11/Wayland don't appear here, so injected is always false.
    pub fn run(tracker: *Tracker, device_path: ?[]const u8, allocator: std.mem.Allocator) !void {
        const path = device_path orelse try findMouseDevice(allocator) orelse {
            std.debug.print("Error: no mouse device found. Try running as root or specify a device.\n", .{});
            std.debug.print("Usage: clicktrack [/dev/input/eventN]\n", .{});
            return;
        };
        defer if (device_path == null) allocator.free(path);

        std.debug.print("Listening on {s} ...\n", .{path});

        const fd = try posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
        defer posix.close(fd);

        const ev_size = @sizeOf(InputEvent);
        var read_buf: [ev_size * 64]u8 align(@alignOf(InputEvent)) = undefined;

        while (true) {
            const n = posix.read(fd, &read_buf) catch |err| {
                if (err == error.Interrupted) continue;
                return err;
            };
            if (n == 0) break;

            var offset: usize = 0;
            while (offset + ev_size <= n) : (offset += ev_size) {
                const ev: *const InputEvent = @ptrCast(@alignCast(read_buf[offset..][0..ev_size]));
                if (ev.type != EV_KEY or ev.code != BTN_LEFT) continue;
                if (ev.value == 2) continue;
                const ts = std.time.nanoTimestamp();
                if (ev.value == 1) tracker.onDown(ts, false) else tracker.onUp(ts, false);
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
