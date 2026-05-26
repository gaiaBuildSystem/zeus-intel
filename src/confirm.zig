const std = @import("std");
const tui = @import("tui");
const State = @import("state.zig").State;

pub fn handleEvent(state: *State, event: tui.Event) tui.EventResult {
    switch (event) {
        .key => |ke| switch (ke.key) {
            .left, .right => |_| {
                state.confirm_yes = !state.confirm_yes;
                return .needs_redraw;
            },
            .char => |c| {
                if (c == 'h') {
                    state.confirm_yes = !state.confirm_yes;
                    return .needs_redraw;
                }
                if (c == 'l') {
                    state.confirm_yes = !state.confirm_yes;
                    return .needs_redraw;
                }
            },
            .enter => {
                if (state.confirm_yes) {
                    state.screen = .installing;
                } else {
                    state.confirm_yes = true;
                    state.screen = .choose_device;
                }
                return .needs_redraw;
            },
            .escape => {
                state.confirm_yes = true;
                state.screen = .choose_device;
                return .needs_redraw;
            },
            else => {},
        },
        else => {},
    }
    return .ignored;
}

pub fn render(state: *const State, ctx: *tui.RenderContext) void {
    const card_w: u16 = 60;
    const card_h: u16 = 10;
    const card_x = ctx.bounds.x + (ctx.bounds.width -| card_w) / 2;
    const card_y = ctx.bounds.y + (ctx.bounds.height -| card_h) / 2;

    var c = tui.Card.init("").withTitle("Confirm Installation").withBorder(.rounded);
    var card_ctx = ctx.child(tui.Rect.init(card_x, card_y, card_w, card_h));
    c.render(&card_ctx);

    var inner = ctx.child(tui.Rect.init(card_x + 2, card_y + 4, card_w - 4, card_h - 6));
    var sub = inner.getSubScreen();

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Install to /dev/{s} ?", .{state.chosen_device}) catch return;
    sub.setStyle(tui.Style{});
    sub.moveCursor(0, 0);
    sub.putString(msg);

    // "[ Yes ]  [ No ]" on row 2, centered
    const yes_label = "[ Yes ]";
    const no_label = "[ No ]";
    const gap: u16 = 4;
    const total_w: u16 = @intCast(yes_label.len + gap + no_label.len);
    const start_x: u16 = (card_w - 4 -| total_w) / 2;

    if (state.confirm_yes) {
        sub.setStyle(tui.Style{ .fg = tui.Color.green, .attrs = .{ .bold = true } });
    } else {
        sub.setStyle(tui.Style{});
    }
    sub.moveCursor(start_x, 2);
    sub.putString(yes_label);

    const no_x: u16 = start_x + @as(u16, @intCast(yes_label.len)) + gap;
    if (!state.confirm_yes) {
        sub.setStyle(tui.Style{ .fg = tui.Color.red, .attrs = .{ .bold = true } });
    } else {
        sub.setStyle(tui.Style{});
    }
    sub.moveCursor(no_x, 2);
    sub.putString(no_label);

    sub.setStyle(tui.Style{});
}
