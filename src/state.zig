const std = @import("std");

pub const Screen = enum {
    choose_device,
    confirm,
    installing,
    done,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    screen: Screen = .choose_device,
    devices: std.ArrayListUnmanaged([]const u8) = .empty,
    selected_idx: usize = 0,
    chosen_device: []const u8 = &.{},
    auto_yes: bool = false,
    confirm_yes: bool = true,
    // 0..1000 milliprogress; written by install thread, read by render thread
    progress: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    should_quit: bool = false,

    pub fn deinit(self: *State) void {
        for (self.devices.items) |d| self.allocator.free(d);
        self.devices.deinit(self.allocator);
    }
};
