const std = @import("std");
const Allocator = std.mem.Allocator;
const zua = @import("zua.zig");
const object = zua.object;
const GCObject = object.GCObject;
const String = object.String;
const Table = object.Table;
const Closure = object.Closure;
const CClosure = object.CClosure;
const UserData = object.UserData;
const Thread = object.Thread;
const UpValue = object.UpValue;
const Function = object.Function;
const Value = object.Value;

// =============================================================================
// GC State
// =============================================================================

pub const GC = struct {
    objects: ?*GCObject = null,
    num_objects: usize = 0,
    threshold: usize = 1024,
    allocator: Allocator,

    // Memory usage tracking
    total_allocated: usize = 0,
    total_collected: usize = 0,
    collection_count: usize = 0,

    // Root objects for garbage collection
    roots: ?Roots = null,

    pub const Roots = struct {
        globals: ?*object.Table = null,
        registry: ?*object.Table = null,
        main_thread: ?*object.Thread = null,
    };

    pub fn init(allocator: Allocator) GC {
        return .{
            .allocator = allocator,
        };
    }

    pub fn setRoots(self: *GC, roots: Roots) void {
        self.roots = roots;
    }

    pub fn collect(self: *GC) void {
        // Mark phase
        self.markRoots();

        // Sweep phase
        const collected = self.sweep();

        // Update statistics
        self.collection_count += 1;
        self.total_collected += collected;

        // Dynamic threshold adjustment
        // Use a factor between 1.5 and 3.0 based on collection efficiency
        const efficiency = if (self.num_objects > 0)
            @as(f64, @floatFromInt(collected)) / @as(f64, @floatFromInt(self.num_objects + collected))
        else
            0.0;
        const factor = 1.5 + (efficiency * 1.5); // Range: 1.5-3.0
        self.threshold = @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.num_objects)) * factor));

        // Ensure minimum threshold
        if (self.threshold < 1024) {
            self.threshold = 1024;
        }
    }

    pub fn addObject(self: *GC, obj: *GCObject) void {
        obj.next = self.objects;
        self.objects = obj;
        self.num_objects += 1;

        // Track memory usage (approximate size)
        var obj_size: usize = 0;
        switch (obj.obj_type) {
            .string => obj_size = @sizeOf(object.String),
            .table => obj_size = @sizeOf(object.Table),
            .closure => obj_size = @sizeOf(object.Closure),
            .c_closure => obj_size = @sizeOf(object.CClosure),
            .userdata => obj_size = @sizeOf(object.UserData),
            .thread => obj_size = @sizeOf(object.Thread),
            .upvalue => obj_size = @sizeOf(object.UpValue),
            .proto => obj_size = @sizeOf(object.Function),
        }
        self.total_allocated += obj_size;

        // Trigger collection if threshold exceeded
        if (self.num_objects > self.threshold) {
            self.collect();
        }
    }

    fn markRoots(self: *GC) void {
        // Mark all root objects
        if (self.roots) |roots| {
            // Mark global environment table
            if (roots.globals) |globals| {
                self.markObject(&globals.gc);
            }

            // Mark registry table
            if (roots.registry) |registry| {
                self.markObject(&registry.gc);
            }

            // Mark main thread and its stack
            if (roots.main_thread) |thread| {
                self.markObject(&thread.gc);

                // Mark stack values
                for (0..thread.stack_top) |i| {
                    self.markValue(thread.stack[i]);
                }

                // Mark open upvalues
                var upval = thread.open_upval;
                while (upval) |uv| {
                    self.markObject(&uv.gc);
                    upval = uv.next;
                }
            }
        } else {
            // Fallback: mark all objects if roots not set
            // This is a temporary solution to test the GC infrastructure
            var current = self.objects;
            while (current) |obj| {
                self.markObject(obj);
                current = obj.next;
            }
        }
    }

    fn markObject(self: *GC, obj: *GCObject) void {
        if (obj.marked != 0) return;

        obj.marked = 1;

        switch (obj.obj_type) {
            .string => {
                _ = String.cast(obj);
                // Strings don't have references to other objects
            },
            .table => {
                const table = Table.cast(obj);
                // Mark metatable
                if (table.metatable) |mt| {
                    self.markObject(&mt.gc);
                }
                // Mark array elements
                for (table.array.items) |value| {
                    self.markValue(value);
                }
                // Mark map entries
                var iter = table.map.iterator();
                while (iter.next()) |entry| {
                    self.markValue(entry.key_ptr.*);
                    self.markValue(entry.value_ptr.*);
                }
            },
            .closure => {
                const closure = Closure.cast(obj);
                // Mark prototype
                self.markObject(&closure.proto.gc);
                // Mark upvalues
                for (closure.upvalues) |upval| {
                    if (upval) |uv| {
                        self.markObject(&uv.gc);
                    }
                }
            },
            .c_closure => {
                const cclosure = CClosure.cast(obj);
                // Mark environment
                if (cclosure.env) |env| {
                    self.markObject(&env.gc);
                }
                // Mark upvalues
                for (cclosure.upvalues) |value| {
                    self.markValue(value);
                }
            },
            .userdata => {
                const userdata = UserData.cast(obj);
                // Mark environment
                if (userdata.env) |env| {
                    self.markObject(&env.gc);
                }
            },
            .thread => {
                const thread = Thread.cast(obj);
                // Mark globals
                self.markObject(&thread.globals.gc);
                // Mark registry
                self.markObject(&thread.registry.gc);
                // Mark open upvalues
                var upval = thread.open_upval;
                while (upval) |uv| {
                    self.markObject(&uv.gc);
                    upval = uv.next;
                }
                // Mark stack values
                for (0..thread.stack_top) |i| {
                    self.markValue(thread.stack[i]);
                }
            },
            .upvalue => {
                const upval = UpValue.cast(obj);
                // Mark closed value
                self.markValue(upval.closed);
            },
            .proto => {
                const proto = Function.cast(obj);
                // Mark constants
                for (proto.constants) |constant| {
                    switch (constant) {
                        .string => {
                            // TODO: If string is interned, find and mark it
                        },
                        else => {},
                    }
                }
                // Mark protos
                for (proto.protos) |p| {
                    self.markObject(&p.gc);
                }
            },
        }
    }

    fn markValue(self: *GC, value: Value) void {
        switch (value) {
            .string => |s| self.markObject(&s.gc),
            .table => |t| self.markObject(&t.gc),
            .closure => |c| self.markObject(&c.gc),
            .c_closure => |cc| self.markObject(&cc.gc),
            .userdata => |ud| self.markObject(&ud.gc),
            .thread => |th| self.markObject(&th.gc),
            else => {},
        }
    }

    fn sweep(self: *GC) usize {
        var prev: ?*GCObject = null;
        var current = self.objects;
        var collected: usize = 0;

        while (current) |obj| {
            const next = obj.next;

            if (obj.marked == 0) {
                // Unmarked object, collect it
                if (prev) |p| {
                    p.next = next;
                } else {
                    self.objects = next;
                }

                self.freeObject(obj);
                self.num_objects -= 1;
                collected += 1;
            } else {
                // Marked object, unmark it for next collection
                obj.marked = 0;
                prev = obj;
            }

            current = next;
        }
        return collected;
    }

    fn freeObject(self: *GC, obj: *GCObject) void {
        // Track memory freed (approximate size)
        var obj_size: usize = 0;
        switch (obj.obj_type) {
            .string => obj_size = @sizeOf(object.String),
            .table => obj_size = @sizeOf(object.Table),
            .closure => obj_size = @sizeOf(object.Closure),
            .c_closure => obj_size = @sizeOf(object.CClosure),
            .userdata => obj_size = @sizeOf(object.UserData),
            .thread => obj_size = @sizeOf(object.Thread),
            .upvalue => obj_size = @sizeOf(object.UpValue),
            .proto => obj_size = @sizeOf(object.Function),
        }
        self.total_collected += obj_size;

        switch (obj.obj_type) {
            .string => {
                const str = String.cast(obj);
                str.deinit(self.allocator);
            },
            .table => {
                const table = Table.cast(obj);
                table.deinit();
                self.allocator.destroy(table);
            },
            .closure => {
                const closure = Closure.cast(obj);
                closure.deinit(self.allocator);
            },
            .c_closure => {
                const cclosure = CClosure.cast(obj);
                cclosure.deinit(self.allocator);
            },
            .userdata => {
                const userdata = UserData.cast(obj);
                // TODO: Call finalizer if present
                // For now, skip finalizer call to avoid pointer issues
                self.allocator.destroy(userdata);
            },
            .thread => {
                const thread = Thread.cast(obj);
                thread.deinit();
            },
            .upvalue => {
                const upval = UpValue.cast(obj);
                self.allocator.destroy(upval);
            },
            .proto => {
                const proto = Function.cast(obj);
                proto.deinit();
                self.allocator.destroy(proto);
            },
        }
    }

    // GC Statistics and Debugging
    pub const GCStats = struct {
        num_objects: usize,
        threshold: usize,
        total_allocated: usize,
        total_collected: usize,
        collection_count: usize,
    };

    pub fn getStats(self: *GC) GCStats {
        return .{
            .num_objects = self.num_objects,
            .threshold = self.threshold,
            .total_allocated = self.total_allocated,
            .total_collected = self.total_collected,
            .collection_count = self.collection_count,
        };
    }

    pub fn printStats(self: *GC) void {
        const stats = self.getStats();
        std.debug.print("GC Stats:\n", .{});
        std.debug.print("  Objects: {d}\n", .{stats.num_objects});
        std.debug.print("  Threshold: {d}\n", .{stats.threshold});
        std.debug.print("  Total Allocated: {d} bytes\n", .{stats.total_allocated});
        std.debug.print("  Total Collected: {d} bytes\n", .{stats.total_collected});
        std.debug.print("  Collections: {d}\n", .{stats.collection_count});
        std.debug.print("\n", .{});
    }

    pub fn debugCollect(self: *GC) void {
        std.debug.print("Starting GC collection...\n", .{});
        const before = self.num_objects;
        self.collect();
        const after = self.num_objects;
        std.debug.print("GC collection completed. Collected {d} objects.\n", .{before - after});
        self.printStats();
    }
};

// =============================================================================
// GC Allocator
// =============================================================================

// TODO: Implement GCAllocator when needed

// =============================================================================
// GC Helpers
// =============================================================================

pub fn addToGC(gc: *GC, obj: *GCObject) void {
    gc.addObject(obj);
}

pub fn shouldCollect(gc: *GC) bool {
    return gc.num_objects > gc.threshold;
}

pub fn forceCollect(gc: *GC) void {
    gc.collect();
}
