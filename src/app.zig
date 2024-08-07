const std = @import("std");
const SDL = @import("sdl2");
const SDLex = @import("SDLex.zig");
const Vec2 = @import("Vec2.zig").Vec2;
const View = @import("view.zig").View;
pub const heap = @import("heap/interface.zig");
const heap_internal = @import("heap/internal.zig");
pub const stack = @import("stack/interface.zig");
pub const stack_internal = @import("stack/internal.zig");
const Design = @import("design.zig");
const Operation = @import("operation.zig");
const Animation = @import("animation.zig");
const UI = @import("UI.zig");
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//arena allocator for all the internal allocation of the application
pub var Allocator = std.heap.ArenaAllocator.init(gpa.allocator());
pub var exe_path: []u8 = undefined;

const fps = 144;
const frame_time_nano = 1_000_000_000 / fps;

const State = enum {
    heap,
    stack,
};

pub var operation_manager: Operation.Manager = undefined;
pub var window: SDL.Window = undefined;
pub var renderer: SDL.Renderer = undefined;
pub var cam_view: View = undefined;
var initiallized = false;
var state: State = State.heap;
var running_time: i128 = 0;

var playback_speed: f128 = 1;
var paused = false;
var freecam = false;

//TODO: move this function to a more apropriate file

pub fn init() !void {
    if (initiallized) {
        std.debug.print("tried to initiallize app more than once!", .{});
        return;
    }

    //  init basics
    try SDLex.fullyInitSDL();
    const display_info = SDL.DisplayMode.getDesktopInfo(0) catch unreachable;
    std.debug.print("screen resolution: {d}, {d}\n", .{ display_info.w, display_info.h });

    window = try SDL.createWindow("Application", .{ .centered = {} }, .{ .centered = {} }, @intCast(display_info.w), @intCast(display_info.h), .{ .vis = .shown, .resizable = false, .borderless = true, .mouse_capture = true });
    renderer = try SDL.createRenderer(window, null, .{ .accelerated = true });
    try renderer.setColor(Design.BG_color);
    cam_view = View.init(.{
        .x = 0,
        .y = 0,
        .width = @intFromFloat(@as(f64, @floatFromInt(display_info.w)) * (1.0 - Design.UI.width_portion)),
        .height = display_info.h,
    });
    Design.UI.view = View.init(.{ .x = cam_view.port.width, .y = 0, .width = display_info.w - cam_view.port.width, .height = display_info.h });
    Design.UI.view.cam.x = 0; // not require an offset when drawing ui.
    operation_manager = Operation.Manager.init();

    //init fonts
    exe_path = try std.fs.selfExeDirPathAlloc(gpa.allocator());

    const UI_font_path = try std.fmt.allocPrintZ(gpa.allocator(), "{s}/ioveska.ttf", .{exe_path});
    defer gpa.allocator().free(UI_font_path);
    Design.UI.font = try SDL.ttf.openFont(UI_font_path, 150);

    //loading screen
    const loading_surf = try Design.UI.font.renderTextSolid("Loading...", SDL.Color.rgb(150, 150, 150));
    const loading_tex = try SDL.createTextureFromSurface(renderer, loading_surf);
    try renderer.copy(loading_tex, .{ .x = 0, .y = 200, .width = 1000, .height = 600 }, null);
    renderer.present();

    //init heap
    heap_internal.init(renderer, Allocator.allocator());

    //init UI
    try UI.init(renderer);

    //init stack
    try stack_internal.init();
    initiallized = true;
}

pub fn start() !void {
    var last_iteration_time: i128 = 0;
    mainLoop: while (true) {
        const start_time = std.time.nanoTimestamp();
        last_iteration_time = @intFromFloat(@as(f128, @floatFromInt(last_iteration_time)) * playback_speed);
        operation_manager.update(if (paused) 0 else last_iteration_time, !freecam);
        const mouse_state = SDL.getMouseState();
        const mouse_pos: SDL.Point = .{ .x = mouse_state.x, .y = mouse_state.y };
        while (SDL.pollEvent()) |ev| {
            switch (ev) {
                .key_down => {
                    if (ev.key_down.scancode == .left)
                        operation_manager.undoLast();
                    if (ev.key_down.scancode == .right)
                        operation_manager.fastForward();
                    if (ev.key_down.scancode == .escape)
                        break :mainLoop;
                    if (ev.key_down.scancode == .space)
                        paused = !paused;
                },
                .mouse_button_down => {
                    if (ev.mouse_button_down.button == .left) {
                        const mouse_on_ui = UI.relativePoint(mouse_pos);
                        if (SDL.c.SDL_PointInRect(@ptrCast(&mouse_on_ui), @ptrCast(&Design.UI.freecam.rect)) == SDL.c.SDL_TRUE) {
                            freecam = !freecam;
                        }
                    }
                },
                .mouse_wheel => {
                    if (SDL.c.SDL_PointInRect(@ptrCast(&mouse_pos), @ptrCast(&cam_view.port)) == SDL.c.SDL_TRUE) {
                        if (freecam) {
                            const delta: f32 = @floatFromInt(ev.mouse_wheel.delta_y);
                            const zoomed_port = cam_view.getZoomed(1.0 + delta / 8.0, mouse_pos);
                            cam_view.cam = if (!cam_view.offLimits(zoomed_port)) zoomed_port else cam_view.cam;
                        }
                    } else _ = UI.scrollForSpeed(&playback_speed, ev.mouse_wheel.delta_y, mouse_pos);
                },
                .mouse_motion => {
                    const mouse_motion = cam_view.scale_vec_cam_to_port(SDLex.conertVecPoint(SDL.Point{ .x = ev.mouse_motion.delta_x, .y = ev.mouse_motion.delta_y }));
                    if (freecam and
                        SDL.c.SDL_PointInRect(@ptrCast(&mouse_pos), @ptrCast(&cam_view.port)) == SDL.c.SDL_TRUE and
                        ev.mouse_motion.button_state.getPressed(.right))
                    {
                        cam_view.cam.x -= mouse_motion.x;
                        cam_view.cam.y -= mouse_motion.y;
                    }
                },

                .quit => break :mainLoop,
                else => {},
            }
        }

        try renderer.clear();
        heap_internal.draw(renderer, cam_view);
        stack_internal.draw(renderer, cam_view);

        try UI.drawBG();
        UI.speed_element.draw(playback_speed);
        UI.freecam_element.draw(freecam);
        if (operation_manager.current_operation) |operation| {
            UI.action_element.draw(operation.data.action);
        }

        renderer.present();

        const sleep_time: i128 = frame_time_nano - (std.time.nanoTimestamp() - start_time);
        if (sleep_time > 0) {
            std.time.sleep(@intCast(sleep_time));
        }
        const end_time = std.time.nanoTimestamp();
        last_iteration_time = end_time - start_time;
        running_time += last_iteration_time;
    }
}

//---------------------------------------------------
//---------------------------------------------------
//-----------------APP INTERFACE---------------------
//---------------------------------------------------
//---------------------------------------------------
pub fn log(comptime str: []const u8, args: anytype) void {
    const string = std.fmt.allocPrint(Allocator.allocator(), str, args) catch unreachable;
    var non_animation: Animation.ZoomAnimation = Animation.ZoomAnimation.init(&cam_view, null, .{ .x = 0, .y = 0, .width = 0, .height = 0 }, 0);
    non_animation.done = true;
    operation_manager.push(Allocator.allocator(), .{ .action = .{ .print = string }, .animation = non_animation, .pause_time_nano = 0 });
}
