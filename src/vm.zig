const std = @import("std");
const Allocator = std.mem.Allocator;
const zua = @import("zua.zig");
const Instruction = zua.opcodes.Instruction;
const OpCode = zua.opcodes.OpCode;
const Value = zua.object.Value;
const Table = zua.object.Table;
const String = zua.object.String;
const Closure = zua.object.Closure;
const CClosure = zua.object.CClosure;
const Function = zua.object.Function;
const Constant = zua.object.Constant;
const UpValue = zua.object.UpValue;
const Thread = zua.object.Thread;
const CFunction = zua.object.CFunction;
const stdlib = @import("stdlib.zig");

// Error set for VM operations
pub const VmError = error{
    StackOverflow,
    ExpectedTable,
    AttemptToCallNonFunction,
    AttemptToPerformArithmetic,
    AttemptToConcatenate,
    AttemptToGetLength,
    TableIndexIsNil,
    RuntimeError,
    OutOfMemory,
};

// =============================================================================
// Lua State
// =============================================================================

pub const LuaState = struct {
    allocator: Allocator,
    thread: *Thread,
    gc: GC,
    
    // Global state
    globals: *Table,
    registry: *Table,
    
    // String interning
    string_pool: std.HashMap(u64, *String, StringHashContext, std.hash_map.default_max_load_percentage),
    
    // Stack
    top: usize = 0,
    stack: []Value,
    stack_size: usize,
    
    // Call info
    ci: CallInfo,
    base_ci: std.ArrayList(CallInfo),
    
    // Open upvalues
    open_upval: ?*UpValue = null,
    
    // Error handling
    errfunc: i32 = 0,
    
    // String hash context for interning
    const StringHashContext = struct {
        pub fn hash(self: @This(), hash: u64) u32 {
            _ = self;
            return @as(u32, @truncate(hash));
        }
        
        pub fn eql(self: @This(), a: u64, b: u64) bool {
            _ = self;
            return a == b;
        }
    };
    
    const Self = @This();

    pub fn init(allocator: Allocator) !*Self {
        const ptr = try allocator.create(Self);
        const stack = try allocator.alloc(Value, 1024);
        @memset(stack, .nil);
        
        ptr.gc = GC.init(allocator);
        
        const thread = try Thread.initWithGC(allocator, &ptr.gc, 1024);
        
        const globals = try Table.initWithGC(allocator, &ptr.gc);
        
        const registry = try Table.initWithGC(allocator, &ptr.gc);
        
        // Set GC roots
        const roots = GC.Roots{
            .globals = globals,
            .registry = registry,
            .main_thread = thread,
        };
        ptr.gc.setRoots(roots);
        
        ptr.* = .{
            .allocator = allocator,
            .thread = thread,
            .gc = ptr.gc,
            .globals = globals,
            .registry = registry,
            .string_pool = std.HashMap(u64, *String, StringHashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .top = 0,
            .stack = stack,
            .stack_size = 1024,
            .ci = .{},
            .base_ci = .empty,
        };
        
        try ptr.base_ci.append(ptr.allocator, .{});
        
        // Open standard libraries
        stdlib.openLibs(ptr);
        
        return ptr;
    }

    pub fn deinit(self: *Self) void {
        self.thread.deinit();
        self.globals.deinit();
        self.allocator.destroy(self.globals);
        self.registry.deinit();
        self.allocator.destroy(self.registry);
        // Clear string pool
        var it = self.string_pool.iterator();
        while (it.next()) |entry| {
            const str = entry.value_ptr.*;
            str.deinit(self.allocator);
        }
        self.string_pool.deinit();
        self.allocator.free(self.stack);
        self.base_ci.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn getTop(self: *Self) i32 {
        return @intCast(self.top);
    }

    pub fn setTop(self: *Self, idx: i32) void {
        const new_top: usize = if (idx >= 0) @intCast(idx) else self.top - @as(usize, @intCast(-idx));
        while (self.top < new_top) : (self.top += 1) {
            self.stack[self.top] = .nil;
        }
        self.top = new_top;
    }

    pub fn push(self: *Self, value: Value) !void {
        if (self.top >= self.stack.len) {
            return error.StackOverflow;
        }
        self.stack[self.top] = value;
        self.top += 1;
    }

    pub fn pop(self: *Self) Value {
        std.debug.assert(self.top > 0);
        self.top -= 1;
        return self.stack[self.top];
    }

    pub fn pushValue(self: *Self, value: Value) !void {
        try self.push(value);
    }

    pub fn toValue(self: *Self, idx: i32) Value {
        if (idx > 0) {
            const uidx: usize = @intCast(idx);
            if (uidx <= self.top) {
                return self.stack[uidx - 1];
            }
        } else if (idx < 0) {
            const uidx: usize = self.top - @as(usize, @intCast(-idx));
            if (uidx < self.top) {
                return self.stack[uidx];
            }
        }
        return .nil;
    }

    pub fn toNumber(self: *Self, idx: i32) ?f64 {
        const val = self.toValue(idx);
        return switch (val) {
            .number => |n| n,
            .string => |s| std.fmt.parseFloat(f64, s.asSlice()) catch null,
            else => null,
        };
    }

    pub fn toBoolean(self: *Self, idx: i32) bool {
        return self.toValue(idx).toBoolean();
    }

    pub fn toString(self: *Self, idx: i32) ?[]const u8 {
        const val = self.toValue(idx);
        return switch (val) {
            .string => |s| s.asSlice(),
            else => null,
        };
    }

    pub fn toTable(self: *Self, idx: i32) ?*Table {
        const val = self.toValue(idx);
        return switch (val) {
            .table => |t| t,
            else => null,
        };
    }

    pub fn typeName(self: *Self, idx: i32) []const u8 {
        return self.toValue(idx).getTypeName();
    }

    pub fn pushNil(self: *Self) !void {
        try self.push(.nil);
    }

    pub fn pushNumber(self: *Self, n: f64) !void {
        try self.push(.{ .number = n });
    }

    pub fn pushBoolean(self: *Self, b: bool) !void {
        try self.push(.{ .boolean = b });
    }

    pub fn internString(self: *Self, s: []const u8) !*String {
        const hash = std.hash.Wyhash.hash(0, s);
        
        // Check if string already exists in pool
        if (self.string_pool.get(hash)) |str| {
            // Check if content matches (hash collision protection)
            if (str.len == s.len and std.mem.eql(u8, str.asSlice(), s)) {
                return str;
            }
        }
        
        // Create new string and add to pool
        const str = try String.initWithGC(self.allocator, &self.gc, s);
        try self.string_pool.put(hash, str);
        return str;
    }

    pub fn pushString(self: *Self, s: []const u8) !void {
        const str = try self.internString(s);
        try self.push(.{ .string = str });
    }

    pub fn pushTable(self: *Self) !*Table {
        const table = try Table.initWithGC(self.allocator, &self.gc);
        try self.push(.{ .table = table });
        return table;
    }

    pub fn pushCFunction(self: *Self, f: CFunction) !void {
        const cclosure = try CClosure.initWithGC(self.allocator, &self.gc, f, 0);
        try self.push(.{ .c_closure = cclosure });
    }

    pub fn setGlobal(self: *Self, name: []const u8) !void {
        const value = self.pop();
        const str = try self.internString(name);
        try self.globals.set(.{ .string = str }, value);
    }

    pub fn getGlobal(self: *Self, name: []const u8) !void {
        const str = try self.internString(name);
        const value = self.globals.get(.{ .string = str });
        try self.push(value);
    }

    pub fn setField(self: *Self, idx: i32, k: []const u8) !void {
        const t = self.toTable(idx) orelse return error.ExpectedTable;
        const v = self.pop();
        const str = try self.internString(k);
        try t.set(.{ .string = str }, v);
    }

    pub fn getField(self: *Self, idx: i32, k: []const u8) !void {
        const t = self.toTable(idx) orelse {
            try self.push(.nil);
            return;
        };
        const str = try self.internString(k);
        const v = t.get(.{ .string = str });
        try self.push(v);
    }

    pub fn setTable(self: *Self, idx: i32) !void {
        const t = self.toTable(idx) orelse return error.ExpectedTable;
        const v = self.pop();
        const k = self.pop();
        try t.set(k, v);
    }

    pub fn getTable(self: *Self, idx: i32) !void {
        const t = self.toTable(idx) orelse {
            try self.push(.nil);
            return;
        };
        const k = self.pop();
        const v = t.get(k);
        try self.push(v);
    }

    pub fn rawEqual(self: *Self, idx1: i32, idx2: i32) bool {
        return Value.eql(self.toValue(idx1), self.toValue(idx2));
    }

    pub fn isNil(self: *Self, idx: i32) bool {
        return self.toValue(idx) == .nil;
    }

    pub fn isNone(self: *Self, idx: i32) bool {
        return self.toValue(idx) == .none;
    }

    pub fn isNoneOrNil(self: *Self, idx: i32) bool {
        const v = self.toValue(idx);
        return v == .none or v == .nil;
    }

    pub fn isTable(self: *Self, idx: i32) bool {
        return self.toValue(idx) == .table;
    }

    pub fn isFunction(self: *Self, idx: i32) bool {
        const v = self.toValue(idx);
        return v == .closure or v == .c_closure;
    }

    pub fn isNumber(self: *Self, idx: i32) bool {
        return self.toValue(idx) == .number;
    }

    pub fn isString(self: *Self, idx: i32) bool {
        return self.toValue(idx) == .string;
    }

    pub fn isBoolean(self: *Self, idx: i32) bool {
        return self.toValue(idx) == .boolean;
    }

    // Create a new table at the top of the stack
    pub fn newTable(self: *Self) !void {
        _ = try self.pushTable();
    }

    // Get the length of a value
    pub fn objLen(self: *Self, idx: i32) usize {
        const v = self.toValue(idx);
        return switch (v) {
            .string => |s| s.len,
            .table => |t| t.length(),
            else => 0,
        };
    }

    pub fn len(self: *Self, idx: i32) !void {
        const v = self.toValue(idx);
        const len_val: Value = switch (v) {
            .string => |s| .{ .number = @floatFromInt(s.len) },
            .table => |t| .{ .number = @floatFromInt(t.length()) },
            else => return error.InvalidType,
        };
        try self.push(len_val);
    }

    pub fn concat(self: *Self, n: i32) !void {
        if (n == 0) {
            try self.push(.{ .string = try self.internString("") });
            return;
        }
        
        // Simple concatenation for now
        var total_len: usize = 0;
        const start = self.top - @as(usize, @intCast(n));
        
        for (start..self.top) |i| {
            if (self.stack[i] == .string) {
                total_len += self.stack[i].string.len;
            }
        }
        
        var result = try std.ArrayList(u8).initCapacity(self.allocator, total_len);
        
        for (start..self.top) |i| {
            if (self.stack[i] == .string) {
                try result.appendSlice(self.allocator, self.stack[i].string.asSlice());
            }
        }
        
        const items = try result.toOwnedSlice(self.allocator);
        const str = try self.internString(items);
        self.allocator.free(items);
        
        self.top = start;
        try self.push(.{ .string = str });
    }

    pub fn next(self: *Self, idx: i32) i32 {
        const t = self.toTable(idx) orelse return 0;
        const key = self.pop();
        
        if (t.next(key)) |kv| {
            self.push(kv.key) catch return 0;
            self.push(kv.value) catch return 0;
            return 2;
        }
        
        self.push(.nil) catch return 0;
        return 1;
    }

    // Error handling
    pub fn errorHandle(self: *Self, msg: []const u8) !void {
        _ = self;
        _ = msg;
        return error.RuntimeError;
    }

    // Insert a value at a specific position in the stack
    pub fn insert(self: *Self, idx: i32) !void {
        const pos: usize = if (idx > 0) @intCast(idx - 1) else self.top - @as(usize, @intCast(-idx));
        if (pos >= self.top) return;
        
        const val = self.stack[self.top - 1];
        var i: usize = self.top - 1;
        while (i > pos) : (i -= 1) {
            self.stack[i] = self.stack[i - 1];
        }
        self.stack[pos] = val;
    }

    // Load a chunk from source
    pub fn load(self: *Self, source: []const u8, name: []const u8) !void {
        const func = try zua.compiler.compile(self.allocator, source);
        const closure = try Closure.initWithGC(self.allocator, &self.gc, func);
        try self.push(.{ .closure = closure });
        
        // Set the name in constants if provided
        _ = name;
    }

    // Call a function
    pub fn call(self: *Self, num_args: i32, num_results: i32) !void {
        const func_idx = self.top - @as(usize, @intCast(num_args + 1));
        const func = self.stack[func_idx];
        
        switch (func) {
            .closure => |closure| {
                try self.callLua(closure, num_args, num_results);
            },
            .c_closure => |cclosure| {
                try self.callC(cclosure, num_args, num_results);
            },
            else => {
                return error.AttemptToCallNonFunction;
            },
        }
    }

    fn callLua(self: *Self, closure: *Closure, num_args: i32, num_results: i32) !void {
        const proto = closure.proto;
        
        // Save current call info
        const old_ci = self.ci;
        
        // Set up new call frame
        const base = self.top - @as(usize, @intCast(num_args)) - 1;
        
        // Ensure stack space
        if (self.top + proto.max_stack_size >= self.stack.len) {
            return error.StackOverflow;
        }
        
        // Set up new call info
        self.ci = .{
            .func = .{ .closure = closure },
            .base = base,
            .saved_pc = 0,
            .num_results = num_results,
            .is_lua = true,
        };
        
        // Extend stack for local variables
        while (self.top < base + proto.max_stack_size) : (self.top += 1) {
            self.stack[self.top] = .nil;
        }
        
        // Execute the function
        try self.executeLua();
        
        // Restore call info
        self.ci = old_ci;
    }

    fn callC(self: *Self, cclosure: *CClosure, num_args: i32, num_results: i32) !void {
        _ = num_results;
        
        const old_top = self.top;
        
        // Call the C function
        const nresults = cclosure.func(@ptrCast(self));
        
        // Adjust stack
        if (nresults == 0) {
            self.top = old_top - @as(usize, @intCast(num_args + 1));
        } else {
            // Keep nresults values on stack
            const new_top = old_top - @as(usize, @intCast(num_args + 1)) + @as(usize, @intCast(nresults));
            self.top = new_top;
        }
    }

    // Execute Lua bytecode
    fn executeLua(self: *Self) VmError!void {
        const current_closure = self.ci.func.closure;
        const proto = current_closure.proto;
        const code = proto.code;
        const constants = proto.constants;
        const base = self.ci.base;
        
        var pc: usize = 0;
        
        while (pc < code.len) {
            const instruction = code[pc];
            const op = instruction.op;
            
            switch (op) {
                .move => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    self.stack[base + a] = self.stack[base + b];
                },
                .loadk => {
                    const abx: Instruction.ABx = @bitCast(instruction);
                    const a = abx.a;
                    const bx = abx.bx;
                    const constant = constants[bx];
                    self.stack[base + a] = switch (constant) {
                        .nil => Value.nil,
                        .boolean => |b| .{ .boolean = b },
                        .number => |n| .{ .number = n },
                        .string => |s| .{ .string = try String.init(self.allocator, s) },
                    };
                },
                .loadbool => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    self.stack[base + a] = .{ .boolean = b != 0 };
                    if (c != 0) pc += 1;
                },
                .loadnil => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    for (a..@intCast(b + 1)) |i| {
                        self.stack[base + i] = .nil;
                    }
                },
                .getglobal => {
                    const abx: Instruction.ABx = @bitCast(instruction);
                    const a = abx.a;
                    const bx = abx.bx;
                    const name_const = constants[bx];
                    if (name_const == .string) {
                        const name_str = try String.init(self.allocator, name_const.string);
                        const value = self.globals.get(.{ .string = name_str });
                        self.stack[base + a] = value;
                    }
                },
                .setglobal => {
                    const abx: Instruction.ABx = @bitCast(instruction);
                    const a = abx.a;
                    const bx = abx.bx;
                    const name_const = constants[bx];
                    if (name_const == .string) {
                        const name_str = try String.init(self.allocator, name_const.string);
                        try self.globals.set(.{ .string = name_str }, self.stack[base + a]);
                    }
                },
                .gettable => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const table_val = self.stack[base + b];
                    if (table_val != .table) {
                        return error.ExpectedTable;
                    }
                    
                    const key = if (zua.opcodes.rkIsConstant(c))
                        self.constantToValue(constants[zua.opcodes.rkGetConstantIndex(c)])
                    else
                        self.stack[base + c];
                    
                    self.stack[base + a] = table_val.table.get(key);
                },
                .settable => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const table_val = self.stack[base + a];
                    if (table_val != .table) {
                        return error.ExpectedTable;
                    }
                    
                    const key = if (zua.opcodes.rkIsConstant(b))
                        self.constantToValue(constants[zua.opcodes.rkGetConstantIndex(b)])
                    else
                        self.stack[base + b];
                    
                    const value = if (zua.opcodes.rkIsConstant(c))
                        self.constantToValue(constants[zua.opcodes.rkGetConstantIndex(c)])
                    else
                        self.stack[base + c];
                    
                    try table_val.table.set(key, value);
                },
                .newtable => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const table = try Table.initWithGC(self.allocator, &self.gc);
                    self.stack[base + a] = .{ .table = table };
                },
                .self => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const table_val = self.stack[base + b];
                    if (table_val != .table) {
                        return error.ExpectedTable;
                    }
                    
                    const key = if (zua.opcodes.rkIsConstant(c))
                        self.constantToValue(constants[zua.opcodes.rkGetConstantIndex(c)])
                    else
                        self.stack[base + c];
                    
                    const method = table_val.table.get(key);
                    self.stack[base + a] = method;
                    self.stack[base + a + 1] = table_val;
                },
                .add => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const lhs = if (zua.opcodes.rkIsConstant(b))
                        self.constantToValue(constants[zua.opcodes.rkGetConstantIndex(b)])
                    else
                        self.stack[base + b];
                    
                    const rhs = if (zua.opcodes.rkIsConstant(c))
                        self.constantToValue(constants[zua.opcodes.rkGetConstantIndex(c)])
                    else
                        self.stack[base + c];
                    
                    if (lhs == .number and rhs == .number) {
                        self.stack[base + a] = .{ .number = lhs.number + rhs.number };
                    } else {
                        // Try metamethod
                        return error.AttemptToPerformArithmetic;
                    }
                },
                .sub => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const lhs = self.getValueRK(base, constants, b);
                    const rhs = self.getValueRK(base, constants, c);
                    
                    if (lhs == .number and rhs == .number) {
                        self.stack[base + a] = .{ .number = lhs.number - rhs.number };
                    } else {
                        return error.AttemptToPerformArithmetic;
                    }
                },
                .mul => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const lhs = self.getValueRK(base, constants, b);
                    const rhs = self.getValueRK(base, constants, c);
                    
                    if (lhs == .number and rhs == .number) {
                        self.stack[base + a] = .{ .number = lhs.number * rhs.number };
                    } else {
                        return error.AttemptToPerformArithmetic;
                    }
                },
                .div => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const lhs = self.getValueRK(base, constants, b);
                    const rhs = self.getValueRK(base, constants, c);
                    
                    if (lhs == .number and rhs == .number) {
                        self.stack[base + a] = .{ .number = lhs.number / rhs.number };
                    } else {
                        return error.AttemptToPerformArithmetic;
                    }
                },
                .mod => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const lhs = self.getValueRK(base, constants, b);
                    const rhs = self.getValueRK(base, constants, c);
                    
                    if (lhs == .number and rhs == .number) {
                        self.stack[base + a] = .{ .number = @mod(lhs.number, rhs.number) };
                    } else {
                        return error.AttemptToPerformArithmetic;
                    }
                },
                .pow => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const lhs = self.getValueRK(base, constants, b);
                    const rhs = self.getValueRK(base, constants, c);
                    
                    if (lhs == .number and rhs == .number) {
                        self.stack[base + a] = .{ .number = std.math.pow(f64, lhs.number, rhs.number) };
                    } else {
                        return error.AttemptToPerformArithmetic;
                    }
                },
                .unm => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    
                    const val = self.stack[base + b];
                    if (val == .number) {
                        self.stack[base + a] = .{ .number = -val.number };
                    } else {
                        return error.AttemptToPerformArithmetic;
                    }
                },
                .not => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    
                    self.stack[base + a] = .{ .boolean = self.stack[base + b].isFalsy() };
                },
                .len => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    
                    const val = self.stack[base + b];
                    self.stack[base + a] = switch (val) {
                        .string => |s| .{ .number = @floatFromInt(s.len) },
                        .table => |t| .{ .number = @floatFromInt(t.length()) },
                        else => return error.AttemptToGetLength,
                    };
                },
                .concat => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    // Concatenate values from b to c
                    var total_len: usize = 0;
                    for (b..@intCast(c + 1)) |i| {
                        if (self.stack[base + i] == .string) {
                            total_len += self.stack[base + i].string.len;
                        } else {
                            return error.AttemptToConcatenate;
                        }
                    }
                    
                    var result = try std.ArrayList(u8).initCapacity(self.allocator, total_len);
                    for (b..@intCast(c + 1)) |i| {
                        try result.appendSlice(self.allocator, self.stack[base + i].string.asSlice());
                    }
                    
                    const items = try result.toOwnedSlice(self.allocator);
                    const str = try String.init(self.allocator, items);
                    self.allocator.free(items);
                    
                    self.stack[base + a] = .{ .string = str };
                },
                .jmp => {
                    const asbx: Instruction.AsBx = @bitCast(instruction);
                    const offset = asbx.getSignedBx();
                    pc = @intCast(@as(isize, @intCast(pc)) + offset + 1);
                    continue;
                },
                .eq => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const lhs = self.getValueRK(base, constants, b);
                    const rhs = self.getValueRK(base, constants, c);
                    
                    const is_equal = Value.eql(lhs, rhs);
                    if (is_equal == (a == 0)) {
                        // Jump if condition matches
                        pc += 1;
                    }
                },
                .lt => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const lhs = self.getValueRK(base, constants, b);
                    const rhs = self.getValueRK(base, constants, c);
                    
                    const is_less = Value.lt(lhs, rhs);
                    if (is_less == (a == 0)) {
                        pc += 1;
                    }
                },
                .le => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const lhs = self.getValueRK(base, constants, b);
                    const rhs = self.getValueRK(base, constants, c);
                    
                    const is_less_or_equal = Value.le(lhs, rhs);
                    if (is_less_or_equal == (a == 0)) {
                        pc += 1;
                    }
                },
                .@"test" => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const c = abc.c;
                    
                    const val = self.stack[base + a];
                    const is_truthy = val.isTruthy();
                    if (is_truthy == (c == 0)) {
                        pc += 1;
                    }
                },
                .testset => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const val = self.stack[base + b];
                    const is_truthy = val.isTruthy();
                    if (is_truthy == (c != 0)) {
                        self.stack[base + a] = val;
                    } else {
                        pc += 1;
                    }
                },
                .forloop, .forprep => {
                    const asbx: Instruction.AsBx = @bitCast(instruction);
                    const a = asbx.a;
                    const offset = asbx.getSignedBx();
                    
                    if (instruction.op == .forprep) {
                        // Initialize loop: R(A)-=R(A+2); pc+=sBx
                        const idx = self.stack[base + a];
                        const step = self.stack[base + a + 2];
                        
                        if (idx == .number and step == .number) {
                            self.stack[base + a] = .{ .number = idx.number - step.number };
                        }
                        pc = @intCast(@as(isize, @intCast(pc)) + offset + 1);
                    } else {
                        // forloop: R(A)+=R(A+2); if R(A)<?=R(A+1) then pc+=sBx
                        const idx = self.stack[base + a];
                        const limit = self.stack[base + a + 1];
                        const step = self.stack[base + a + 2];
                        
                        if (idx == .number and limit == .number and step == .number) {
                            const new_idx = idx.number + step.number;
                            self.stack[base + a] = .{ .number = new_idx };
                            self.stack[base + a + 3] = .{ .number = new_idx };
                            
                            const in_range = if (step.number > 0) 
                                new_idx <= limit.number 
                            else 
                                new_idx >= limit.number;
                            
                            if (in_range) {
                                pc = @intCast(@as(isize, @intCast(pc)) + offset + 1);
                            }
                        }
                    }
                },
                .tforloop => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    _ = abc.c;
                    
                    // R(A), R(A+1), R(A+2) = iterator state
                    // Call iterator: R(A+3), R(A+4), R(A+5) = R(A)(R(A+1), R(A+2))
                    const func = self.stack[base + a];
                    
                    if (func == .nil) {
                        // End iteration
                        pc += 1;
                    } else {
                        // Get iterator function, state, and control variable
                        const state = self.stack[base + a + 1];
                        const control = self.stack[base + a + 2];
                        
                        // Push function, state, control
                        try self.push(func);
                        try self.push(state);
                        try self.push(control);
                        
                        // Call iterator function
                        try self.call(2, 3);
                        
                        // Get results
                        _ = self.stack[base + a + 1];
                        _ = self.stack[base + a + 2];
                        const value = self.stack[base + a + 3];
                        
                        // If iterator returns nil, end iteration
                        if (value == .nil) {
                            pc += 1;
                        }
                    }
                },
                .closure => {
                    const abx: Instruction.ABx = @bitCast(instruction);
                    const a = abx.a;
                    const bx = abx.bx;
                    
                    // Create closure from prototype at index bx
                    if (bx < proto.protos.len) {
                        const child_proto = proto.protos[bx];
                        const closure = try Closure.initWithGC(self.allocator, &self.gc, child_proto);
                        self.stack[base + a] = .{ .closure = closure };
                    } else {
                        self.stack[base + a] = .nil;
                    }
                },
                .getupval => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    
                    // Get upvalue from current closure
                    if (current_closure.upvalues.len > b) {
                        if (current_closure.upvalues[b]) |upval| {
                            self.stack[base + a] = upval.value.*;
                        } else {
                            self.stack[base + a] = .nil;
                        }
                    } else {
                        self.stack[base + a] = .nil;
                    }
                },
                .setupval => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    
                    // Set upvalue in current closure
                    if (current_closure.upvalues.len > b) {
                        if (current_closure.upvalues[b]) |upval| {
                            upval.value.* = self.stack[base + a];
                        }
                    }
                },
                .call => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    // Save state
                    const saved_base = base;
                    const saved_pc = pc;
                    
                    // Call the function at position a
                    const func = self.stack[base + a];
                    const num_args: i32 = if (b > 0) @intCast(b - 1) else @intCast(self.top - base - a - 1);
                    const num_results: i32 = if (c > 0) @intCast(c - 1) else -1;
                    
                    // Move function to correct position if needed
                    self.ci.base = base + a;
                    
                    switch (func) {
                        .closure => |closure| {
                            try self.callLua(closure, num_args, num_results);
                        },
                        .c_closure => |cclosure| {
                            try self.callC(cclosure, num_args, num_results);
                        },
                        else => {
                            return error.AttemptToCallNonFunction;
                        },
                    }
                    
                    // Restore state
                    self.ci.base = saved_base;
                    pc = saved_pc;
                },
                .tailcall => {
                    // Tail call: similar to call followed by return
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    
                    const func = self.stack[base + a];
                    const num_args: i32 = if (b > 0) @intCast(b - 1) else @intCast(self.top - base - a - 1);
                    
                    // Move function and args to base
                    for (0..@intCast(num_args + 1)) |i| {
                        self.stack[base + i] = self.stack[base + a + i];
                    }
                    
                    switch (func) {
                        .closure => |closure| {
                            try self.callLua(closure, num_args, self.ci.num_results);
                        },
                        .c_closure => |cclosure| {
                            try self.callC(cclosure, num_args, self.ci.num_results);
                        },
                        else => {
                            return error.AttemptToCallNonFunction;
                        },
                    }
                    return;
                },
                .@"return" => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    
                    const num_results: ?usize = if (b == 0) null else b - 1;
                    const num_wanted = self.ci.num_results;
                    
                    if (num_wanted < 0) {
                        // Return all values
                        if (num_results) |n| {
                            self.top = base + a + n;
                        }
                    } else {
                        // Return exactly num_wanted values
                        const wanted: usize = @intCast(num_wanted);
                        if (num_results) |n| {
                            // Copy results
                            for (0..@min(wanted, n)) |i| {
                                self.stack[base - 1 + i] = self.stack[base + a + i];
                            }
                            // Fill remaining with nil
                            for (n..wanted) |i| {
                                self.stack[base - 1 + i] = .nil;
                            }
                        } else {
                            // Multiple returns
                            for (0..wanted) |i| {
                                self.stack[base - 1 + i] = .nil;
                            }
                        }
                        self.top = base - 1 + wanted;
                    }
                    
                    return;
                },
                .setlist => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    const c = abc.c;
                    
                    const table_val = self.stack[base + a];
                    if (table_val != .table) {
                        return error.ExpectedTable;
                    }
                    
                    const offset: usize = if (c == 0) blk: {
                        pc += 1;
                        const extra: u32 = @bitCast(code[pc]);
                        break :blk extra;
                    } else @intCast(c - 1);
                    
                    const start_idx = offset * 50;
                    
                    for (0..@intCast(b)) |i| {
                        const idx: usize = start_idx + i + 1;
                        try table_val.table.set(.{ .number = @floatFromInt(idx) }, self.stack[base + a + 1 + i]);
                    }
                },
                .vararg => {
                    const abc: Instruction.ABC = @bitCast(instruction);
                    const a = abc.a;
                    const b = abc.b;
                    
                    const num_wanted: ?usize = if (b == 0) null else b - 1;
                    
                    // TODO: Implement proper vararg handling
                    // For now, just fill with nil
                    if (num_wanted) |n| {
                        for (0..n) |i| {
                            self.stack[base + a + i] = .nil;
                        }
                    } else {
                        // Multiple returns - leave as is
                    }
                },
            }
            
            pc += 1;
        }
    }

    fn getValueRK(self: *Self, base: usize, constants: []const Constant, rk: u9) Value {
        return if (zua.opcodes.rkIsConstant(rk))
            self.constantToValue(constants[zua.opcodes.rkGetConstantIndex(rk)])
        else
            self.stack[base + rk];
    }

    fn constantToValue(self: *Self, constant: Constant) Value {
        return switch (constant) {
            .nil => .nil,
            .boolean => |b| .{ .boolean = b },
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = String.init(self.allocator, s) catch return .nil },
        };
    }

    pub fn run(self: *Self) !void {
        // Check if we have a function on the stack
        if (self.top > 0) {
            const func = self.stack[self.top - 1];
            switch (func) {
                .closure => {
                    // Set up call info
                    self.ci = .{
                        .func = func,
                        .base = self.top - 1,
                        .saved_pc = 0,
                        .num_results = 0,
                        .is_lua = true,
                    };
                    try self.executeLua();
                },
                .c_closure => {
                    // Call C closure directly
                    try self.call(0, 0);
                },
                else => {
                    return error.AttemptToCallNonFunction;
                },
            }
        }
    }
};

// =============================================================================
// Call Info
// =============================================================================

pub const CallInfo = struct {
    func: Value = .nil,
    base: usize = 0,
    saved_pc: usize = 0,
    num_results: i32 = 0,
    is_lua: bool = true,
    tailcalls: usize = 0,
};

// =============================================================================
// GC
// =============================================================================

pub const GC = zua.gc.GC;

// =============================================================================
// Tests
// =============================================================================

test "LuaState basic operations" {
    const allocator = std.testing.allocator;
    var state = try LuaState.init(allocator);
    defer state.deinit();
    
    try state.pushNumber(42.0);
    try std.testing.expectEqual(@as(f64, 42.0), state.toNumber(-1).?);
    
    try state.pushBoolean(true);
    try std.testing.expectEqual(true, state.toBoolean(-1));
    
    try state.pushNil();
    try std.testing.expect(state.isNil(-1));
}

test "LuaState table operations" {
    const allocator = std.testing.allocator;
    var state = try LuaState.init(allocator);
    defer state.deinit();
    
    _ = try state.pushTable();
    
    try state.pushNumber(1);
    try state.pushNumber(100);
    try state.setTable(-3);
    
    try state.pushNumber(1);
    try state.getTable(-2);
    try std.testing.expectEqual(@as(f64, 100.0), state.toNumber(-1).?);
}
