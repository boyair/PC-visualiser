const std = @import("std");
const SDL = @import("sdl2");
const SDLex = @import("SDLex.zig");
const Vec2 = @import("Vec2.zig").Vec2;
const View = @import("view.zig").View;
const heap = @import("heap/internal.zig");
const design = @import("design.zig");
const Operation = @import("operation.zig");
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const fps = 2000;
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

pub fn init() !void {
    if (initiallized) {
        std.debug.print("tried to initiallize app more than once!", .{});
        return;
    }

    //  init basics
    try SDLex.fullyInitSDL();
    window = SDL.createWindow("Application", .{ .centered = {} }, .{ .centered = {} }, 1000, 1000, .{ .vis = .shown, .resizable = false, .borderless = false, .mouse_capture = true }) catch |err| {
        std.debug.print("Failed to load window! {s}\n", .{@errorName(err)});
        return err;
    };
    renderer = try SDL.createRenderer(window, null, .{ .accelerated = true });
    try renderer.setColor(design.BG_color);
    cam_view = View.init(&window);
    operation_manager = Operation.Manager.init();

    //init font
    const app_dir = try std.fs.selfExeDirPathAlloc(gpa.allocator());
    const font_path = try std.fmt.allocPrintZ(gpa.allocator(), "{s}/ioveska.ttf", .{app_dir});
    design.heap.font = try SDL.ttf.openFont(font_path, 200);

    //loading screen
    const loading_surf = try design.heap.font.renderTextSolid("Loading...", SDL.Color.rgb(255, 255, 255));
    const loading_tex = try SDL.createTextureFromSurface(renderer, loading_surf);
    try renderer.copy(loading_tex, .{ .x = 0, .y = 200, .width = 1000, .height = 600 }, null);
    renderer.present();

    //init heap
    heap.initRand();
    try heap.initTextures(renderer);
    initiallized = true;
}

pub fn start() !void {
    var holding_right = false;
    var last_iteration_time: i128 = 0;
    mainLoop: while (true) {
        const start_time = std.time.nanoTimestamp();
        last_iteration_time = @intFromFloat(@as(f128, @floatFromInt(last_iteration_time)) * playback_speed);
        operation_manager.update(last_iteration_time);
        const mouse_state = SDL.getMouseState();
        const mouse_pos: SDL.Point = .{ .x = mouse_state.x, .y = mouse_state.y };
        while (SDL.pollEvent()) |ev| {
            switch (ev) {
                .key_up => {
                    if (ev.key_up.scancode == .down)
                        playback_speed -= 0.2;
                    if (ev.key_up.scancode == .up)
                        playback_speed += 0.2;
                },
                .mouse_button_down => {
                    if (ev.mouse_button_down.button == SDL.MouseButton.right) {
                        holding_right = true;
                    }
                },
                .mouse_button_up => {
                    if (ev.mouse_button_up.button == SDL.MouseButton.right) {
                        holding_right = false;
                    }
                },
                .window => {
                    if (ev.window.type == .resized) {
                        cam_view.window_size = window.getSize();
                    }
                },
                .mouse_wheel => {
                    const delta: f32 = @floatFromInt(ev.mouse_wheel.delta_y);
                    const zoomed_port = cam_view.getZoomed(1.0 + delta / 8.0, mouse_pos);
                    cam_view.port = if (!cam_view.offLimits(zoomed_port)) zoomed_port else cam_view.port;
                },
                .quit => break :mainLoop,
                else => {},
            }
        }
        try renderer.clear();
        heap.draw(renderer, cam_view);
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

//pub fn heapAlloc(usize: size){
//    heap.alloc(4,)
//}
