const std = @import("std");
const Allocator = std.mem.Allocator;
const zua = @import("zua.zig");
const GCObject = zua.object.GCObject;
const String = zua.object.String;
const Table = zua.object.Table;
const Closure = zua.object.Closure;
const CClosure = zua.object.CClosure;
const UserData = zua.object.UserData;
const Thread = zua.object.Thread;
const UpValue = zua.object.UpValue;
const Function = zua.object.Function;
const Value = zua.object.Value;

// =============================================================================
// GC State
// =============================================================================

pub const GC = struct {
    objects: ?*GCObject = null,
    num_objects: usize = 0,
    threshold: usize = 1024,
    allocator: Allocator,

    pub fn init(allocator: Allocator) GC {
        return .{
            .allocator = allocator,
        };
    }

    pub fn collect(self: *GC) void {
        // Mark phase
        self.markRoots();

        // Sweep phase
        self.sweep();

        // Reset threshold
        self.threshold = self.num_objects * 2;
    }

    pub fn addObject(self: *GC, obj: *GCObject) void {
        obj.next = self.objects;
        self.objects = obj;
        self.num_objects += 1;

        // Trigger collection if threshold exceeded
        if (self.num_objects > self.threshold) {
            self.collect();
        }
    }

    fn markRoots(_: *GC) void {
        // Mark all root objects
        // TODO: Mark from main thread stack, globals, registry, etc.
        // This is a placeholder - in a real implementation, we would need to:
        // 1. Mark all values on the main thread stack
        // 2. Mark the global environment table
        // 3. Mark the registry table
        // 4. Mark any open upvalues
        // 5. Mark any other root objects
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

    fn sweep(self: *GC) void {
        var prev: ?*GCObject = null;
        var current = self.objects;

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
            } else {
                // Marked object, unmark it for next collection
                obj.marked = 0;
                prev = obj;
            }

            current = next;
        }
    }

    fn freeObject(self: *GC, obj: *GCObject) void {
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
