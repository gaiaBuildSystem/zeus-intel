const std = @import("std");
const tui = @import("tui");
const State = @import("state.zig").State;

pub fn handleEvent(state: *State, event: tui.Event) tui.EventResult {
    switch (event) {
        .key => |ke| {
            switch (ke.key) {
                .enter => {
                    state.should_quit = true;
                    return .consumed;
                },
                .char => |c| {
                    if (c == 'q') {
                        state.should_quit = true;
                        return .consumed;
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
    const card_w: u16 = 65;
    const card_h: u16 = 10;
    const card_x = ctx.bounds.x + (ctx.bounds.width -| card_w) / 2;
    const card_y = ctx.bounds.y + (ctx.bounds.height -| card_h) / 2;

    const device_name = if (state.chosen_device.len > 0) state.chosen_device else "unknown";
    var dev_buf: [256]u8 = undefined;
    const dev_line = std.fmt.bufPrint(&dev_buf, "/dev/{s} has been flashed successfully.", .{device_name}) catch "Done.";

    var content_buf: [512]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf, "Installation complete!\n\n{s}", .{dev_line}) catch "Done.";

    var c = tui.Card.init(content)
        .withTitle("Done")
        .withBorder(.rounded)
        .withFooter("Remove the installation media and press Enter or 'q' to exit.");
    var card_ctx = ctx.child(tui.Rect.init(card_x, card_y, card_w, card_h));
    c.render(&card_ctx);
}
