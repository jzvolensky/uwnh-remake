// Note: make sure to remain on ZIG 0.11.0
//
// TODO
// - It makes sense for diff/diff_list to have an arena allocator because you want to clear it every loop/frame/tick
// -- what about viewport? (I think the answer is yes since it can change on the fly)
// -- what about world/world_data? (I think the answer is also yes since you can load/unload worlds on the fly)
// -- what about entities? (not the default "template" ones but the scene/world ones yes)
// - ECS
// -- array of entities (this serves as IDs?)
// -- array of entity_types
// -- array of components attached to entities ... how does this work?
// --- [0, x.., 0, x..] where every x > 0 and every 0 = another entity
// --- what about when you use the editor? you'd have to do something like [entity_index_id, add_or_remove_component, which_one]
// --- then you have a component so then what?
// --- no you need to keep them separated (like the song)
// --- you need to queries like...
// ---- "select * entities that have a health component"
// ---- "select * entities where type = %"
// ---- "select health from components where entity = %"
// ---- seperate array for each component vs entities = entities_with_health_component = [_]u16.{0,3,4,8}...
// - Go through all files that use "export fn" and convert them or remove them -> build process with // @wasm
// - Figure out the chain of initializations given new file structure, such as game->init() --->>> editor->init() ---->>>++++ entities->init()
//
// Entity -> array of attached components as integer IDs
// Take an action (function, example: Move(entity_index, direction)
// - In the function you would check if the entity HAS the component or not
// - If not, do nothing
// - Stat based components
// - entity_{id}_component_{id}.bin -> hold default values
// -- Alternatively: iterating over an entity at runtime and applying default values to it

// TODO: Scripts
// Outer array is script line
// Inner array is command for line (need to create legend for inner array commands)
// if [0] = 0 = moveEntity
// -- [1] = entityIndex
// -- [2] = direction (0 = left, 1 = right, 2 = up, 3 = down) (EXAMPLE)
// script: [2][3]u8 = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 } };
// runScript(scriptIndex: u8)

const std = @import("std");
const ArrayList = std.ArrayList;

pub var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
pub var allocator = gpa_allocator.allocator();

const enums = @import("enums.zig");
const embeds = @import("embeds.zig");
const debug = @import("debug.zig");
const helpers = @import("helpers.zig");
const renderer = @import("renderer.zig");
const diff = @import("diff.zig");
const editor = @import("editor.zig");
const viewport = @import("viewport.zig");
// const inputs = @import("inputs.zig");

// -----------------------------------------------------------------------------------------
// @wasm
pub const std_options = struct {
    pub const log_level = .info;
    pub fn logFn(
        comptime level: std.log.Level,
        comptime scope: @Type(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        log(level.asText() ++ prefix ++ format, args);
    }
};

fn log(comptime format: []const u8, args: anytype) void {
    const writer = std.io.Writer(void, error{}, console_log_write_zig){ .context = {} };
    writer.print(format, args) catch @panic("console_log_write failed");
    console_log_flush();
}

pub fn panic(
    msg: []const u8,
    trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    log("panic: {s}", .{msg});
    if (trace) |t| {
        log("ErrorTrace:", .{});
        std.debug.dumpStackTrace(t.*);
    } else {
        log("ErrorTrace: <none>", .{});
    }
    log("StackTrace:", .{});
    std.debug.dumpCurrentStackTrace(ret_addr);
    while (true) { @breakpoint(); }
}

pub fn uncaughtError(err: anytype) noreturn {
    log("uncaught error: {s}", .{@errorName(err)});
    if (@errorReturnTrace()) |t| {
        log("ErrorTrace:", .{});
        std.debug.dumpStackTrace(t.*);
    } else {
        log("ErrorTrace: <none>", .{});
    }
    while (true) { @breakpoint(); }
}


fn console_log_write_zig(context: void, bytes: []const u8) !usize {
    _ = context;
    console_log_write(bytes.ptr, bytes.len);
    return bytes.len;
}
extern fn console_log_write(ptr: [*]const u8, len: usize) void;
extern fn console_log_flush() void;
// -----------------------------------------------------------------------------------------

pub const WorldDataStruct = struct {
    offset: u16 = 3,
    data: std.ArrayListUnmanaged(u16) = .{},
    layers: u16 = 3,
    has_data: bool = false,
    // TODO: You tried to pass a pointer to the embedded data so you don't have duplicate data BUT then the pointer was only updating a single instance of EmbeddedDataStruct (and then self.index in that struct was incrementing and going out of bounds)
    embedded: EmbeddedDataStruct = undefined,
    pub fn setEmbedded(self: *WorldDataStruct, embedded: EmbeddedDataStruct) void {
        self.embedded = embedded;
    }
    pub fn getIndex(self: *WorldDataStruct) u16 {
        const index = if (self.has_data)
            self.data.items[0]
        else
            self.embedded.readData(0, .Little);
        
        // std.log.info("index {d}",.{index});
        return index;
    }
    pub fn getWidth(self: *WorldDataStruct) u16 {
        const width = if (self.has_data)
            self.data.items[1]
        else 
            self.embedded.readData(1, .Little);
        // std.log.info("width {d}",.{width});
        return width;
    }
    pub fn getHeight(self: *WorldDataStruct) u16 {
        const height = if (self.has_data)
            self.data.items[2]
        else
            self.embedded.readData(2, .Little);
        // std.log.info("height {d}",.{height});
        return height;
    }
    pub fn getSize(self: *WorldDataStruct) u16 {
        const size = self.getWidth() * self.getHeight();
        // std.log.info("size {d}",.{size});
        return size;
    }
    pub fn getLayerIndex(self: *WorldDataStruct, layer: u16) u16 {
        const layer_index = self.offset + (layer * self.getSize());
        // std.log.info("offset {d} layer {d} layer_index {d}",.{self.offset, layer, layer_index});
        return layer_index;
    }
    pub fn getLayerEndIndex(self: *WorldDataStruct, layer: u16) u16 {
        const layer_index = self.getLayerIndex(layer);
        const size = self.getSize();
        // std.log.info("layer_end_index {d}",.{layer_index + size});
        const layer_end_index = layer_index + size;
        return layer_end_index;
    }
    pub fn getCoordinateData(self: *WorldDataStruct, layer: u16, x: u16, y: u16) u16 {
        var index: u16 = self.getLayerIndex(layer);
        index += y * self.getWidth();
        index += x;
        const data = if (self.has_data)
            self.data.items[index]
        else
            self.embedded.readData(index, .Little);
        // std.log.info("getCoordinateData {d}",.{data});
        return data;
    }
    pub fn setCoordinateData(self: *WorldDataStruct, layer: u16, x: u16, y: u16, value: u16) !void {
        try self.readDataFromEmbedded();
        var index: u16 = self.getLayerIndex(layer);
        index += y * self.getWidth();
        index += x;
        if (self.has_data) {
            self.data.items[index] = value;
        }
    }
    pub fn readDataFromEmbedded(self: *WorldDataStruct) !void {
        // TODO: Add a "force" option to do it even if self.has_data
        if (self.has_data) {
            return;
        }
        var max: u16 = self.embedded.getLength();
        max = max / 2; // Note: because the embedded file is using 32-bit or something like that, so you gotta divide
        // std.log.info("max {d}",.{max});
        // std.log.info("file_index {d}",.{self.embedded.file_index});
        try self.data.resize(gpa_allocator.allocator(), max);
        for (0..max) |i| {
            var i_converted = @as(u16, @intCast(i));
            const value = self.embedded.readData(i_converted, .Little);
            // std.log.info("value {d}",.{value});
            self.data.items[i_converted] = value;
            // std.log.info("new_data[i] {d}",.{new_data[i]});
        }
        self.has_data = true;
    }
    // TODO: This is really an editor function and should go into an editor specific area if possible
    pub fn addRow(self: *WorldDataStruct) !void {
        if (self.has_data) {
            // TODO: init w/ initCapacity(new_size), then use appendAssumeCapacity instead of append
            var new_data: std.ArrayListUnmanaged(u16) = .{};
            var current_offset: u16 = self.offset - 1;
            for (self.data.items, 0..) |item, i| {
                if (i == 0) {
                    try new_data.append(allocator, item);
                } else if (i == 1) {
                    try new_data.append(allocator, item);
                } else if (i == 2) {
                    try new_data.append(allocator, item + 1);
                } else {
                    try new_data.append(allocator, item);
                    var leftover: u16 = @as(u16, @intCast(i)) - current_offset;
                    var layer_size = self.getWidth() * self.getHeight();
                    if (leftover % layer_size == 0) {
                        try new_data.appendNTimes(
                            allocator, 
                            0,
                            self.getWidth());
                        current_offset = @intCast(i);
                    }
                }
            }
            self.data.clearAndFree(allocator);
            self.data = new_data;
        }
    }
    // TODO: This is really an editor function and should go into an editor specific area if possible
    pub fn addColumn(self: *WorldDataStruct) !void {
        if (self.has_data) {
            // TODO: init w/ initCapacity(new_size), then use appendAssumeCapacity instead of append
            var new_data: std.ArrayListUnmanaged(u16) = .{};
            var current_offset: u16 = self.offset - 1;
            for (self.data.items, 0..) |item, i| {
                if (i == 0) {
                    try new_data.append(allocator, item);
                } else if (i == 1) {
                    try new_data.append(allocator, item + 1);
                } else if (i == 2) {
                    try new_data.append(allocator, item);
                } else {
                    try new_data.append(allocator, item);
                    // Figure out if we're at the end of a row and add a 0
                    var leftover: u16 = @as(u16, @intCast(i)) - current_offset;
                    if (leftover % self.getWidth() == 0) {
                        try new_data.append(allocator, 0);
                        current_offset = @intCast(i);
                    }
                }
            }
            self.data.clearAndFree(allocator);
            self.data = new_data;
        }
    }
};
test "world_data_struct" {
    var world_data: [3]u16 = .{0, 3, 3};
    var world_data_struct = WorldDataStruct{.data = world_data[0..], .embedded = embeds.embeds[2]};
    try std.testing.expect(world_data_struct.getWidth() == 3);
}
pub const DataType = enum { world, entity };
pub const EmbeddedDataStruct = struct {
    file_index: u16 = undefined,
    // TODO: Eventually, deal with breaking up data into separate binary files or other chunking mechanisms
    pub fn findIndexByFileName(self: *EmbeddedDataStruct, data_type: DataType, index: u16) !bool {
        var buf: [256]u8 = undefined;
        const file_name = switch (data_type) {
            .world => try std.fmt.bufPrint(&buf, "world_{d}.bin", .{index}),
            .entity => try std.fmt.bufPrint(&buf, "entity_{d}.bin", .{index}),
        };

        for (embeds.file_names, 0..) |name, i| {
            if (std.mem.eql(u8, name, file_name)) {
                self.file_index = @intCast(i);
                return true;
            }
        }
        return false;
    }
    pub fn getLength(self: *EmbeddedDataStruct) u16 {
        return @as(u16, @intCast(embeds.embeds[self.file_index].len));
    }
    pub fn readData(self: *EmbeddedDataStruct, index: u16, endian: std.builtin.Endian) u16 {
        // std.log.info("readData({})", .{index});
        const filebytes = embeds.embeds[self.file_index];
        const pulled_value =  std.mem.readInt(u16, filebytes[index * 2..][0..2], endian);
        return pulled_value;
    }
};
const ComponentHealth = @import("components/health.zig").ComponentHealth;
pub const EntityDataStruct = struct {
    offset: u16 = 3,
    data: std.ArrayListUnmanaged(u16) = .{},
    has_data: bool = false,
    embedded: EmbeddedDataStruct = undefined,
    health: ComponentHealth = undefined,
    pub fn setEmbedded(self: *EntityDataStruct, embedded: EmbeddedDataStruct) void {
        self.embedded = embedded;
    }
    pub fn getIndex(self: *EntityDataStruct) u16 {
        const index = if (self.has_data)
            self.data.items[0]
        else
            self.embedded.readData(0, .Little);
        
        // std.log.info("index {d}",.{index});
        return index;
    }
    pub fn readDataFromEmbedded(self: *EntityDataStruct) !void {
        // TODO: Add a "force" option to do it even if self.has_data
        if (self.has_data) {
            return;
        }
        var max: u16 = self.embedded.getLength();
        max = max / 2; // Note: because the embedded file is using 32-bit or something like that, so you gotta divide
        // std.log.info("max {d}",.{max});
        // std.log.info("file_index {d}",.{self.embedded.file_index});
        try self.data.resize(gpa_allocator.allocator(), max);
        for (0..max) |i| {
            var i_converted = @as(u16, @intCast(i));
            const value = self.embedded.readData(i_converted, .Little);
            // std.log.info("value {d}",.{value});
            self.data.items[i_converted] = value;
            // std.log.info("new_data[i] {d}",.{new_data[i]});
        }
        self.has_data = true;
    }
    pub fn loadComponents(self: *EntityDataStruct) !void {
        if (!self.has_data) {
            try self.readDataFromEmbedded();
        }
        if (self.data.items[1] == 33) {
            self.health = ComponentHealth{.default_value = 10, .current_value = self.data.items[2]};
            std.log.info("health component found", .{});
        }
    }
    // pub fn collisionFns
    // pub fn healthFns
    // pub fn movementFns
};
// @wasm
pub fn entityIncrementHealth(entity: u16) u16 {
    // TODO: Add a check to make sure this entity has health component loaded
    entities_list.at(entity).health.incrementHealth();
    return entities_list.at(entity).health.current_value;
}
// @wasm
pub fn entityGetHealth(entity: u16) u16 {
    // TODO: Add a check to make sure this entity has health component loaded
    return entities_list.at(entity).health.current_value;
}

pub var entities_list = std.SegmentedList(EntityDataStruct, 32){};
pub var worlds_list = std.SegmentedList(WorldDataStruct, 32){};
pub var current_world_index: u16 = 0;

// @wasm
pub fn initializeGame() !void {
    for (0..embeds.total_worlds) |i| {
        var embedded_data_struct = EmbeddedDataStruct{};
        _ = try embedded_data_struct.findIndexByFileName(.world, @intCast(i));
        try worlds_list.append(gpa_allocator.allocator(), .{.embedded = embedded_data_struct});
    }
    for (0..embeds.total_entities) |i| {
        var embedded_data_struct = EmbeddedDataStruct{};
        _ = try embedded_data_struct.findIndexByFileName(.entity, @intCast(i));
        try entities_list.append(gpa_allocator.allocator(), .{.embedded = embedded_data_struct});
        try entities_list.at(i).loadComponents();
    }
    loadWorld(current_world_index);
}

// @wasm
pub fn loadWorld(index: u16) void {
    current_world_index = index;
    var w: u16 = undefined;
    var h: u16 = undefined;
    var in_editor: bool = false;
    if (editor.new_new_worlds.items.len > 0) {
        for (editor.new_new_worlds.items) |nw| {
            if (nw.getIndex() == index) {
                in_editor = true;
                w = nw.getWidth();
                h = nw.getHeight();
            }
        }
    }
    if (!in_editor) {
        // w = worlds_list.items[current_world_index].getWidth();
        // h = worlds_list.items[current_world_index].getHeight();
        w = worlds_list.at(current_world_index).getWidth();
        h = worlds_list.at(current_world_index).getHeight();
    }

    if (w < viewport.getSizeWidth()) {
        var leftover = viewport.getSizeWidth() - w;
        if (leftover % 2 > 0) {
            viewport.setPaddingLeft(leftover / 2);
            viewport.setPaddingRight(leftover / 2 + 1);
        } else {
            viewport.setPaddingLeft(leftover / 2);
            viewport.setPaddingRight(leftover / 2);
        }
    }
    if (h < viewport.getSizeHeight()) {
        var leftover = viewport.getSizeHeight() - h;
        if (leftover % 2 > 0) {
            viewport.setPaddingTop(leftover / 2);
            viewport.setPaddingBottom(leftover / 2 + 1);
        } else {
            viewport.setPaddingTop(leftover / 2);
            viewport.setPaddingBottom(leftover / 2);
        }
    }

    // TODO: Check that we have a viewport size
    viewport.initializeViewportData();
    var x: u16 = 0;
    var y: u16 = 0;
    for (0..viewport.getLength()) |i| {
        _ = i;
        if (
            x >= viewport.getPaddingLeft() and
            y >= viewport.getPaddingTop() and
            x < (viewport.getSizeWidth() - viewport.getPaddingRight()) and
            y < (viewport.getSizeHeight() - viewport.getPaddingBottom())
        ) {
            viewport.setData(x, y, 1);
        } else {
            viewport.setData(x, y, 0);
        }

        x += 1;
        if (x >= viewport.getSizeWidth()) {
            y += 1;
            x = 0;
        }
    }
}
// @wasm
pub fn getCurrentWorldIndex() u16 {
    return current_world_index;
}
// @wasm
pub fn getCurrentWorldWidth() u16 {
    // return worlds_list.items[current_world_index].getWidth();
    return worlds_list.at(current_world_index).getWidth();
}

// NOTE: NOT WASM COMPATIBLE
pub fn getFileIndexByName(name: []const u8) usize {
    var file_index: usize = 0;
    for (embeds.file_names, 0..) |file_name, i| {
        if (std.mem.eql(u8, file_name, name)) {
            file_index = i;
        }
    }
    return file_index;
}
// @wasm
pub fn readFromEmbeddedFile(file_index: usize, index: u16, mode: u16) u16 {
    var file = embeds.embeds[file_index];
    const adjusted_index = index * 2;

    var pulled_value: u16 = 0;
    if (mode == 0) {
        // Little Endian Mode
        pulled_value = (@as(u16, @intCast(file[adjusted_index + 1])) << 8 | @as(u16, @intCast(file[adjusted_index])));
    } else if (mode == 1) {
        // Big Endian Mode
        pulled_value = (@as(u16, @intCast(file[adjusted_index])) << 8 | @as(u16, @intCast(file[adjusted_index + 1])));
    }

    return pulled_value;
}

// @wasm
pub fn getWorldData(world: u16, layer: u16, x: u16, y: u16) u16 {
    if (editor.new_new_worlds.items.len > 0) {
        for (editor.new_new_worlds.items) |nw| {
            if (nw.getIndex() == world) {
                return nw.getCoordinateData(layer, x, y);
            }
        }
    }
    if (world >= embeds.total_worlds) {
        var offset_index: u16 = world - embeds.total_worlds;
        // iterate over editor.world_layer until you get a match
        var cursor: u16 = 0;
        var layer_index: u16 = 0;
        while (cursor < editor.world_layer.items.len) {
            var e_world: u16 = editor.world_layer.items[cursor];
            var e_layer: u16 = editor.world_layer.items[(cursor + 1)];
            if (e_world == offset_index and e_layer == layer) {
                layer_index = layer;
                break;
            }
            cursor += 2;
        }
        var w = editor.worlds.items[offset_index].items[0];
        var index: u16 = y * w * x + 1; // +1 = layer type
        return editor.layers.items[layer_index].items[index];
    } else {
        // return worlds_list.items[world].getCoordinateData(layer, x, y);
        return worlds_list.at(world).getCoordinateData(layer, x, y);
    }
}
// @wasm
pub fn setWorldData(world: u16, layer: u16, x: u16, y: u16, value: u16) !void {
    // TODO: Actually figure out instances where you truly need to add this diff
    try diff.addData(0);
    
    for (editor.new_new_worlds.items) |nw| {
        if (nw.getIndex() == world) {
            try nw.setCoordinateData(layer, x, y, value);
        }
    }
    
    if (world >= embeds.total_worlds) {
        var offset_index: u16 = world - embeds.total_worlds;
        // iterate over editor.world_layer until you get a match
        var cursor: u16 = 0;
        var layer_index: u16 = 0;
        while (cursor < editor.world_layer.items.len) {
            var e_world: u16 = editor.world_layer.items[cursor];
            var e_layer: u16 = editor.world_layer.items[(cursor + 1)];
            if (e_world == offset_index and e_layer == layer) {
                layer_index = layer;
                break;
            }
            cursor += 2;
        }
        var w = editor.worlds.items[offset_index].items[0];
        var index: u16 = y * w * x + 1; // +1 = layer type
        editor.layers.items[layer_index].items[index] = value;
    } else {
        // worlds_list.items[world].setCoordinateData(layer, x, y, value);
        try worlds_list.at(world).setCoordinateData(layer, x, y, value);
    }
}

// @wasm
pub fn getWorldAtViewport(layer: u16, x: u16, y: u16) u16 {
    // TODO: Camera offset and all that
    if (
        x >= viewport.getPaddingLeft() and
        y >= viewport.getPaddingTop() and
        x < (viewport.getSizeWidth() - viewport.getPaddingRight()) and
        y < (viewport.getSizeHeight() - viewport.getPaddingBottom())
    ) {
        var world_x = x - viewport.getPaddingLeft();
        var world_y = y - viewport.getPaddingTop();
        return getWorldData(current_world_index, layer, world_x, world_y); 
    }
    return 0;
}
// @wasm
pub fn translateViewportXToWorldX(x: u16) u16 {
    return x - viewport.getPaddingLeft();
}
// @wasm
pub fn translateViewportYToWorldY(y: u16) u16 {
    return y - viewport.getPaddingTop();
}

// --------------------------------------
// TESTS
test "string_stuff" {
    const str = try std.fmt.allocPrint(allocator, "world_{d}_layer_{d}.bin", .{0, 0});
    try std.testing.expect(std.mem.eql(u8, str, "world_0_layer_0.bin"));
}

test "raw_enums" {
    var enumint: u16 = helpers.enumToU16(enums.WorldsEnum, enums.WorldsEnum.World1);
    var some_value: u16 = 0;
    try std.testing.expect(enumint == 0);
    try std.testing.expect(some_value == @intFromEnum(enums.WorldsEnum.World1));
}

test "entity_components" {
    var entity: [3]u16 = .{ 2, 0, 0 };
    try std.testing.expect(entity[0] == 2);
    const health = @import("components/health.zig");
    std.debug.print("\n{s}\n", .{@typeName(health)});
    // entity[2] = health;
    // try std.testing.expect(entity[2].default_value == 10);
}
