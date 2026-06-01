const std = @import("std");
const tui = @import("tui");
const linux = std.os.linux;
const State = @import("state.zig").State;

// _IOR(0x12, 114, u64) on x86 Linux
const BLKGETSIZE64: u32 = 0x80081272;
const CHUNK_SIZE: usize = 4 * 1024 * 1024;
const SECTOR_SIZE: u64 = 512;

pub fn handleEvent(_: *State, _: tui.Event) tui.EventResult {
    return .ignored;
}

pub fn render(state: *const State, ctx: *tui.RenderContext) void {
    const card_w: u16 = 60;
    const card_h: u16 = 10;
    const card_x = ctx.bounds.x + (ctx.bounds.width -| card_w) / 2;
    const card_y = ctx.bounds.y + (ctx.bounds.height -| card_h) / 2;

    var c = tui.Card.init("Please wait...")
        .withTitle("Installing Phobos")
        .withBorder(.rounded);

    var card_ctx = ctx.child(
        tui.Rect.init(card_x, card_y, card_w, card_h),
    );
    c.render(&card_ctx);

    const p: f32 = @as(f32, @floatFromInt(state.progress.load(.acquire))) / 1000.0;
    var bar = tui.ProgressBar.initWithProgress(p);
    var bar_ctx = ctx.child(
        tui.Rect.init(card_x + 2, card_y + 6, card_w - 4, 1),
    );
    bar.render(&bar_ctx);
}

/// Returns the bare name (e.g. "sda") of the disk the installer booted from.
/// Caller provides a stack buffer; returned slice points into it.
pub fn sourceDisk(buf: []u8) ![]const u8 {
    var part_buf: [128]u8 = undefined;
    const root_part = try findRootPartition(&part_buf);
    return parentBlockDevice(root_part, buf);
}

fn findRootPartition(buf: []u8) ![]const u8 {
    const mounts = try std.fs.cwd().readFileAlloc(
        std.heap.page_allocator,
        "/proc/mounts",
        65536,
    );
    defer std.heap.page_allocator.free(mounts);

    var lines = std.mem.splitScalar(u8, mounts, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const device = fields.next() orelse continue;
        const mountpoint = fields.next() orelse continue;
        if (!std.mem.eql(u8, mountpoint, "/")) continue;
        if (!std.mem.startsWith(u8, device, "/dev/")) continue;
        const n = @min(device.len, buf.len);
        @memcpy(buf[0..n], device[0..n]);
        return buf[0..n];
    }
    return error.RootNotFound;
}

// Given a partition path like "/dev/sda1", return the parent block device
// name like "sda" by checking /sys/block/<dev>/<part>.
fn parentBlockDevice(partition_path: []const u8, buf: []u8) ![]const u8 {
    const part_name = if (std.mem.startsWith(u8, partition_path, "/dev/"))
        partition_path["/dev/".len..]
    else
        partition_path;

    // If the partition name itself exists directly in /sys/block it *is* the disk.
    var check_buf: [128]u8 = undefined;
    const self_path = std.fmt.bufPrint(&check_buf, "/sys/block/{s}", .{part_name}) catch
        return error.PathTooLong;
    if (std.fs.accessAbsolute(self_path, .{})) {
        const n = @min(part_name.len, buf.len);
        @memcpy(buf[0..n], part_name[0..n]);
        return buf[0..n];
    } else |_| {}

    var dir = try std.fs.openDirAbsolute("/sys/block", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/block/{s}/{s}", .{ entry.name, part_name }) catch continue;
        std.fs.accessAbsolute(path, .{}) catch continue;
        const n = @min(entry.name.len, buf.len);
        @memcpy(buf[0..n], entry.name[0..n]);
        return buf[0..n];
    }

    // No parent found: partition is itself the disk device.
    const n = @min(part_name.len, buf.len);
    @memcpy(buf[0..n], part_name[0..n]);
    return buf[0..n];
}


/// Returns bytes to copy: sector 0 through the GPT backup header (or last MBR
/// partition end). This is always much less than the full device on a sparsely
/// used disk. Falls back to the full device size on any parse error.
fn diskCopyLimit(fd: i32, device_bytes: u64) u64 {
    return partitionedSize(fd) catch device_bytes;
}

fn partitionedSize(fd: i32) !u64 {
    var mbr: [512]u8 = undefined;
    if (@as(isize, @bitCast(linux.pread(fd, &mbr, 512, 0))) != 512)
        return error.ReadFailed;
    if (mbr[510] != 0x55 or mbr[511] != 0xAA)
        return error.NoMBRSignature;

    var gpt_hdr: [512]u8 = undefined;
    if (@as(isize, @bitCast(linux.pread(fd, &gpt_hdr, 512, 512))) == 512 and
        std.mem.eql(u8, gpt_hdr[0..8], "EFI PART"))
    {
        return gptCopyLimit(fd, &gpt_hdr);
    }

    return mbrCopyLimit(&mbr);
}

fn mbrCopyLimit(mbr: *const [512]u8) !u64 {
    var last_lba: u64 = 0;
    for (0..4) |i| {
        const e = mbr[446 + i * 16 ..][0..16];
        if (e[4] == 0) continue;
        const start = std.mem.readInt(u32, e[8..12], .little);
        const count = std.mem.readInt(u32, e[12..16], .little);
        if (count == 0) continue;
        const end = @as(u64, start) + @as(u64, count) - 1;
        if (end > last_lba) last_lba = end;
    }
    if (last_lba == 0) return error.NoPartitions;
    return (last_lba + 1) * SECTOR_SIZE;
}

fn gptCopyLimit(fd: i32, hdr: *const [512]u8) !u64 {
    const entry_lba = std.mem.readInt(u64, hdr[72..80], .little);
    const num_entries = std.mem.readInt(u32, hdr[80..84], .little);
    const entry_size = std.mem.readInt(u32, hdr[84..88], .little);
    if (entry_size < 128 or entry_size > 512) return error.BadEntrySize;

    const capped = @min(num_entries, 4096);
    var last_lba: u64 = 0;
    for (0..capped) |i| {
        var entry: [512]u8 = undefined;
        const off = entry_lba * SECTOR_SIZE + @as(u64, i) * entry_size;
        if (@as(isize, @bitCast(linux.pread(fd, &entry, entry_size, @intCast(off)))) != @as(isize, @intCast(entry_size)))
            continue;
        if (std.mem.allEqual(u8, entry[0..16], 0)) continue;
        const end_lba = std.mem.readInt(u64, entry[40..48], .little);
        if (end_lba > last_lba) last_lba = end_lba;
    }
    if (last_lba == 0) return error.NoPartitions;
    return (last_lba + 1) * SECTOR_SIZE;
}

/// Reads the AlternateLBA field from the primary GPT header so the caller can
/// pread/pwrite the backup GPT tail (backup entries + backup header) separately,
/// without streaming through gigabytes of unused disk space.
fn gptAlternateLba(fd: i32) ?u64 {
    var hdr: [512]u8 = undefined;
    if (@as(isize, @bitCast(linux.pread(fd, &hdr, 512, 512))) != 512) return null;
    if (!std.mem.eql(u8, hdr[0..8], "EFI PART")) return null;
    const alt = std.mem.readInt(u64, hdr[32..40], .little);
    return if (alt == 0) null else alt;
}

fn replaceFstabLabel(allocator: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const fstab = try std.fs.cwd().readFileAlloc(allocator, "/etc/fstab", 65536);
    defer allocator.free(fstab);
    const new_fstab = try std.mem.replaceOwned(u8, allocator, fstab, from, to);
    defer allocator.free(new_fstab);
    const f = try std.fs.cwd().createFile("/etc/fstab", .{});
    defer f.close();
    try f.writeAll(new_fstab);
}

pub fn runInstall(state: *State, complete: *std.atomic.Value(bool)) void {
    defer complete.store(true, .release);
    doInstall(state) catch |err| {
        std.log.err("install failed: {}", .{err});
        return;
    };
    state.progress.store(1000, .release);
}

fn doInstall(state: *State) !void {
    var parent_buf: [64]u8 = undefined;
    const src_name = try sourceDisk(&parent_buf);

    if (std.mem.eql(u8, src_name, state.chosen_device)) return error.SameDevice;

    var src_path_buf: [72]u8 = undefined;
    const src_path = try std.fmt.bufPrintZ(&src_path_buf, "/dev/{s}", .{src_name});

    var dst_path_buf: [72]u8 = undefined;
    const dst_path = try std.fmt.bufPrintZ(&dst_path_buf, "/dev/{s}", .{state.chosen_device});

    const src_fd_rc = linux.open(src_path, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(src_fd_rc)) < 0) return error.OpenSrcFailed;
    const src_fd: i32 = @intCast(src_fd_rc);
    defer _ = linux.close(src_fd);

    const dst_fd_rc = linux.open(dst_path, .{ .ACCMODE = .WRONLY }, 0);
    if (@as(isize, @bitCast(dst_fd_rc)) < 0) return error.OpenDstFailed;
    const dst_fd: i32 = @intCast(dst_fd_rc);
    defer _ = linux.close(dst_fd);

    var total_bytes: u64 = 0;
    _ = linux.ioctl(src_fd, BLKGETSIZE64, @intFromPtr(&total_bytes));
    if (total_bytes == 0) return error.GetSizeFailed;

    var dst_bytes: u64 = 0;
    _ = linux.ioctl(dst_fd, BLKGETSIZE64, @intFromPtr(&dst_bytes));
    const copy_limit = diskCopyLimit(src_fd, total_bytes);
    const alt_lba = gptAlternateLba(src_fd);
    const backup_end = if (alt_lba) |lba| (lba + 1) * SECTOR_SIZE else copy_limit;
    const required = @max(copy_limit, backup_end);

    if (dst_bytes < required) return error.DestinationTooSmall;

    const buf = try std.heap.page_allocator.alloc(u8, CHUNK_SIZE);
    defer std.heap.page_allocator.free(buf);

    // the copy need to be done with the zeus_install flag set to 0
    var argv = [_][]const u8{ "fw_setenv", "zeus_install", "0" };
    var child = std.process.Child.init(
        &argv,
        std.heap.page_allocator
    );
    _ = try child.spawnAndWait();

    try replaceFstabLabel(std.heap.page_allocator, "BOOT-INTEL", "BOOT");

    var bytes_done: u64 = 0;
    while (bytes_done < copy_limit) {
        const remaining = copy_limit - bytes_done;
        const want = @min(buf.len, remaining);
        const nr = linux.read(src_fd, buf.ptr, want);
        if (@as(isize, @bitCast(nr)) <= 0) break;
        const nread: usize = @intCast(nr);

        var written: usize = 0;
        while (written < nread) {
            const nw = linux.write(dst_fd, buf[written..nread].ptr, nread - written);
            if (@as(isize, @bitCast(nw)) <= 0) return error.WriteFailed;
            written += @intCast(nw);
        }

        bytes_done += nread;
        const millis: u32 = @intCast(@min(999, bytes_done * 1000 / copy_limit));
        state.progress.store(millis, .release);
    }

    // Copy the GPT backup tail (backup entries array + backup header) which sits
    // near the physical end of the source disk, past the unused space we skipped.
    // Without this the destination disk has no backup GPT and some firmware
    // implementations refuse to recognize it or log validation errors on boot.
    if (alt_lba) |lba| {
        var gpt_hdr: [512]u8 = undefined;
        const alt_off: i64 = @intCast(lba * SECTOR_SIZE);
        if (@as(isize, @bitCast(linux.pread(src_fd, &gpt_hdr, 512, alt_off))) == 512 and
            std.mem.eql(u8, gpt_hdr[0..8], "EFI PART"))
        {
            const num_entries = std.mem.readInt(u32, gpt_hdr[80..84], .little);
            const entry_size = std.mem.readInt(u32, gpt_hdr[84..88], .little);
            if (entry_size >= 128 and entry_size <= 512) {
                const entries_bytes = @as(u64, num_entries) * entry_size;
                const tail_start = lba * SECTOR_SIZE - entries_bytes;
                const tail_len = entries_bytes + SECTOR_SIZE; // entries + header
                const tail_buf = try std.heap.page_allocator.alloc(u8, tail_len);
                defer std.heap.page_allocator.free(tail_buf);
                if (@as(isize, @bitCast(linux.pread(src_fd, tail_buf.ptr, tail_len, @intCast(tail_start)))) == @as(isize, @intCast(tail_len))) {
                    _ = linux.pwrite(dst_fd, tail_buf.ptr, tail_len, @intCast(tail_start));
                }
            }
        }
    }

    try replaceFstabLabel(std.heap.page_allocator, "BOOT", "BOOT-INTEL");

    // rollback it to the default value after the copy is done
    argv = [_][]const u8{ "fw_setenv", "zeus_install", "1" };
    child = std.process.Child.init(
        &argv,
        std.heap.page_allocator
    );
    _ = try child.spawnAndWait();

    // Flush writes to the block device before closing.
    _ = linux.syscall1(.fsync, @as(usize, @intCast(dst_fd)));
}
