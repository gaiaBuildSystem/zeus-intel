const std = @import("std");
const linux = std.os.linux;

// _IOR(0x12, 114, u64) on x86 Linux
const BLKGETSIZE64: u32 = 0x80081272;
const CHUNK_SIZE: usize = 4 * 1024 * 1024;
const SECTOR_SIZE: u64 = 512;

pub const ProgressSink = struct {
    ctx: *anyopaque,
    onProgress: *const fn (ctx: *anyopaque, milli: u32) anyerror!void,
};

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

// EFI System Partition type GUID in its on-disk byte order.
const EFI_PART_TYPE: [16]u8 = .{
    0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
    0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B,
};

/// Returns the byte offset of the FAT/EFI boot partition, trying GPT first
/// then falling back to MBR (type 0x0B/0x0C).
fn findFatPartStart(fd: i32) !u64 {
    var sec0: [512]u8 = undefined;
    if (@as(isize, @bitCast(linux.pread(fd, &sec0, 512, 0))) != 512) return error.ReadFailed;
    if (sec0[510] != 0x55 or sec0[511] != 0xAA) return error.NoDiskSignature;

    // GPT: protective MBR at sector 0, real header at sector 1.
    var hdr: [512]u8 = undefined;
    if (@as(isize, @bitCast(linux.pread(fd, &hdr, 512, 512))) == 512 and
        std.mem.eql(u8, hdr[0..8], "EFI PART"))
    {
        const entry_lba = std.mem.readInt(u64, hdr[72..80], .little);
        const num_entries = std.mem.readInt(u32, hdr[80..84], .little);
        const entry_size = std.mem.readInt(u32, hdr[84..88], .little);
        if (entry_size >= 128 and entry_size <= 512) {
            for (0..@min(num_entries, 128)) |i| {
                var entry: [512]u8 = undefined;
                const off: i64 = @intCast(entry_lba * SECTOR_SIZE + @as(u64, i) * entry_size);
                if (@as(isize, @bitCast(linux.pread(fd, &entry, entry_size, off))) != @as(isize, @intCast(entry_size))) continue;
                if (std.mem.eql(u8, entry[0..16], &EFI_PART_TYPE))
                    return std.mem.readInt(u64, entry[32..40], .little) * SECTOR_SIZE;
            }
        }
        return error.EfiPartNotFound;
    }

    // MBR: scan the four primary entries for a FAT32 partition (0x0B or 0x0C).
    for (0..4) |i| {
        const e = sec0[446 + i * 16 ..][0..16];
        if (e[4] != 0x0B and e[4] != 0x0C) continue;
        const start_lba = std.mem.readInt(u32, e[8..12], .little);
        if (start_lba == 0) continue;
        return @as(u64, start_lba) * SECTOR_SIZE;
    }
    return error.FatPartNotFound;
}

/// Writes `new_label` into the FAT32 volume-label fields at byte offset
/// `part_start` within the already-open disk fd:
///   - boot sector offset 71 (BS_VolLab)
///   - backup boot sector (BPB_BkBootSec)
///   - the 0x08-attribute directory entry in the root cluster
fn setFatLabel(fd: i32, part_start: u64, new_label: []const u8) !void {
    var boot: [512]u8 = undefined;
    if (@as(isize, @bitCast(linux.pread(fd, &boot, 512, @intCast(part_start)))) != 512)
        return error.ReadFailed;

    // Build space-padded, uppercased 11-byte label.
    var lab: [11]u8 = .{' '} ** 11;
    const n = @min(new_label.len, 11);
    @memcpy(lab[0..n], new_label[0..n]);
    for (&lab) |*c| if (c.* >= 'a' and c.* <= 'z') { c.* -= 32; };

    @memcpy(boot[71..82], &lab);
    if (@as(isize, @bitCast(linux.pwrite(fd, &boot, 512, @intCast(part_start)))) != 512)
        return error.WriteFailed;

    // Mirror to the backup boot sector.
    const bk = std.mem.readInt(u16, boot[50..52], .little);
    if (bk != 0 and bk != 0xFFFF) {
        const bk_off: i64 = @intCast(part_start + @as(u64, bk) * 512);
        var bk_sec: [512]u8 = undefined;
        if (@as(isize, @bitCast(linux.pread(fd, &bk_sec, 512, bk_off))) == 512) {
            @memcpy(bk_sec[71..82], &lab);
            _ = linux.pwrite(fd, &bk_sec, 512, bk_off);
        }
    }

    // Update the volume-label directory entry (attr 0x08) in the root cluster.
    const bps = std.mem.readInt(u16, boot[11..13], .little);
    const spc: u64 = boot[13];
    const rsvd: u64 = std.mem.readInt(u16, boot[14..16], .little);
    const nfats: u64 = boot[16];
    const fat_sz: u64 = std.mem.readInt(u32, boot[36..40], .little);
    const root_clus: u64 = std.mem.readInt(u32, boot[44..48], .little);
    if (bps == 0 or spc == 0 or root_clus < 2) return;
    const clus_bytes = spc * @as(u64, bps);
    const root_off: i64 = @intCast(part_start + (rsvd + nfats * fat_sz + (root_clus - 2) * spc) * @as(u64, bps));

    const root_buf = try std.heap.page_allocator.alloc(u8, clus_bytes);
    defer std.heap.page_allocator.free(root_buf);
    if (@as(isize, @bitCast(linux.pread(fd, root_buf.ptr, clus_bytes, root_off))) != @as(isize, @intCast(clus_bytes)))
        return;

    var i: usize = 0;
    while (i + 32 <= root_buf.len) : (i += 32) {
        if (root_buf[i] == 0x00) break;
        if (root_buf[i] == 0xE5) continue;
        if (root_buf[i + 11] == 0x08) {
            @memcpy(root_buf[i..][0..11], &lab);
            _ = linux.pwrite(fd, root_buf.ptr, clus_bytes, root_off);
            break;
        }
    }
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

fn changeBootFileLabelName(fromLabel: []const u8, toLabel: []const u8) !void {
    // check if the /var/rootdirs/media/grub/<fromLabel> file exists
    // if it exists we are on PhobOS
    // if not we need to check /boot/<fromLabel> which is used on plain Debian
    // with this done we then rename the <fromLabel> to <toLabel>
    // this is a file, with a name so u-boot can check the label easily

    var from_buf: [256]u8 = undefined;
    var to_buf: [256]u8 = undefined;

    const phobos_from = try std.fmt.bufPrintZ(
        &from_buf,
        "/var/rootdirs/media/grub/{s}",
        .{fromLabel}
    );

    const phobos_to = try std.fmt.bufPrintZ(
        &to_buf,
        "/var/rootdirs/media/grub/{s}",
        .{toLabel}
    );

    if (std.fs.cwd().access(phobos_from, .{})) |_| {
        if (std.fs.cwd().access(phobos_to, .{})) |_| {} else |_| {
            try std.fs.cwd().rename(phobos_from, phobos_to);
        }
    } else |_| {
        const debian_from = try std.fmt.bufPrintZ(
            &from_buf,
            "/boot/{s}",
            .{fromLabel}
        );
        const debian_to = try std.fmt.bufPrintZ(
            &to_buf,
            "/boot/{s}",
            .{toLabel}
        );
        if (std.fs.cwd().access(debian_to, .{})) |_| {} else |_| {
            try std.fs.cwd().rename(debian_from, debian_to);
        }
    }
}

fn ubootEnvSet(name: []const u8, value: []const u8) !void {
    var argv = [_][]const u8{ "fw_setenv", name, value };
    var child = std.process.Child.init(
        &argv,
        std.heap.page_allocator
    );
    _ = try child.spawnAndWait();
}

pub fn installToDevice(
    chosen_device: []const u8,
    progress: ?*std.atomic.Value(u32),
    sink: ?ProgressSink,
) !void {
    var parent_buf: [64]u8 = undefined;
    const src_name = try sourceDisk(&parent_buf);

    if (std.mem.eql(u8, src_name, chosen_device)) return error.SameDevice;

    var src_path_buf: [72]u8 = undefined;
    const src_path = try std.fmt.bufPrintZ(&src_path_buf, "/dev/{s}", .{src_name});

    var dst_path_buf: [72]u8 = undefined;
    const dst_path = try std.fmt.bufPrintZ(&dst_path_buf, "/dev/{s}", .{chosen_device});

    const src_fd_rc = linux.open(src_path, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(src_fd_rc)) < 0) return error.OpenSrcFailed;
    const src_fd: i32 = @intCast(src_fd_rc);
    defer _ = linux.close(src_fd);

    const dst_fd_rc = linux.open(dst_path, .{ .ACCMODE = .RDWR }, 0);
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

    // Find the EFI/boot partition start on the source disk before cloning.
    const boot_part_start = try findFatPartStart(src_fd);

    const buf = try std.heap.page_allocator.alloc(u8, CHUNK_SIZE);
    defer std.heap.page_allocator.free(buf);

    // the copy need to be done with the zeus_install flag set to 0
    try ubootEnvSet("zeus_install", "0");
    try ubootEnvSet("label_name", "BOOT");

    try replaceFstabLabel(std.heap.page_allocator, "BOOT-INTEL", "BOOT");

    try changeBootFileLabelName("BOOT-INTEL", "BOOT");

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
        if (progress) |p| p.store(millis, .release);
        if (sink) |s| try s.onProgress(s.ctx, millis);
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

    // Rename the BOOT-INTEL label on the destination BOOT partition to BOOT so
    // it matches the fstab entry we already wrote into the clone.
    try setFatLabel(dst_fd, boot_part_start, "BOOT");

    try replaceFstabLabel(std.heap.page_allocator, "BOOT", "BOOT-INTEL");

    // rollback it to the default value after the copy is done
    try ubootEnvSet("zeus_install", "1");
    try ubootEnvSet("label_name", "BOOT-INTEL");

    try changeBootFileLabelName("BOOT", "BOOT-INTEL");

    // Flush writes to the block device before closing.
    _ = linux.syscall1(.fsync, @as(usize, @intCast(dst_fd)));
}
