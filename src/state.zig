const std = @import("std");
const Allocator = std.mem.Allocator;
const zua = @import("zua.zig");
const GC = zua.gc.GC;
const Table = zua.object.Table;
const Thread = zua.object.Thread;
const Closure = zua.object.Closure;
const String = zua.object.String;
const Value = zua.object.Value;

// =============================================================================
// Lua State
// =============================================================================

pub const LuaState = struct {
    allocator: Allocator,
    gc: GC,
    main_thread: *Thread,
    globals: *Table,
    registry: *Table,
    
    pub fn init(allocator: Allocator) !*LuaState {
        const state = try allocator.create(LuaState);
        
        const gc = GC.init(allocator);
        const main_thread = try Thread.init(allocator, 1024);
        const globals = main_thread.globals;
        const registry = main_thread.registry;
        
        state.* = .{
            .allocator = allocator,
            .gc = gc,
            .main_thread = main_thread,
            .globals = globals,
            .registry = registry,
        };
        
        try state.initGlobals();
        return state;
    }
    
    pub fn deinit(self: *LuaState) void {
        self.main_thread.deinit();
        self.allocator.destroy(self);
    }
    
    fn initGlobals(self: *LuaState) !void {
        // TODO: Initialize global environment with standard libraries
    }
    
    pub fn getGlobal(self: *LuaState, name: []const u8) !Value {
        const str = try String.init(self.allocator, name);
        return self.globals.get(.{ .string = str });
    }
    
    pub fn setGlobal(self: *LuaState, name: []const u8, value: Value) !void {
        const str = try String.init(self.allocator, name);
        try self.globals.set(.{ .string = str }, value);
    }
    
    pub fn getRegistry(self: *LuaState, key: Value) Value {
        return self.registry.get(key);
    }
    
    pub fn setRegistry(self: *LuaState, key: Value, value: Value) !void {
        try self.registry.set(key, value);
    }
    
    pub fn createThread(self: *LuaState) !*Thread {
        return try Thread.init(self.allocator, 1024);
    }
    
    pub fn collectGarbage(self: *LuaState) void {
        self.gc.collect();
    }
};

// =============================================================================
// Registry Keys
// =============================================================================

pub const Registry = struct {
    pub const LUA_RIDX_MAINTHREAD = Value{ .number = 1.0 };
    pub const LUA_RIDX_GLOBALS = Value{ .number = 2.0 };
    pub const LUA_RIDX_LAST = Value{ .number = 3.0 };
};

// =============================================================================
// Tests
// =============================================================================

test "LuaState init" {
    const allocator = std.testing.allocator;
    var state = try LuaState.init(allocator);
    defer state.deinit();
    
    try std.testing.expect(state.main_thread != null);
    try std.testing.expect(state.globals != null);
    try std.testing.expect(state.registry != null);
}

test "LuaState globals" {
    const allocator = std.testing.allocator;
    var state = try LuaState.init(allocator);
    defer state.deinit();
    
    const test_value = Value{ .number = 42.0 };
    try state.setGlobal("test", test_value);
    const retrieved = try state.getGlobal("test");
    try std.testing.expect(Value.eql(retrieved, test_value));
}
