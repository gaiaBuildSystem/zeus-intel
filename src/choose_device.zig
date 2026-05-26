const std = @import("std");
const tui = @import("tui");
const State = @import("state.zig").State;
const installing = @import("installing.zig");

pub fn populateDevices(state: *State) !void {
    var src_buf: [64]u8 = undefined;
    const src = installing.sourceDisk(&src_buf) catch "";

    var dir = std.fs.openDirAbsolute("/sys/block", .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "loop")) continue;
        if (std.mem.startsWith(u8, entry.name, "ram")) continue;
        if (std.mem.eql(u8, entry.name, src)) continue;
        const name = try state.allocator.dupe(u8, entry.name);
        try state.devices.append(state.allocator, name);
    }
}

pub fn handleEvent(state: *State, event: tui.Event) tui.EventResult {
    switch (event) {
        .key => |ke| {
            switch (ke.key) {
                .up => {
                    if (state.selected_idx == 0) return .consumed;
                    state.selected_idx -= 1;
                    return .needs_redraw;
                },
                .down => {
                    if (state.selected_idx + 1 > state.devices.items.len) return .consumed;
                    state.selected_idx += 1;
                    return .needs_redraw;
                },
                .enter => {
                    if (state.selected_idx == state.devices.items.len) {
                        state.should_quit = true;
                        return .needs_redraw;
                    }
                    if (state.devices.items.len > 0) {
                        state.chosen_device = state.devices.items[state.selected_idx];
                        state.screen = if (state.auto_yes) .installing else .confirm;
                        return .needs_redraw;
                    }
                    return .consumed;
                },
                .char => |c| {
                    if (c == 'k') {
                        if (state.selected_idx == 0) return .consumed;
                        state.selected_idx -= 1;
                        return .needs_redraw;
                    }
                    if (c == 'j') {
                        if (state.selected_idx + 1 > state.devices.items.len) return .consumed;
                        state.selected_idx += 1;
                        return .needs_redraw;
                    }
                },
                else => {},
            }
        },
        else => {},
    }
    return .ignored;
}

pub fn render(state: *const State, ctx: *tui.RenderContext) void {
    const card_w: u16 = 60;
    const card_h: u16 = 24;
    const card_x = ctx.bounds.x + (ctx.bounds.width -| card_w) / 2;
    const card_y = ctx.bounds.y + (ctx.bounds.height -| card_h) / 2;

    // Card draws border + title + separator; empty content leaves inner area free
    var c = tui.Card.init("").withTitle("Choose Device").withBorder(.rounded);
    var card_ctx = ctx.child(tui.Rect.init(card_x, card_y, card_w, card_h));
    c.render(&card_ctx);

    // Inner content area: y+4 after border(1)+title(1)+blank(1)+separator(1), height=card_h-6
    var inner_ctx = ctx.child(tui.Rect.init(card_x + 2, card_y + 4, card_w - 4, card_h - 6));
    var sub = inner_ctx.getSubScreen();

    const devices = state.devices.items;
    const cancel_idx = devices.len;

    for (devices, 0..) |device, i| {
        const row: u16 = @intCast(i);
        if (row >= sub.height) break;

        if (i == state.selected_idx) {
            sub.setStyle(tui.Style{ .fg = tui.Color.green, .attrs = .{ .bold = true } });
            sub.moveCursor(0, row);
            sub.putString("> ");
        } else {
            sub.setStyle(tui.Style{});
            sub.moveCursor(0, row);
            sub.putString("  ");
        }

        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "/dev/{s}", .{device}) catch continue;
        sub.putString(text);
    }

    const cancel_row: u16 = @intCast(cancel_idx);
    if (cancel_row < sub.height) {
        if (state.selected_idx == cancel_idx) {
            sub.setStyle(tui.Style{ .fg = tui.Color.red, .attrs = .{ .bold = true } });
            sub.moveCursor(0, cancel_row);
            sub.putString("> Cancel");
        } else {
            sub.setStyle(tui.Style{});
            sub.moveCursor(0, cancel_row);
            sub.putString("  Cancel");
        }
    }

    sub.setStyle(tui.Style{});
}
