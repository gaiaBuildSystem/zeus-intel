const std = @import("std");
const tui = @import("tui");
const linux = std.os.linux;

const State = @import("state.zig").State;
const choose_device = @import("choose_device.zig");
const confirm = @import("confirm.zig");
const installing = @import("installing.zig");
const done = @import("done.zig");

const vt_path = "/dev/tty1";

fn takeoverVt() !void {
    const rc_open = linux.open(vt_path, linux.O{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    if (@as(isize, @bitCast(rc_open)) < 0) return error.OpenVtFailed;
    const fd: i32 = @intCast(rc_open);
    defer _ = linux.close(fd);

    const pid = linux.fork();
    if (@as(isize, @bitCast(pid)) < 0) return error.ForkFailed;
    if (pid != 0) {
        var wstatus: u32 = 0;
        _ = linux.waitpid(@intCast(pid), &wstatus, 0);
        linux.exit(if (linux.W.IFEXITED(wstatus)) linux.W.EXITSTATUS(wstatus) else 1);
    }

    const rc_sid = linux.setsid();
    if (rc_sid < 0) return error.SetsidFailed;

    const rc = linux.ioctl(fd, linux.T.IOCSCTTY, 1);
    if (@as(isize, @bitCast(rc)) < 0) return error.IoctlTIOCSCTTYFailed;

    _ = linux.dup2(fd, 0);
    _ = linux.dup2(fd, 1);
    _ = linux.dup2(fd, 2);
}

const App = struct {
    state: State,
    tui_app: ?*tui.App = null,
    anim_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    anim_thread: ?std.Thread = null,
    install_thread: ?std.Thread = null,
    install_complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn render(self: *App, ctx: *tui.RenderContext) void {
        if (self.state.screen == .installing and self.install_complete.load(.acquire)) {
            self.anim_running.store(false, .release);
            self.state.screen = .done;
        }
        switch (self.state.screen) {
            .choose_device => choose_device.render(&self.state, ctx),
            .confirm => confirm.render(&self.state, ctx),
            .installing => installing.render(&self.state, ctx),
            .done => done.render(&self.state, ctx),
        }
    }

    pub fn handleEvent(self: *App, event: tui.Event) tui.EventResult {
        const result = switch (self.state.screen) {
            .choose_device => choose_device.handleEvent(&self.state, event),
            .confirm => confirm.handleEvent(&self.state, event),
            .installing => installing.handleEvent(&self.state, event),
            .done => done.handleEvent(&self.state, event),
        };
        if (self.state.screen == .installing and !self.anim_running.load(.acquire)) {
            self.startInstall();
        }
        if (self.state.should_quit) {
            if (self.tui_app) |a| a.quit();
        }
        return result;
    }

    fn startInstall(self: *App) void {
        self.anim_running.store(true, .release);
        self.anim_thread = std.Thread.spawn(.{}, runAnim, .{self}) catch return;
        self.install_thread = std.Thread.spawn(
            .{},
            installing.runInstall,
            .{ &self.state, &self.install_complete },
        ) catch return;
    }

    pub fn stopAnim(self: *App) void {
        self.anim_running.store(false, .release);
        if (self.anim_thread) |t| {
            t.join();
            self.anim_thread = null;
        }
        if (self.install_thread) |t| {
            t.join();
            self.install_thread = null;
        }
    }
};

fn runAnim(app: *App) void {
    while (app.anim_running.load(.acquire)) {
        std.Thread.sleep(50_000_000);
        if (app.tui_app) |a| a.needs_redraw = true;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var no_vt = false;
    var auto_yes = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--no-vt")) no_vt = true;
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) auto_yes = true;
    }
    if (!no_vt) try takeoverVt();

    const model = try allocator.create(App);
    defer allocator.destroy(model);
    model.* = .{ .state = .{ .allocator = allocator, .auto_yes = auto_yes } };
    defer model.state.deinit();

    try choose_device.populateDevices(&model.state);

    var app = try tui.App.initWithAllocator(allocator, .{});
    model.tui_app = &app;
    try app.setRoot(model);
    try app.run();
    model.stopAnim();
    app.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
