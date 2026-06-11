const std = @import("std");
const installing = @import("installing.zig");

const CliOptions = struct {
    help: bool = false,
    list_only: bool = false,
    assume_yes: bool = false,
    target: ?[]const u8 = null,
};

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn writeErrorJson(writer: anytype, code: []const u8, message: []const u8) !void {
    try writer.writeAll("{\"ok\":false,\"code\":");
    try writeJsonString(writer, code);
    try writer.writeAll(",\"message\":");
    try writeJsonString(writer, message);
    try writer.writeAll("}\n");
}

fn writeHelpJson(writer: anytype) !void {
    try writer.writeAll(
        "{\"ok\":true,\"action\":\"help\",\"usage\":[\"--list\",\"--device <name|/dev/name> [--yes]\",\"<name|/dev/name> [--yes]\"],\"options\":[\"-l,--list\",\"-d,--device\",\"-y,--yes\",\"-h,--help\"]}\n",
    );
}

const ProgressEmitCtx = struct {
    file: std.fs.File,
    device: []const u8,
    last_percent: i16 = -1,
};

fn emitProgress(ctx_ptr: *anyopaque, milli: u32) anyerror!void {
    const ctx: *ProgressEmitCtx = @ptrCast(@alignCast(ctx_ptr));
    const writer = ctx.file.deprecatedWriter();
    const percent: i16 = @intCast(milli / 10);
    if (percent == ctx.last_percent) return;
    ctx.last_percent = percent;

    try writer.writeAll("{\"ok\":true,\"action\":\"flash\",\"status\":\"progress\",\"device\":");
    try writeJsonString(writer, ctx.device);
    try writer.writeAll(",\"percent\":");
    try writer.print("{d}", .{percent});
    try writer.writeAll("}\n");
}

fn normalizeDeviceName(arg: []const u8) []const u8 {
    if (std.mem.startsWith(u8, arg, "/dev/")) return arg[5..];
    return arg;
}

fn isValidTargetName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') continue;
        return false;
    }
    return true;
}

fn collectValidDevices(allocator: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
    var devices: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (devices.items) |d| allocator.free(d);
        devices.deinit(allocator);
    }

    var src_buf: [64]u8 = undefined;
    const src = installing.sourceDisk(&src_buf) catch "";

    var dir = try std.fs.openDirAbsolute("/sys/block", .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "loop")) continue;
        if (std.mem.startsWith(u8, entry.name, "ram")) continue;
        if (std.mem.eql(u8, entry.name, src)) continue;

        const dup = try allocator.dupe(u8, entry.name);
        try devices.append(allocator, dup);
    }

    std.sort.block([]const u8, devices.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return devices;
}

fn freeDevices(allocator: std.mem.Allocator, devices: *std.ArrayListUnmanaged([]const u8)) void {
    for (devices.items) |d| allocator.free(d);
    devices.deinit(allocator);
}

fn parseArgs(argv: []const []const u8) !CliOptions {
    var opts = CliOptions{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            opts.list_only = true;
        } else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
            opts.assume_yes = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--device")) {
            i += 1;
            if (i >= argv.len) return error.MissingDeviceArgument;
            opts.target = normalizeDeviceName(argv[i]);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownArgument;
        } else {
            if (opts.target != null) return error.MultipleDeviceArguments;
            opts.target = normalizeDeviceName(arg);
        }
    }

    return opts;
}

fn containsDevice(devices: []const []const u8, wanted: []const u8) bool {
    for (devices) |d| {
        if (std.mem.eql(u8, d, wanted)) return true;
    }
    return false;
}

fn askConfirmation(reader: anytype, writer: anytype, target: []const u8) !bool {
    try writer.writeAll("{\"ok\":true,\"action\":\"flash\",\"status\":\"confirmation_required\",\"device\":");
    try writeJsonString(writer, target);
    try writer.writeAll(",\"prompt\":\"Type YES to continue\"}\n");

    var buf: [32]u8 = undefined;
    const line = try reader.readUntilDelimiterOrEof(&buf, '\n');
    const input = line orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, input, " \t\r\n"), "YES");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const opts = parseArgs(argv) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.writeAll("{\"ok\":false,\"code\":\"ArgumentError\",\"message\":");
        const msg = try std.fmt.allocPrint(allocator, "{}", .{err});
        defer allocator.free(msg);
        try writeJsonString(stderr, msg);
        try stderr.writeAll("}\n");
        std.process.exit(2);
    };

    var devices = try collectValidDevices(allocator);
    defer freeDevices(allocator, &devices);

    const stdout_file = std.fs.File.stdout();
    const out = stdout_file.deprecatedWriter();
    const errw = std.fs.File.stderr().deprecatedWriter();

    if (opts.help) {
        try writeHelpJson(out);
        return;
    }

    if (opts.list_only) {
        try out.writeAll("{\"ok\":true,\"action\":\"list\",\"devices\":[");
        for (devices.items) |d| {
            if (d.ptr != devices.items[0].ptr) try out.writeByte(',');
            try out.writeAll("\"/dev/");
            try out.writeAll(d);
            try out.writeByte('"');
        }
        try out.writeAll("]}\n");
        return;
    }

    const target = opts.target orelse {
        try writeErrorJson(errw, "MissingDevice", "missing target device, use --device <name> or positional <name>");
        std.process.exit(2);
    };

    if (!isValidTargetName(target)) {
        try writeErrorJson(errw, "InvalidDeviceName", "invalid device name");
        std.process.exit(2);
    }

    if (!containsDevice(devices.items, target)) {
        try writeErrorJson(errw, "InvalidTarget", "target is not in valid block device list");
        std.process.exit(2);
    }

    if (!opts.assume_yes) {
        const stdin = std.fs.File.stdin().deprecatedReader();
        const confirmed = try askConfirmation(stdin, out, target);
        if (!confirmed) {
            try out.writeAll("{\"ok\":false,\"action\":\"flash\",\"status\":\"cancelled\"}\n");
            return;
        }
    }

    var progress_ctx = ProgressEmitCtx{ .file = stdout_file, .device = target };
    try out.writeAll("{\"ok\":true,\"action\":\"flash\",\"status\":\"started\",\"device\":");
    try writeJsonString(out, target);
    try out.writeAll("}\n");

    installing.installToDevice(target, null, .{
        .ctx = &progress_ctx,
        .onProgress = emitProgress,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "install failed: {}", .{err});
        defer allocator.free(msg);
        try writeErrorJson(errw, "InstallFailed", msg);
        std.process.exit(1);
    };
    try out.writeAll("{\"ok\":true,\"action\":\"flash\",\"status\":\"done\",\"device\":");
    try writeJsonString(out, target);
    try out.writeAll("}\n");
}

test {
    std.testing.refAllDecls(@This());
}
