const std = @import("std");

fn f4(a: comptime_float) f64 {
    return @round(a * 1_0000);
}
const Counter = struct {
    id: [:0]const u8,
    initial: f64 = 0,
};
const Counters = &[_]Counter{
    .{ .id = "ticks" },
    .{ .id = "dirt" },
    .{ .id = "shovel", .initial = f4(1.0000) },
};
const CountersEnum = blk: {
    var struct_fields: [Counters.len]std.builtin.Type.EnumField = undefined;
    for (Counters, &struct_fields, 0..) |c, *f, i| f.* = .{ .name = c.id, .value = i };
    break :blk @Type(.{ .@"enum" = .{ .tag_type = usize, .fields = &struct_fields, .decls = &.{}, .is_exhaustive = true } });
};
const CountersStruct = blk: {
    var struct_fields: [Counters.len]std.builtin.Type.StructField = undefined;
    for (Counters, &struct_fields) |c, *f| f.* = .{ .name = c.id, .type = f64, .default_value = null, .is_comptime = false, .alignment = @alignOf(f64) };
    break :blk @Type(.{ .@"struct" = .{ .layout = .@"extern", .fields = &struct_fields, .decls = &.{}, .is_tuple = false } });
};
pub fn counterGet(st: *CountersStruct, tag: CountersEnum) *f64 {
    const st_a: *[Counters.len]f64 = @ptrCast(st);
    return &st_a[@intFromEnum(tag)];
}

const Amount = struct {
    tag: CountersEnum,
    value: f64,
    pub fn from(tag: CountersEnum, value: f64) Amount {
        return .{ .tag = tag, .value = value };
    }
};
const Recipe = struct {
    cmd: []const u8,
    effect: []const Amount,
};
const Recipes = [_]Recipe{
    .{ .cmd = "dig", .effect = &.{ .from(.shovel, f4(-0.0001)), .from(.dirt, f4(0.1)) } },
};

const Game = struct {
    last_tick_time_ms: i64 = 0,
    state: CountersStruct,
    last_save_value: std.json.Parsed(std.json.Value), // to not lose json keys on save.
    const MS_PER_TICK = 1000;
    const MAX_TICKS_AWAY = 1000;

    pub fn init(gpa: std.mem.Allocator, savegame: []const u8) !Game {
        const decoded = try std.json.parseFromSlice(std.json.Value, gpa, savegame, .{ .parse_numbers = false });
        if (decoded.value != .object) return error.CorruptedSave;
        const obj = &decoded.value.object;

        var res_state: [Counters.len]f64 = undefined;
        std.debug.assert(@sizeOf(CountersStruct) == @sizeOf([Counters.len]f64) and @alignOf(CountersStruct) == @alignOf([Counters.len]f64));
        for (Counters, &res_state) |counter, *st| {
            st.* = if (obj.get(counter.id)) |v| blk: {
                if (v != .number_string) return error.CorruptedSave;
                break :blk try std.fmt.parseFloat(f64, v.number_string);
            } else counter.initial;
        }

        return .{ .state = @as(*const CountersStruct, @ptrCast(&res_state)).*, .last_save_value = decoded };
    }
    pub fn deinit(self: *Game) void {
        self.last_save_value.deinit();
    }
    pub fn save(self: *Game, gpa: std.mem.Allocator) ![]const u8 {
        const res = &self.last_save_value.value.object;
        for (Counters, 0..) |counter, i| {
            const val = counterGet(&self.state, @enumFromInt(i));
            const gpres = try res.getOrPut(counter.id);
            gpres.value_ptr.* = .{ .float = val.* }; // this makes 9996 format as 9.996e3 for some reason
        }
        return std.json.stringifyAlloc(gpa, &self.last_save_value.value, .{});
    }

    pub fn tick(self: *Game, time_ms: i64) void {
        if (time_ms < self.last_tick_time_ms) return;
        if (self.last_tick_time_ms == 0) {
            self.last_tick_time_ms = time_ms;
            return;
        }
        const diff = time_ms - self.last_tick_time_ms;
        const num_ticks_to_xc = @min(MAX_TICKS_AWAY, @divFloor(diff, MS_PER_TICK));
        if (num_ticks_to_xc == 0) return;
        self.last_tick_time_ms = self.last_tick_time_ms + MS_PER_TICK * num_ticks_to_xc;
        std.log.info("fast-forward: {d}", .{num_ticks_to_xc});
        std.debug.assert(num_ticks_to_xc > 0 and num_ticks_to_xc < std.math.maxInt(usize));
        for (0..@intCast(num_ticks_to_xc)) |_| self.tickOne();
    }

    pub fn tickOne(self: *Game) void {
        self.state.ticks += f4(1);
    }
};

pub fn main() !void {
    var gpa_backing = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_backing.deinit() == .ok);
    const gpa = gpa_backing.allocator();

    const savetxt = if (std.fs.cwd().readFileAlloc(gpa, "idlegamesave.json", std.math.maxInt(usize))) |v| blk: {
        break :blk v;
    } else |e| blk: {
        break :blk switch (e) {
            error.OutOfMemory => return e,
            else => try gpa.dupe(u8, "{}"),
        };
    };
    defer gpa.free(savetxt);

    var game: Game = try .init(gpa, savetxt);
    defer game.deinit();

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    game.tick(std.time.milliTimestamp());

    lpc: while (true) {
        try stdout.print("> ", .{});
        const command = stdin.readUntilDelimiterAlloc(gpa, '\n', std.math.maxInt(usize)) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        defer gpa.free(command);

        game.tick(std.time.milliTimestamp());

        if (std.mem.eql(u8, command, "ls")) {
            try stdout.print("ticks: {d:.4}\n", .{game.state.ticks / 10000});
            try stdout.print("dirt: {d:.4}\n", .{game.state.dirt / 10000});
            try stdout.print("shovel: {d:.4}\n", .{game.state.shovel / 10000});
            try stdout.print("- dig: [0.0001|shovel] shovel -> [0.1|dirt] dirt\n", .{});
        } else if (std.mem.eql(u8, command, "save")) {
            const save_res = try game.save(gpa);
            defer gpa.free(save_res);
            if (std.fs.cwd().writeFile(.{ .sub_path = "idlegamesave.json", .data = save_res })) |_| {
                try stdout.print("saved\n", .{});
            } else |e| {
                try stdout.print("save file error: {s}\n", .{@errorName(e)});
                try stdout.print("{s}\n", .{save_res});
            }
        } else if (std.mem.eql(u8, command, "exit")) {
            break;
        } else if (std.mem.eql(u8, command, "help")) {
            try stdout.writeAll(
                \\Commands:
                \\- ls : list counts
                \\- save : save game
                \\- exit : exit game
                \\- help : this menu
                \\Input the name of a recipe to execute it.
                \\
            );
        } else for (Recipes) |recipe| {
            if (std.mem.eql(u8, command, recipe.cmd)) {
                for (recipe.effect) |min| {
                    if (counterGet(&game.state, min.tag).* + min.value >= 0) {
                        // pass
                    } else {
                        try stdout.print("not enough resource", .{});
                        continue :lpc;
                    }
                }
                for (recipe.effect) |fx| {
                    counterGet(&game.state, fx.tag).* += fx.value;
                }
                try stdout.print("executed\n", .{});
                continue :lpc;
            }
        } else {
            try stdout.print("Bad command: \"{}\"\n", .{std.zig.fmtEscapes(command)});
            try stdout.print("Use 'help' for list of commands.\n", .{});
        }
    }
}
