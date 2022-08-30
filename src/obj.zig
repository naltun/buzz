const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;
const StringHashMap = std.StringHashMap;
const Chunk = @import("./chunk.zig").Chunk;
const _vm = @import("./vm.zig");
const VM = _vm.VM;
const Fiber = _vm.Fiber;
const Parser = @import("./parser.zig").Parser;
const _memory = @import("./memory.zig");
const GarbageCollector = _memory.GarbageCollector;
const TypeRegistry = _memory.TypeRegistry;
const _value = @import("./value.zig");
const Token = @import("./token.zig").Token;
const Config = @import("./config.zig").Config;
const CodeGen = @import("./codegen.zig").CodeGen;

pub const pcre = @import("./pcre.zig").pcre;

const Value = _value.Value;
const HashableValue = _value.HashableValue;
const ValueType = _value.ValueType;
const valueToHashable = _value.valueToHashable;
const hashableToValue = _value.hashableToValue;
const floatToInteger = _value.floatToInteger;
const valueToString = _value.valueToString;
const valueEql = _value.valueEql;
const valueIs = _value.valueIs;
const valueTypeEql = _value.valueTypeEql;

pub const ObjType = enum {
    String,
    Type,
    UpValue,
    Closure,
    Function,
    ObjectInstance,
    Object,
    List,
    Map,
    Enum,
    EnumInstance,
    Bound,
    Native,
    UserData,
    Pattern,
    Fiber,
};

pub const Obj = struct {
    const Self = @This();

    obj_type: ObjType,
    is_marked: bool = false,
    // True when old obj and was modified
    is_dirty: bool = false,
    node: ?*std.TailQueue(*Obj).Node = null,

    pub fn is(self: *Self, type_def: *ObjTypeDef) bool {
        return switch (self.obj_type) {
            .String => type_def.def_type == .String,
            .Pattern => type_def.def_type == .Pattern,
            .Fiber => type_def.def_type == .Fiber,

            .Type, .Object, .Enum => type_def.def_type == .Type,

            .ObjectInstance => type_def.def_type == .Object and ObjObjectInstance.cast(self).?.is(null, type_def),
            .EnumInstance => type_def.def_type == .Enum and ObjEnumInstance.cast(self).?.enum_ref.type_def == type_def,
            .Function => function: {
                const function: *ObjFunction = ObjFunction.cast(self).?;
                break :function function.type_def.eql(type_def);
            },

            .UpValue => upvalue: {
                const upvalue: *ObjUpValue = ObjUpValue.cast(self).?;
                break :upvalue valueIs(
                    Value{ .Obj = type_def.toObj() },
                    upvalue.closed orelse upvalue.location.*,
                );
            },
            .Closure => ObjClosure.cast(self).?.function.toObj().is(type_def),
            .List => ObjList.cast(self).?.type_def.eql(type_def),
            .Map => ObjMap.cast(self).?.type_def.eql(type_def),
            .Bound => bound: {
                const bound: *ObjBoundMethod = ObjBoundMethod.cast(self).?;
                break :bound valueIs(
                    Value{ .Obj = type_def.toObj() },
                    Value{ .Obj = if (bound.closure) |cls| cls.function.toObj() else bound.native.?.toObj() },
                );
            },

            .UserData, .Native => unreachable, // TODO: we don't know how to embark NativeFn type at runtime yet
        };
    }

    pub fn typeEql(self: *Self, type_def: *ObjTypeDef) bool {
        return switch (self.obj_type) {
            .Pattern => type_def.def_type == .Pattern,
            .String => type_def.def_type == .String,
            .Type => type_def.def_type == .Type,
            .UpValue => uv: {
                var upvalue: *ObjUpValue = ObjUpValue.cast(self).?;
                break :uv valueTypeEql(upvalue.closed orelse upvalue.location.*, type_def);
            },
            .EnumInstance => ei: {
                var instance: *ObjEnumInstance = ObjEnumInstance.cast(self).?;
                break :ei type_def.def_type == .EnumInstance and instance.enum_ref.type_def.eql(type_def.resolved_type.?.EnumInstance);
            },
            .ObjectInstance => oi: {
                var instance: *ObjObjectInstance = ObjObjectInstance.cast(self).?;
                break :oi type_def.def_type == .ObjectInstance and instance.is(null, type_def.resolved_type.?.ObjectInstance);
            },
            .Enum => ObjEnum.cast(self).?.type_def.eql(type_def),
            .Object => ObjObject.cast(self).?.type_def.eql(type_def),
            .Function => ObjFunction.cast(self).?.type_def.eql(type_def),
            .Closure => ObjClosure.cast(self).?.function.type_def.eql(type_def),
            .Bound => bound: {
                var bound = ObjBoundMethod.cast(self).?;
                break :bound if (bound.closure) |cls| cls.function.type_def.eql(type_def) else unreachable; // TODO
            },
            .List => ObjList.cast(self).?.type_def.eql(type_def),
            .Map => ObjMap.cast(self).?.type_def.eql(type_def),
            .Fiber => ObjFiber.cast(self).?.type_def.eql(type_def),
            .UserData, .Native => unreachable, // TODO
        };
    }

    pub fn eql(self: *Self, other: *Self) bool {
        if (self.obj_type != other.obj_type) {
            return false;
        }

        switch (self.obj_type) {
            .Pattern => {
                return mem.eql(u8, ObjPattern.cast(self).?.source, ObjPattern.cast(other).?.source);
            },
            .String => {
                if (Config.debug) {
                    assert(self != other or mem.eql(u8, ObjString.cast(self).?.string, ObjString.cast(other).?.string));
                    assert(self == other or !mem.eql(u8, ObjString.cast(self).?.string, ObjString.cast(other).?.string));
                }

                // since string are interned this should be enough
                return self == other;
            },
            .Type => {
                const self_type: *ObjTypeDef = ObjTypeDef.cast(self).?;
                const other_type: *ObjTypeDef = ObjTypeDef.cast(other).?;

                return self_type.optional == other_type.optional and self_type.eql(other_type);
            },
            .UpValue => {
                const self_upvalue: *ObjUpValue = ObjUpValue.cast(self).?;
                const other_upvalue: *ObjUpValue = ObjUpValue.cast(other).?;

                return valueEql(self_upvalue.closed orelse self_upvalue.location.*, other_upvalue.closed orelse other_upvalue.location.*);
            },
            .EnumInstance => {
                const self_enum_instance: *ObjEnumInstance = ObjEnumInstance.cast(self).?;
                const other_enum_instance: *ObjEnumInstance = ObjEnumInstance.cast(other).?;

                return self_enum_instance.enum_ref == other_enum_instance.enum_ref and self_enum_instance.case == other_enum_instance.case;
            },
            .Bound,
            .Closure,
            .Function,
            .ObjectInstance,
            .Object,
            .List,
            .Map,
            .Enum,
            .Native,
            .UserData,
            .Fiber,
            => {
                return self == other;
            },
        }
    }
};

pub const ObjFiber = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .Fiber },

    fiber: *Fiber,

    type_def: *ObjTypeDef,

    pub fn mark(self: *Self, gc: *GarbageCollector) !void {
        try gc.markFiber(self.fiber);
        try gc.markObj(self.type_def.toObj());
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Fiber) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub fn over(vm: *VM) c_int {
        var self = Self.cast(vm.peek(0).Obj).?;

        vm.push(Value{ .Boolean = self.fiber.status == .Over });

        return 1;
    }

    pub fn cancel(vm: *VM) c_int {
        var self = Self.cast(vm.peek(0).Obj).?;

        self.fiber.status = .Over;

        return 0;
    }

    pub fn rawMember(method: []const u8) ?NativeFn {
        if (mem.eql(u8, method, "over")) {
            return over;
        } else if (mem.eql(u8, method, "cancel")) {
            return cancel;
        }

        return null;
    }

    pub fn member(vm: *VM, method: *ObjString) !?*ObjNative {
        if (vm.gc.objfiber_members.get(method)) |umethod| {
            return umethod;
        }

        var nativeFn: ?NativeFn = rawMember(method.string);

        if (nativeFn) |unativeFn| {
            var native: *ObjNative = try vm.gc.allocateObject(
                ObjNative,
                .{
                    .native = unativeFn,
                },
            );

            try vm.gc.objfiber_members.put(method, native);

            return native;
        }

        return null;
    }

    pub fn memberDef(parser: *Parser, method: []const u8) !?*ObjTypeDef {
        if (parser.gc.objfiber_memberDefs.get(method)) |umethod| {
            return umethod;
        }

        if (mem.eql(u8, method, "over")) {
            var native_type = try parser.parseTypeDefFrom("Function over() > bool");

            try parser.gc.objfiber_memberDefs.put("over", native_type);

            return native_type;
        } else if (mem.eql(u8, method, "cancel")) {
            var native_type = try parser.parseTypeDefFrom("Function cancel() > void");

            try parser.gc.objfiber_memberDefs.put("cancel", native_type);

            return native_type;
        }

        return null;
    }

    pub const FiberDef = struct {
        const SelfFiberDef = @This();

        return_type: *ObjTypeDef,
        yield_type: *ObjTypeDef,

        pub fn mark(self: *SelfFiberDef, gc: *GarbageCollector) !void {
            try gc.markObj(self.return_type.toObj());
            try gc.markObj(self.yield_type.toObj());
        }
    };
};

pub const pcre_struct = switch (builtin.os.tag) {
    .linux, .freebsd, .openbsd => pcre.struct_real_pcre,
    .macos, .tvos, .watchos, .ios => pcre.struct_real_pcre8_or_16,
    else => unreachable,
};

// Patterns are pcre regex, @see https://www.pcre.org/original/doc/html/index.html
pub const ObjPattern = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .Pattern },

    source: []const u8,
    pattern: *pcre_struct,

    pub fn mark(_: *Self, _: *GarbageCollector) !void {}

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Pattern) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    fn rawMatch(self: *Self, vm: *VM, subject: ?[*]const u8, len: usize, offset: *usize) !?*ObjList {
        if (subject == null) {
            return null;
        }

        var results: ?*ObjList = null;

        var output_vector: [3000]c_int = undefined;

        const rc = pcre.pcre_exec(
            self.pattern, // the compiled pattern
            null, // no extra data - we didn't study the pattern
            @ptrCast([*c]const u8, subject.?), // the subject string
            @intCast(c_int, len), // the length of the subject
            @intCast(c_int, offset.*), // start offset
            0, // default options
            @ptrCast([*c]c_int, &output_vector), // output vector for substring information
            output_vector.len, // number of elements in the output vector
        );

        switch (rc) {
            pcre.PCRE_ERROR_UNSET...pcre.PCRE_ERROR_NOMATCH => return null,
            // TODO: handle ouptut_vector too small
            0 => unreachable,
            else => {
                offset.* = @intCast(usize, output_vector[1]);

                results = try vm.gc.allocateObject(
                    ObjList,
                    ObjList.init(
                        vm.gc.allocator,
                        try vm.gc.type_registry.getTypeDef(
                            ObjTypeDef{
                                .def_type = .String,
                            },
                        ),
                    ),
                );

                // Prevent gc collection
                vm.push(results.?.toValue());

                var i: usize = 0;
                while (i < rc) : (i += 1) {
                    try results.?.items.append(
                        (try vm.gc.copyString(
                            subject.?[@intCast(usize, output_vector[2 * i])..@intCast(usize, output_vector[2 * i + 1])],
                        )).toValue(),
                    );
                }

                _ = vm.pop();
            },
        }

        return results;
    }

    fn rawMatchAll(self: *Self, vm: *VM, subject: ?[*]const u8, len: usize) !?*ObjList {
        if (subject == null) {
            return null;
        }

        var results: ?*ObjList = null;
        var offset: usize = 0;
        while (true) {
            if (try self.rawMatch(vm, subject.?, len, &offset)) |matches| {
                var was_null = results == null;
                results = results orelse try vm.gc.allocateObject(
                    ObjList,
                    ObjList.init(vm.gc.allocator, matches.type_def),
                );

                if (was_null) {
                    vm.push(results.?.toValue());
                }

                try results.?.items.append(matches.toValue());
            } else {
                if (results != null) {
                    _ = vm.pop();
                }

                return results;
            }
        }

        if (results != null) {
            _ = vm.pop();
        }

        return results;
    }

    pub fn match(vm: *VM) c_int {
        const self = Self.cast(vm.peek(1).Obj).?;
        const subject = ObjString.cast(vm.peek(0).Obj).?.string;

        var offset: usize = 0;
        if (self.rawMatch(vm, if (subject.len > 0) @ptrCast([*]const u8, subject) else null, subject.len, &offset) catch {
            var err: ?*ObjString = vm.gc.copyString("Could not match") catch null;
            vm.throw(VM.Error.Custom, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        }) |results| {
            vm.push(results.toValue());
        } else {
            vm.push(Value{ .Null = {} });
        }

        return 1;
    }

    pub fn matchAll(vm: *VM) c_int {
        var self = Self.cast(vm.peek(1).Obj).?;
        var subject = ObjString.cast(vm.peek(0).Obj).?.string;

        if (self.rawMatchAll(vm, if (subject.len > 0) @ptrCast([*]const u8, subject) else null, subject.len) catch {
            var err: ?*ObjString = vm.gc.copyString("Could not match") catch null;
            vm.throw(VM.Error.Custom, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        }) |results| {
            vm.push(results.toValue());
        } else {
            vm.push(Value{ .Null = {} });
        }

        return 1;
    }

    pub fn rawMember(method: []const u8) ?NativeFn {
        if (mem.eql(u8, method, "match")) {
            return match;
        } else if (mem.eql(u8, method, "matchAll")) {
            return matchAll;
        }

        return null;
    }

    pub fn member(vm: *VM, method: *ObjString) !?*ObjNative {
        if (vm.gc.objpattern_members.get(method)) |umethod| {
            return umethod;
        }

        var nativeFn: ?NativeFn = rawMember(method.string);

        if (nativeFn) |unativeFn| {
            var native: *ObjNative = try vm.gc.allocateObject(
                ObjNative,
                .{
                    .native = unativeFn,
                },
            );

            try vm.gc.objpattern_members.put(method, native);

            return native;
        }

        return null;
    }

    pub fn memberDef(parser: *Parser, method: []const u8) !?*ObjTypeDef {
        if (parser.gc.objpattern_memberDefs.get(method)) |umethod| {
            return umethod;
        }

        if (mem.eql(u8, method, "match")) {
            var native_type = try parser.parseTypeDefFrom("Function match(str subject) > [str]?");

            try parser.gc.objpattern_memberDefs.put("match", native_type);

            return native_type;
        } else if (mem.eql(u8, method, "matchAll")) {
            var native_type = try parser.parseTypeDefFrom("Function matchAll(str subject) > [[str]]?");

            try parser.gc.objpattern_memberDefs.put("matchAll", native_type);

            return native_type;
        }

        return null;
    }
};

// 1 = return value on stack, 0 = no return value, -1 = error
pub const NativeFn = fn (*VM) c_int;

/// Native function
pub const ObjNative = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .Native },

    // TODO: issue is list.member which separate its type definition from its runtime creation
    // type_def: *ObjTypeDef,

    native: NativeFn,

    pub fn mark(_: *Self, _: *GarbageCollector) void {}

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Native) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

pub const UserData = anyopaque;

/// User data, type around an opaque pointer
pub const ObjUserData = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .UserData },

    userdata: *UserData,

    pub fn mark(_: *Self, _: *GarbageCollector) void {}

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .UserData) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

/// A String
pub const ObjString = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .String },

    /// The actual string
    string: []const u8,

    pub fn mark(_: *Self, _: *GarbageCollector) !void {}

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .String) {
            std.debug.print("Tried to cast into ObjString: {*}\n", .{obj});
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub fn concat(self: *Self, vm: *VM, other: *Self) !*Self {
        var new_string: std.ArrayList(u8) = std.ArrayList(u8).init(vm.gc.allocator);
        try new_string.appendSlice(self.string);
        try new_string.appendSlice(other.string);

        return vm.gc.copyString(new_string.items);
    }

    pub fn len(vm: *VM) c_int {
        var str: *Self = Self.cast(vm.peek(0).Obj).?;

        vm.push(Value{ .Integer = @intCast(i64, str.string.len) });

        return 1;
    }

    pub fn repeat(vm: *VM) c_int {
        const str = Self.cast(vm.peek(1).Obj).?;
        const n = floatToInteger(vm.peek(0));
        const n_i = if (n == .Integer) n.Integer else null;

        if (n_i) |ni| {
            var new_string: std.ArrayList(u8) = std.ArrayList(u8).init(vm.gc.allocator);
            var i: usize = 0;
            while (i < ni) : (i += 1) {
                new_string.appendSlice(str.string) catch {
                    var err: ?*ObjString = vm.gc.copyString("Could not repeat string") catch null;
                    vm.throw(VM.Error.BadNumber, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

                    return -1;
                };
            }

            const new_objstring = vm.gc.copyString(new_string.items) catch {
                var err: ?*ObjString = vm.gc.copyString("Could not repeat string") catch null;
                vm.throw(VM.Error.BadNumber, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

                return -1;
            };

            vm.push(new_objstring.toValue());

            return 1;
        }

        var err: ?*ObjString = vm.gc.copyString("`n` should be an integer") catch null;
        vm.throw(VM.Error.BadNumber, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

        return -1;
    }

    pub fn byte(vm: *VM) c_int {
        const self: *Self = Self.cast(vm.peek(1).Obj).?;
        const index = floatToInteger(vm.peek(0));
        const index_i = if (index == .Integer) index.Integer else null;

        if (index_i == null or index_i.? < 0 or index_i.? >= self.string.len) {
            var err: ?*ObjString = vm.gc.copyString("Out of bound access to str") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        }

        vm.push(Value{ .Integer = @intCast(i64, self.string[@intCast(usize, index_i.?)]) });

        return 1;
    }

    pub fn indexOf(vm: *VM) c_int {
        var self: *Self = Self.cast(vm.peek(1).Obj).?;
        var needle: *Self = Self.cast(vm.peek(0).Obj).?;

        var index = std.mem.indexOf(u8, self.string, needle.string);

        vm.push(if (index) |uindex| Value{ .Integer = @intCast(i64, uindex) } else Value{ .Null = {} });

        return 1;
    }

    pub fn startsWith(vm: *VM) c_int {
        var self: *Self = Self.cast(vm.peek(1).Obj).?;
        var needle: *Self = Self.cast(vm.peek(0).Obj).?;

        vm.push(Value{ .Boolean = std.mem.startsWith(u8, self.string, needle.string) });

        return 1;
    }

    pub fn endsWith(vm: *VM) c_int {
        var self: *Self = Self.cast(vm.peek(1).Obj).?;
        var needle: *Self = Self.cast(vm.peek(0).Obj).?;

        vm.push(Value{ .Boolean = std.mem.endsWith(u8, self.string, needle.string) });

        return 1;
    }

    pub fn replace(vm: *VM) c_int {
        var self: *Self = Self.cast(vm.peek(2).Obj).?;
        var needle: *Self = Self.cast(vm.peek(1).Obj).?;
        var replacement: *Self = Self.cast(vm.peek(0).Obj).?;

        const new_string = std.mem.replaceOwned(u8, vm.gc.allocator, self.string, needle.string, replacement.string) catch {
            var err: ?*ObjString = vm.gc.copyString("Could not replace string") catch null;
            vm.throw(VM.Error.Custom, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };

        vm.push(
            (vm.gc.copyString(new_string) catch {
                var err: ?*ObjString = vm.gc.copyString("Could not replace string") catch null;
                vm.throw(VM.Error.Custom, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

                return -1;
            }).toValue(),
        );

        return 1;
    }

    pub fn sub(vm: *VM) c_int {
        var self: *Self = Self.cast(vm.peek(2).Obj).?;
        var start_value = floatToInteger(vm.peek(1));
        var start: ?i64 = if (start_value == .Integer) start_value.Integer else null;
        var upto_value: Value = floatToInteger(vm.peek(0));
        var upto: ?i64 = if (upto_value == .Integer) upto_value.Integer else if (upto_value == .Float) @floatToInt(i64, upto_value.Float) else null;

        if (start == null or start.? < 0 or start.? >= self.string.len) {
            var err: ?*ObjString = vm.gc.copyString("`start` is out of bound") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        }

        if (upto != null and upto.? < 0) {
            var err: ?*ObjString = vm.gc.copyString("`len` must greater or equal to 0") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        }

        const limit: usize = if (upto != null and @intCast(usize, start.? + upto.?) < self.string.len) @intCast(usize, start.? + upto.?) else self.string.len;
        var substr: []const u8 = self.string[@intCast(usize, start.?)..limit];

        vm.push(
            (vm.gc.copyString(substr) catch {
                var err: ?*ObjString = vm.gc.copyString("Could not get sub string") catch null;
                vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

                return -1;
            }).toValue(),
        );

        return 1;
    }

    pub fn split(vm: *VM) c_int {
        var self: *Self = Self.cast(vm.peek(1).Obj).?;
        var separator: *Self = Self.cast(vm.peek(0).Obj).?;

        // std.mem.split(u8, self.string, separator.string);
        var list_def: ObjList.ListDef = ObjList.ListDef.init(
            vm.gc.allocator,
            vm.gc.type_registry.getTypeDef(ObjTypeDef{
                .def_type = .String,
            }) catch {
                var err: ?*ObjString = vm.gc.copyString("Could not split string") catch null;
                vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

                return -1;
            },
        );

        var list_def_union: ObjTypeDef.TypeUnion = .{
            .List = list_def,
        };

        // TODO: reuse already allocated similar typedef
        var list_def_type: *ObjTypeDef = vm.gc.type_registry.getTypeDef(ObjTypeDef{
            .def_type = .List,
            .optional = false,
            .resolved_type = list_def_union,
        }) catch {
            var err: ?*ObjString = vm.gc.copyString("Could not split string") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };

        var list: *ObjList = vm.gc.allocateObject(
            ObjList,
            ObjList.init(vm.gc.allocator, list_def_type),
        ) catch {
            var err: ?*ObjString = vm.gc.copyString("Could not split string") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };

        // Prevent gc & is result
        vm.push(list.toValue());

        var it = std.mem.split(u8, self.string, separator.string);
        while (it.next()) |fragment| {
            var fragment_str: ?*ObjString = vm.gc.copyString(fragment) catch {
                var err: ?*ObjString = vm.gc.copyString("Could not split string") catch null;
                vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

                return -1;
            };

            list.rawAppend(vm.gc, fragment_str.?.toValue()) catch {
                var err: ?*ObjString = vm.gc.copyString("Could not split string") catch null;
                vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

                return -1;
            };
        }

        return 1;
    }

    pub fn next(self: *Self, vm: *VM, str_index: ?i64) !?i64 {
        if (str_index) |index| {
            if (index < 0 or index >= @intCast(i64, self.string.len)) {
                try vm.throw(VM.Error.OutOfBound, (try vm.gc.copyString("Out of bound access to str")).toValue());
            }

            return if (index + 1 >= @intCast(i64, self.string.len))
                null
            else
                index + 1;
        } else {
            return if (self.string.len > 0) @intCast(i64, 0) else null;
        }
    }

    pub fn encodeBase64(vm: *VM) c_int {
        var str: *Self = Self.cast(vm.peek(0).Obj).?;

        var encoded = vm.gc.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(str.string.len)) catch {
            var err: ?*ObjString = vm.gc.copyString("Could not encode string") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };
        defer vm.gc.allocator.free(encoded);

        var new_string = vm.gc.copyString(
            std.base64.standard.Encoder.encode(encoded, str.string),
        ) catch {
            var err: ?*ObjString = vm.gc.copyString("Could not encode string") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };

        vm.push(new_string.toValue());

        return 1;
    }

    pub fn decodeBase64(vm: *VM) c_int {
        var str: *Self = Self.cast(vm.peek(0).Obj).?;

        const size = std.base64.standard.Decoder.calcSizeForSlice(str.string) catch {
            var err: ?*ObjString = vm.gc.copyString("Could not decode string") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };
        var decoded = vm.gc.allocator.alloc(u8, size) catch {
            var err: ?*ObjString = vm.gc.copyString("Could not decode string") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };
        defer vm.gc.allocator.free(decoded);

        std.base64.standard.Decoder.decode(decoded, str.string) catch {
            var err: ?*ObjString = vm.gc.copyString("Could not decode string") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };

        var new_string = vm.gc.copyString(decoded) catch {
            var err: ?*ObjString = vm.gc.copyString("Could not decode string") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };

        vm.push(new_string.toValue());

        return 1;
    }

    pub fn rawMember(method: []const u8) ?NativeFn {
        if (mem.eql(u8, method, "len")) {
            return len;
        } else if (mem.eql(u8, method, "byte")) {
            return byte;
        } else if (mem.eql(u8, method, "indexOf")) {
            return indexOf;
        } else if (mem.eql(u8, method, "split")) {
            return split;
        } else if (mem.eql(u8, method, "sub")) {
            return sub;
        } else if (mem.eql(u8, method, "startsWith")) {
            return startsWith;
        } else if (mem.eql(u8, method, "endsWith")) {
            return endsWith;
        } else if (mem.eql(u8, method, "replace")) {
            return replace;
        } else if (mem.eql(u8, method, "repeat")) {
            return repeat;
        } else if (mem.eql(u8, method, "encodeBase64")) {
            return encodeBase64;
        } else if (mem.eql(u8, method, "decodeBase64")) {
            return decodeBase64;
        }

        return null;
    }

    // TODO: find a way to return the same ObjNative pointer for the same type of Lists
    pub fn member(vm: *VM, method: *ObjString) !?*ObjNative {
        if (vm.gc.objstring_members.get(method)) |umethod| {
            return umethod;
        }

        var nativeFn: ?NativeFn = rawMember(method.string);

        if (nativeFn) |unativeFn| {
            var native: *ObjNative = try vm.gc.allocateObject(
                ObjNative,
                .{
                    .native = unativeFn,
                },
            );

            try vm.gc.objstring_members.put(method, native);

            return native;
        }

        return null;
    }

    pub fn memberDef(parser: *Parser, method: []const u8) !?*ObjTypeDef {
        if (parser.gc.objstring_memberDefs.get(method)) |umethod| {
            return umethod;
        }

        if (mem.eql(u8, method, "len")) {
            var native_type = try parser.parseTypeDefFrom("Function len() > num");

            try parser.gc.objstring_memberDefs.put("len", native_type);

            return native_type;
        } else if (mem.eql(u8, method, "byte")) {
            var native_type = try parser.parseTypeDefFrom("Function byte(num at) > num");

            try parser.gc.objstring_memberDefs.put("byte", native_type);

            return native_type;
        } else if (mem.eql(u8, method, "indexOf")) {
            var native_type = try parser.parseTypeDefFrom("Function indexOf(str needle) > num?");

            try parser.gc.objstring_memberDefs.put("indexOf", native_type);

            return native_type;
        } else if (mem.eql(u8, method, "startsWith")) {
            var native_type = try parser.parseTypeDefFrom("Function startsWith(str needle) > bool");

            try parser.gc.objstring_memberDefs.put("startsWith", native_type);

            return native_type;
        } else if (mem.eql(u8, method, "endsWith")) {
            var native_type = try parser.parseTypeDefFrom("Function endsWith(str needle) > bool");

            try parser.gc.objstring_memberDefs.put("endsWith", native_type);

            return native_type;
        } else if (mem.eql(u8, method, "replace")) {
            var native_type = try parser.parseTypeDefFrom("Function replace(str needle, str with) > str");

            try parser.gc.objstring_memberDefs.put("replace", native_type);

            return native_type;
        } else if (mem.eql(u8, method, "split")) {
            var native_type = try parser.parseTypeDefFrom("Function split(str separator) > [str]");

            try parser.gc.objstring_memberDefs.put("split", native_type);

            return native_type;
        } else if (mem.eql(u8, method, "sub")) {
            var native_type = try parser.parseTypeDefFrom("Function sub(num start, num? len) > str");

            try parser.gc.objstring_memberDefs.put("sub", native_type);

            return native_type;
        } else if (mem.eql(u8, method, "repeat")) {
            var native_type = try parser.parseTypeDefFrom("Function repeat(num n) > str");

            try parser.gc.objstring_memberDefs.put("repeat", native_type);

            return native_type;
        } else if (mem.eql(u8, method, "encodeBase64")) {
            var native_type = try parser.parseTypeDefFrom("Function encodeBase64() > str");

            try parser.gc.objstring_memberDefs.put("encodeBase64", native_type);

            return native_type;
        } else if (mem.eql(u8, method, "decodeBase64")) {
            var native_type = try parser.parseTypeDefFrom("Function decodeBase64() > str");

            try parser.gc.objstring_memberDefs.put("decodeBase64", native_type);

            return native_type;
        }

        return null;
    }
};

/// Upvalue
pub const ObjUpValue = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .UpValue },

    /// Slot on the stack
    location: *Value,
    closed: ?Value,
    next: ?*ObjUpValue = null,

    pub fn init(slot: *Value) Self {
        return Self{ .closed = null, .location = slot, .next = null };
    }

    pub fn mark(self: *Self, gc: *GarbageCollector) !void {
        try gc.markValue(self.location.*); // Useless
        if (self.closed) |uclosed| {
            try gc.markValue(uclosed);
        }
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .UpValue) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

/// Closure
pub const ObjClosure = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .Closure },

    function: *ObjFunction,
    upvalues: std.ArrayList(*ObjUpValue),
    // Pointer to the global with which the function was declared
    globals: *std.ArrayList(Value),

    pub fn init(allocator: Allocator, vm: *VM, function: *ObjFunction) !Self {
        return Self{
            // TODO: copy?
            .globals = &vm.globals,
            .function = function,
            .upvalues = try std.ArrayList(*ObjUpValue).initCapacity(allocator, function.upvalue_count),
        };
    }

    pub fn mark(self: *Self, gc: *GarbageCollector) !void {
        try gc.markObj(self.function.toObj());
        for (self.upvalues.items) |upvalue| {
            try gc.markObj(upvalue.toObj());
        }
        for (self.globals.items) |global| {
            try gc.markValue(global);
        }
    }

    pub fn deinit(self: *Self) void {
        self.upvalues.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Closure) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

/// Function
pub const ObjFunction = struct {
    const Self = @This();

    pub const FunctionType = enum {
        Function,
        Method,
        Script, // Imported script
        ScriptEntryPoint, // main script
        EntryPoint, // main function
        Catch,
        Test,
        Anonymous,
        Extern,
    };

    obj: Obj = .{ .obj_type = .Function },

    type_def: *ObjTypeDef = undefined, // Undefined because function initialization is in several steps

    name: *ObjString,
    chunk: Chunk,
    upvalue_count: u8 = 0,

    pub fn init(allocator: Allocator, name: *ObjString) !Self {
        return Self{
            .name = name,
            .chunk = Chunk.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.chunk.deinit();
    }

    pub fn mark(self: *Self, gc: *GarbageCollector) !void {
        try gc.markObj(self.name.toObj());
        try gc.markObj(self.type_def.toObj());
        if (Config.debug_gc) {
            std.debug.print("MARKING CONSTANTS OF FUNCTION @{} {s}\n", .{ @ptrToInt(self), self.name.string });
        }
        for (self.chunk.constants.items) |constant| {
            try gc.markValue(constant);
        }
        if (Config.debug_gc) {
            std.debug.print("DONE MARKING CONSTANTS OF FUNCTION @{} {s}\n", .{ @ptrToInt(self), self.name.string });
        }
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Function) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub const FunctionDef = struct {
        const FunctionDefSelf = @This();

        name: *ObjString,
        return_type: *ObjTypeDef,
        yield_type: *ObjTypeDef,
        parameters: std.AutoArrayHashMap(*ObjString, *ObjTypeDef),
        // Storing here the defaults means they can only be non-Obj values
        defaults: std.AutoArrayHashMap(*ObjString, Value),
        function_type: FunctionType = .Function,
        lambda: bool = false,

        pub fn mark(self: *FunctionDefSelf, gc: *GarbageCollector) !void {
            try gc.markObj(self.name.toObj());
            try gc.markObj(self.return_type.toObj());
            try gc.markObj(self.yield_type.toObj());

            var it = self.parameters.iterator();
            while (it.next()) |parameter| {
                try gc.markObj(parameter.key_ptr.*.toObj());
                try gc.markObj(parameter.value_ptr.*.toObj());
            }

            var it2 = self.defaults.iterator();
            while (it2.next()) |default| {
                try gc.markObj(default.key_ptr.*.toObj());
                try gc.markValue(default.value_ptr.*);
            }
        }
    };
};

/// Object instance
pub const ObjObjectInstance = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .ObjectInstance },

    /// Object (null when anonymous)
    object: ?*ObjObject,
    /// Object type (null when not anonymous)
    type_def: ?*ObjTypeDef,
    /// Fields value
    fields: std.AutoHashMap(*ObjString, Value),

    pub fn setField(self: *Self, gc: *GarbageCollector, key: *ObjString, value: Value) !void {
        try self.fields.put(key, value);
        try gc.markObjDirty(&self.obj);
    }

    pub fn init(allocator: Allocator, object: ?*ObjObject, type_def: ?*ObjTypeDef) Self {
        return Self{
            .object = object,
            .type_def = type_def,
            .fields = std.AutoHashMap(*ObjString, Value).init(allocator),
        };
    }

    pub fn mark(self: *Self, gc: *GarbageCollector) !void {
        if (self.object) |object| {
            try gc.markObj(object.toObj());
        }
        if (self.type_def) |type_def| {
            try gc.markObj(type_def.toObj());
        }
        var it = self.fields.iterator();
        while (it.next()) |kv| {
            try gc.markObj(kv.key_ptr.*.toObj());
            try gc.markValue(kv.value_ptr.*);
        }
    }

    pub fn deinit(self: *Self) void {
        self.fields.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .ObjectInstance) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    fn is(self: *Self, instance_type: ?*ObjTypeDef, type_def: *ObjTypeDef) bool {
        const object_def: *ObjTypeDef = instance_type orelse (if (self.object) |object| object.type_def else self.type_def.?.resolved_type.?.ObjectInstance);

        if (type_def.def_type != .Object) {
            return false;
        }

        return object_def == type_def or (object_def.resolved_type.?.Object.super != null and self.is(object_def.resolved_type.?.Object.super.?, type_def));
    }
};

/// Object
pub const ObjObject = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .Object },

    type_def: *ObjTypeDef,

    /// Object name
    name: *ObjString,
    /// Object methods
    methods: std.AutoHashMap(*ObjString, *ObjClosure),
    /// Object fields default values
    fields: std.AutoHashMap(*ObjString, Value),
    /// Object static fields
    static_fields: std.AutoHashMap(*ObjString, Value),
    /// Optional super class
    super: ?*ObjObject = null,

    pub fn init(allocator: Allocator, name: *ObjString, type_def: *ObjTypeDef) Self {
        return Self{
            .name = name,
            .methods = std.AutoHashMap(*ObjString, *ObjClosure).init(allocator),
            .fields = std.AutoHashMap(*ObjString, Value).init(allocator),
            .static_fields = std.AutoHashMap(*ObjString, Value).init(allocator),
            .type_def = type_def,
        };
    }

    pub fn setField(self: *Self, gc: *GarbageCollector, key: *ObjString, value: Value) !void {
        try self.fields.put(key, value);
        try gc.markObjDirty(&self.obj);
    }

    pub fn setStaticField(self: *Self, gc: *GarbageCollector, key: *ObjString, value: Value) !void {
        try self.static_fields.put(key, value);
        try gc.markObjDirty(&self.obj);
    }

    pub fn setMethod(self: *Self, gc: *GarbageCollector, key: *ObjString, closure: *ObjClosure) !void {
        try self.methods.put(key, closure);
        try gc.markObjDirty(&self.obj);
    }

    pub fn mark(self: *Self, gc: *GarbageCollector) !void {
        try gc.markObj(self.type_def.toObj());
        try gc.markObj(self.name.toObj());
        var it = self.methods.iterator();
        while (it.next()) |kv| {
            try gc.markObj(kv.key_ptr.*.toObj());
            try gc.markObj(kv.value_ptr.*.toObj());
        }
        var it2 = self.fields.iterator();
        while (it2.next()) |kv| {
            try gc.markObj(kv.key_ptr.*.toObj());
            try gc.markValue(kv.value_ptr.*);
        }
        var it3 = self.static_fields.iterator();
        while (it3.next()) |kv| {
            try gc.markObj(kv.key_ptr.*.toObj());
            try gc.markValue(kv.value_ptr.*);
        }
        if (self.super) |usuper| {
            try gc.markObj(usuper.toObj());
        }
    }

    pub fn deinit(self: *Self) void {
        self.methods.deinit();
        self.fields.deinit();
        self.static_fields.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Object) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub const ObjectDef = struct {
        const ObjectDefSelf = @This();

        name: *ObjString,
        // TODO: Do i need to have two maps ?
        fields: std.StringHashMap(*ObjTypeDef),
        fields_defaults: std.StringHashMap(void),
        static_fields: std.StringHashMap(*ObjTypeDef),
        methods: std.StringHashMap(*ObjTypeDef),
        // When we have placeholders we don't know if they are properties or methods
        // That information is available only when the placeholder is resolved
        placeholders: std.StringHashMap(*ObjTypeDef),
        static_placeholders: std.StringHashMap(*ObjTypeDef),
        super: ?*ObjTypeDef = null,
        inheritable: bool = false,
        is_class: bool,

        pub fn init(allocator: Allocator, name: *ObjString, is_class: bool) ObjectDefSelf {
            return ObjectDefSelf{
                .name = name,
                .is_class = is_class,
                .fields = std.StringHashMap(*ObjTypeDef).init(allocator),
                .static_fields = std.StringHashMap(*ObjTypeDef).init(allocator),
                .fields_defaults = std.StringHashMap(void).init(allocator),
                .methods = std.StringHashMap(*ObjTypeDef).init(allocator),
                .placeholders = std.StringHashMap(*ObjTypeDef).init(allocator),
                .static_placeholders = std.StringHashMap(*ObjTypeDef).init(allocator),
            };
        }

        pub fn deinit(self: *ObjectDefSelf) void {
            self.fields.deinit();
            self.static_fields.deinit();
            self.fields_defaults.deinit();
            self.methods.deinit();
            self.placeholders.deinit();
            self.static_placeholders.deinit();
        }

        pub fn mark(self: *ObjectDefSelf, gc: *GarbageCollector) !void {
            try gc.markObj(self.name.toObj());

            var it = self.fields.iterator();
            while (it.next()) |kv| {
                try gc.markObj(kv.value_ptr.*.toObj());
            }

            var it3 = self.static_fields.iterator();
            while (it3.next()) |kv| {
                try gc.markObj(kv.value_ptr.*.toObj());
            }

            var it4 = self.methods.iterator();
            while (it4.next()) |kv| {
                try gc.markObj(kv.value_ptr.*.toObj());
            }

            var it5 = self.placeholders.iterator();
            while (it5.next()) |kv| {
                try gc.markObj(kv.value_ptr.*.toObj());
            }

            var it6 = self.static_placeholders.iterator();
            while (it6.next()) |kv| {
                try gc.markObj(kv.value_ptr.*.toObj());
            }

            if (self.super) |super| {
                try gc.markObj(super.toObj());
            }
        }
    };
};

/// List
pub const ObjList = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .List },

    type_def: *ObjTypeDef,

    /// List items
    items: std.ArrayList(Value),

    methods: std.AutoHashMap(*ObjString, *ObjNative),

    pub fn init(allocator: Allocator, type_def: *ObjTypeDef) Self {
        return Self{
            .items = std.ArrayList(Value).init(allocator),
            .type_def = type_def,
            .methods = std.AutoHashMap(*ObjString, *ObjNative).init(allocator),
        };
    }

    pub fn mark(self: *Self, gc: *GarbageCollector) !void {
        for (self.items.items) |value| {
            try gc.markValue(value);
        }
        try gc.markObj(self.type_def.toObj());
        var it = self.methods.iterator();
        while (it.next()) |kv| {
            try gc.markObj(kv.key_ptr.*.toObj());
            try gc.markObj(kv.value_ptr.*.toObj());
        }
    }

    pub fn deinit(self: *Self) void {
        self.items.deinit();
        self.methods.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .List) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    // TODO: find a way to return the same ObjNative pointer for the same type of Lists
    pub fn member(self: *Self, vm: *VM, method: *ObjString) !?*ObjNative {
        if (self.methods.get(method)) |native| {
            return native;
        }

        var nativeFn: ?NativeFn = null;
        if (mem.eql(u8, method.string, "append")) {
            nativeFn = append;
        } else if (mem.eql(u8, method.string, "len")) {
            nativeFn = len;
        } else if (mem.eql(u8, method.string, "next")) {
            nativeFn = next;
        } else if (mem.eql(u8, method.string, "remove")) {
            nativeFn = remove;
        } else if (mem.eql(u8, method.string, "sub")) {
            nativeFn = sub;
        } else if (mem.eql(u8, method.string, "indexOf")) {
            nativeFn = indexOf;
        } else if (mem.eql(u8, method.string, "join")) {
            nativeFn = join;
        }

        if (nativeFn) |unativeFn| {
            var native: *ObjNative = try vm.gc.allocateObject(
                ObjNative,
                .{
                    .native = unativeFn,
                },
            );

            try self.methods.put(method, native);

            return native;
        }

        return null;
    }

    pub fn rawAppend(self: *Self, gc: *GarbageCollector, value: Value) !void {
        try self.items.append(value);
        try gc.markObjDirty(&self.obj);
    }

    pub fn set(self: *Self, gc: *GarbageCollector, index: usize, value: Value) !void {
        self.items.items[index] = value;
        try gc.markObjDirty(&self.obj);
    }

    fn append(vm: *VM) c_int {
        var list_value: Value = vm.peek(1);
        var list: *ObjList = ObjList.cast(list_value.Obj).?;
        var value: Value = vm.peek(0);

        list.rawAppend(vm.gc, value) catch |err| {
            const messageValue: Value = (vm.gc.copyString("Could not append to list") catch {
                std.debug.print("Could not append to list", .{});
                std.os.exit(1);
            }).toValue();

            vm.throw(err, messageValue) catch {
                std.debug.print("Could not append to list", .{});
                std.os.exit(1);
            };
            return -1;
        };

        vm.push(list_value);

        return 1;
    }

    fn len(vm: *VM) c_int {
        var list: *ObjList = ObjList.cast(vm.peek(0).Obj).?;

        vm.push(Value{ .Integer = @intCast(i64, list.items.items.len) });

        return 1;
    }

    pub fn remove(vm: *VM) c_int {
        var list: *ObjList = ObjList.cast(vm.peek(1).Obj).?;
        var list_index_value = floatToInteger(vm.peek(0));
        var list_index: ?i64 = if (list_index_value == .Integer) list_index_value.Integer else null;

        if (list_index == null or list_index.? < 0 or list_index.? >= list.items.items.len) {
            vm.push(Value{ .Null = {} });

            return 1;
        }

        vm.push(list.items.orderedRemove(@intCast(usize, list_index.?)));
        vm.gc.markObjDirty(&list.obj) catch {
            std.debug.print("Could not remove from list", .{});
            std.os.exit(1);
        };

        return 1;
    }

    pub fn indexOf(vm: *VM) c_int {
        var self: *Self = Self.cast(vm.peek(1).Obj).?;
        var needle: Value = vm.peek(0);

        var index: ?usize = 0;
        var i: usize = 0;
        for (self.items.items) |item| {
            if (valueEql(needle, item)) {
                index = i;
                break;
            }

            i += 1;
        }

        vm.push(if (index) |uindex| Value{ .Integer = @intCast(i64, uindex) } else Value{ .Null = {} });

        return 1;
    }

    pub fn join(vm: *VM) c_int {
        var self: *Self = Self.cast(vm.peek(1).Obj).?;
        var separator: *ObjString = ObjString.cast(vm.peek(0).Obj).?;

        var result = std.ArrayList(u8).init(vm.gc.allocator);
        var writer = result.writer();
        defer result.deinit();
        for (self.items.items) |item, i| {
            valueToString(writer, item) catch {
                var err: ?*ObjString = vm.gc.copyString("could not stringify item") catch null;
                vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

                return -1;
            };

            if (i + 1 < self.items.items.len) {
                writer.writeAll(separator.string) catch {
                    var err: ?*ObjString = vm.gc.copyString("could not join list") catch null;
                    vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

                    return -1;
                };
            }
        }

        vm.push(
            Value{
                .Obj = (vm.gc.copyString(result.items) catch {
                    var err: ?*ObjString = vm.gc.copyString("could not join list") catch null;
                    vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

                    return -1;
                }).toObj(),
            },
        );

        return 1;
    }

    pub fn sub(vm: *VM) c_int {
        var self: *Self = Self.cast(vm.peek(2).Obj).?;
        var start_value = floatToInteger(vm.peek(1));
        var start: ?i64 = if (start_value == .Integer) start_value.Integer else null;
        var upto_value: Value = floatToInteger(vm.peek(0));
        var upto: ?i64 = if (upto_value == .Integer) upto_value.Integer else if (upto_value == .Float) @floatToInt(i64, upto_value.Float) else null;

        if (start == null or start.? < 0 or start.? >= self.items.items.len) {
            var err: ?*ObjString = vm.gc.copyString("`start` is out of bound") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        }

        if (upto != null and upto.? < 0) {
            var err: ?*ObjString = vm.gc.copyString("`len` must greater or equal to 0") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        }

        const limit: usize = if (upto != null and @intCast(usize, start.? + upto.?) < self.items.items.len) @intCast(usize, start.? + upto.?) else self.items.items.len;
        var substr: []Value = self.items.items[@intCast(usize, start.?)..limit];

        var list = vm.gc.allocateObject(ObjList, ObjList{
            .type_def = self.type_def,
            .methods = self.methods.clone() catch {
                var err: ?*ObjString = vm.gc.copyString("Could not get sub list") catch null;
                vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

                return -1;
            },
            .items = std.ArrayList(Value).init(vm.gc.allocator),
        }) catch {
            var err: ?*ObjString = vm.gc.copyString("Could not get sub list") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };

        vm.push(list.toValue());

        list.items.appendSlice(substr) catch {
            var err: ?*ObjString = vm.gc.copyString("Could not get sub list") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };

        return 1;
    }

    pub fn rawNext(self: *Self, vm: *VM, list_index: ?i64) !?i64 {
        if (list_index) |index| {
            if (index < 0 or index >= @intCast(i64, self.items.items.len)) {
                try vm.throw(VM.Error.OutOfBound, (try vm.gc.copyString("Out of bound access to list")).toValue());
            }

            return if (index + 1 >= @intCast(i64, self.items.items.len))
                null
            else
                index + 1;
        } else {
            return if (self.items.items.len > 0) @intCast(i64, 0) else null;
        }
    }

    fn next(vm: *VM) c_int {
        var list_value: Value = vm.peek(1);
        var list: *ObjList = ObjList.cast(list_value.Obj).?;
        var list_index: Value = vm.peek(0);

        var next_index: ?i64 = list.rawNext(vm, if (list_index == .Null) null else list_index.Integer) catch |err| {
            // TODO: should we distinguish NativeFn and ExternFn ?
            std.debug.print("{}\n", .{err});
            std.os.exit(1);
        };

        vm.push(if (next_index) |unext_index| Value{ .Integer = unext_index } else Value{ .Null = {} });

        return 1;
    }

    pub const ListDef = struct {
        const SelfListDef = @This();

        item_type: *ObjTypeDef,
        methods: std.StringHashMap(*ObjTypeDef),

        pub fn init(allocator: Allocator, item_type: *ObjTypeDef) SelfListDef {
            return .{
                .item_type = item_type,
                .methods = std.StringHashMap(*ObjTypeDef).init(allocator),
            };
        }

        pub fn deinit(self: *SelfListDef) void {
            self.methods.deinit();
        }

        pub fn mark(self: *SelfListDef, gc: *GarbageCollector) !void {
            try gc.markObj(self.item_type.toObj());
            var it = self.methods.iterator();
            while (it.next()) |method| {
                try gc.markObj(method.value_ptr.*.toObj());
            }
        }

        pub fn member(obj_list: *ObjTypeDef, parser: *Parser, method: []const u8) !?*ObjTypeDef {
            var self = obj_list.resolved_type.?.List;

            if (self.methods.get(method)) |native_def| {
                return native_def;
            }

            if (mem.eql(u8, method, "append")) {
                var parameters = std.AutoArrayHashMap(*ObjString, *ObjTypeDef).init(parser.gc.allocator);

                // We omit first arg: it'll be OP_SWAPed in and we already parsed it
                // It's always the list.

                // `value` arg is of item_type
                try parameters.put(try parser.gc.copyString("value"), self.item_type);

                var method_def = ObjFunction.FunctionDef{
                    .name = try parser.gc.copyString("append"),
                    .parameters = parameters,
                    .defaults = std.AutoArrayHashMap(*ObjString, Value).init(parser.gc.allocator),
                    .return_type = obj_list,
                    .yield_type = try parser.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{ .Function = method_def };

                var native_type = try parser.gc.type_registry.getTypeDef(ObjTypeDef{ .def_type = .Function, .resolved_type = resolved_type });

                try self.methods.put("append", native_type);

                return native_type;
            } else if (mem.eql(u8, method, "remove")) {
                var parameters = std.AutoArrayHashMap(*ObjString, *ObjTypeDef).init(parser.gc.allocator);

                // We omit first arg: it'll be OP_SWAPed in and we already parsed it
                // It's always the list.

                var at_type = try parser.gc.type_registry.getTypeDef(
                    ObjTypeDef{
                        .def_type = .Number,
                        .optional = false,
                    },
                );

                try parameters.put(try parser.gc.copyString("at"), at_type);

                var method_def = ObjFunction.FunctionDef{
                    .name = try parser.gc.copyString("remove"),
                    .parameters = parameters,
                    .defaults = std.AutoArrayHashMap(*ObjString, Value).init(parser.gc.allocator),
                    .return_type = try parser.gc.type_registry.getTypeDef(.{
                        .optional = true,
                        .def_type = self.item_type.def_type,
                        .resolved_type = self.item_type.resolved_type,
                    }),
                    .yield_type = try parser.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{ .Function = method_def };

                var native_type = try parser.gc.type_registry.getTypeDef(
                    ObjTypeDef{
                        .def_type = .Function,
                        .resolved_type = resolved_type,
                    },
                );

                try self.methods.put("remove", native_type);

                return native_type;
            } else if (mem.eql(u8, method, "len")) {
                var parameters = std.AutoArrayHashMap(*ObjString, *ObjTypeDef).init(parser.gc.allocator);

                var method_def = ObjFunction.FunctionDef{
                    .name = try parser.gc.copyString("len"),
                    .parameters = parameters,
                    .defaults = std.AutoArrayHashMap(*ObjString, Value).init(parser.gc.allocator),
                    .return_type = try parser.gc.type_registry.getTypeDef(
                        ObjTypeDef{
                            .def_type = .Number,
                        },
                    ),
                    .yield_type = try parser.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{ .Function = method_def };

                var native_type = try parser.gc.type_registry.getTypeDef(
                    ObjTypeDef{
                        .def_type = .Function,
                        .resolved_type = resolved_type,
                    },
                );

                try self.methods.put("len", native_type);

                return native_type;
            } else if (mem.eql(u8, method, "next")) {
                var parameters = std.AutoArrayHashMap(*ObjString, *ObjTypeDef).init(parser.gc.allocator);

                // We omit first arg: it'll be OP_SWAPed in and we already parsed it
                // It's always the list.

                // `key` arg is number
                try parameters.put(
                    try parser.gc.copyString("key"),
                    try parser.gc.type_registry.getTypeDef(
                        ObjTypeDef{
                            .def_type = .Number,
                            .optional = true,
                        },
                    ),
                );

                var method_def = ObjFunction.FunctionDef{
                    .name = try parser.gc.copyString("next"),
                    .parameters = parameters,
                    .defaults = std.AutoArrayHashMap(*ObjString, Value).init(parser.gc.allocator),
                    // When reached end of list, returns null
                    .return_type = try parser.gc.type_registry.getTypeDef(
                        ObjTypeDef{
                            .def_type = .Number,
                            .optional = true,
                        },
                    ),
                    .yield_type = try parser.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{ .Function = method_def };

                var native_type = try parser.gc.type_registry.getTypeDef(
                    ObjTypeDef{
                        .def_type = .Function,
                        .resolved_type = resolved_type,
                    },
                );

                try self.methods.put("next", native_type);

                return native_type;
            } else if (mem.eql(u8, method, "sub")) {
                var parameters = std.AutoArrayHashMap(*ObjString, *ObjTypeDef).init(parser.gc.allocator);

                // We omit first arg: it'll be OP_SWAPed in and we already parsed it
                // It's always the string.

                try parameters.put(
                    try parser.gc.copyString("start"),
                    try parser.gc.type_registry.getTypeDef(
                        .{
                            .def_type = .Number,
                        },
                    ),
                );
                try parameters.put(
                    try parser.gc.copyString("len"),
                    try parser.gc.type_registry.getTypeDef(
                        .{
                            .def_type = .Number,
                            .optional = true,
                        },
                    ),
                );

                var method_def = ObjFunction.FunctionDef{
                    .name = try parser.gc.copyString("sub"),
                    .parameters = parameters,
                    .defaults = std.AutoArrayHashMap(*ObjString, Value).init(parser.gc.allocator),
                    .return_type = obj_list,
                    .yield_type = try parser.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{ .Function = method_def };

                var native_type = try parser.gc.type_registry.getTypeDef(
                    ObjTypeDef{
                        .def_type = .Function,
                        .resolved_type = resolved_type,
                    },
                );

                try self.methods.put("sub", native_type);

                return native_type;
            } else if (mem.eql(u8, method, "indexOf")) {
                var parameters = std.AutoArrayHashMap(*ObjString, *ObjTypeDef).init(parser.gc.allocator);

                // We omit first arg: it'll be OP_SWAPed in and we already parsed it
                // It's always the string.

                try parameters.put(try parser.gc.copyString("needle"), self.item_type);

                var method_def = ObjFunction.FunctionDef{
                    .name = try parser.gc.copyString("indexOf"),
                    .parameters = parameters,
                    .defaults = std.AutoArrayHashMap(*ObjString, Value).init(parser.gc.allocator),
                    .return_type = try parser.gc.type_registry.getTypeDef(
                        .{
                            .def_type = self.item_type.def_type,
                            .optional = true,
                            .resolved_type = self.item_type.resolved_type,
                        },
                    ),
                    .yield_type = try parser.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{ .Function = method_def };

                var native_type = try parser.gc.type_registry.getTypeDef(
                    ObjTypeDef{
                        .def_type = .Function,
                        .resolved_type = resolved_type,
                    },
                );

                try self.methods.put("indexOf", native_type);

                return native_type;
            } else if (mem.eql(u8, method, "join")) {
                var parameters = std.AutoArrayHashMap(*ObjString, *ObjTypeDef).init(parser.gc.allocator);

                // We omit first arg: it'll be OP_SWAPed in and we already parsed it
                // It's always the string.

                try parameters.put(try parser.gc.copyString("separator"), try parser.gc.type_registry.getTypeDef(.{ .def_type = .String }));

                var method_def = ObjFunction.FunctionDef{
                    .name = try parser.gc.copyString("join"),
                    .parameters = parameters,
                    .defaults = std.AutoArrayHashMap(*ObjString, Value).init(parser.gc.allocator),
                    .return_type = try parser.gc.type_registry.getTypeDef(ObjTypeDef{
                        .def_type = .String,
                    }),
                    .yield_type = try parser.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{ .Function = method_def };

                var native_type = try parser.gc.type_registry.getTypeDef(
                    ObjTypeDef{
                        .def_type = .Function,
                        .resolved_type = resolved_type,
                    },
                );

                try self.methods.put("join", native_type);

                return native_type;
            }

            return null;
        }
    };
};

/// Map
pub const ObjMap = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .Map },

    type_def: *ObjTypeDef,

    // We need an ArrayHashMap for `next`
    // In order to use a regular HashMap, we would have to hack are away around it to implement next
    map: std.AutoArrayHashMap(HashableValue, Value),

    methods: std.AutoHashMap(*ObjString, *ObjNative),

    pub fn init(allocator: Allocator, type_def: *ObjTypeDef) Self {
        return .{
            .type_def = type_def,
            .map = std.AutoArrayHashMap(HashableValue, Value).init(allocator),
            .methods = std.AutoHashMap(*ObjString, *ObjNative).init(allocator),
        };
    }

    pub fn set(self: *Self, gc: *GarbageCollector, key: Value, value: Value) !void {
        try self.map.put(valueToHashable(key), value);
        try gc.markObjDirty(&self.obj);
    }

    pub fn member(self: *Self, vm: *VM, method: *ObjString) !?*ObjNative {
        if (self.methods.get(method)) |native| {
            return native;
        }

        var nativeFn: ?NativeFn = null;
        if (mem.eql(u8, method.string, "remove")) {
            nativeFn = remove;
        } else if (mem.eql(u8, method.string, "size")) {
            nativeFn = size;
        } else if (mem.eql(u8, method.string, "keys")) {
            nativeFn = keys;
        } else if (mem.eql(u8, method.string, "values")) {
            nativeFn = values;
        }

        if (nativeFn) |unativeFn| {
            var native: *ObjNative = try vm.gc.allocateObject(
                ObjNative,
                .{
                    .native = unativeFn,
                },
            );

            try self.methods.put(method, native);

            return native;
        }

        return null;
    }

    pub fn mark(self: *Self, gc: *GarbageCollector) !void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            try gc.markValue(hashableToValue(kv.key_ptr.*));
            try gc.markValue(kv.value_ptr.*);
        }

        var it2 = self.methods.iterator();
        while (it2.next()) |kv| {
            try gc.markObj(kv.key_ptr.*.toObj());
            try gc.markObj(kv.value_ptr.*.toObj());
        }

        try gc.markObj(self.type_def.toObj());
    }

    fn size(vm: *VM) c_int {
        var map: *ObjMap = ObjMap.cast(vm.peek(0).Obj).?;

        vm.push(Value{ .Integer = @intCast(i64, map.map.count()) });

        return 1;
    }

    pub fn remove(vm: *VM) c_int {
        var map: *ObjMap = ObjMap.cast(vm.peek(1).Obj).?;
        var map_key: HashableValue = valueToHashable(vm.peek(0));

        if (map.map.fetchOrderedRemove(map_key)) |removed| {
            vm.push(removed.value);
        } else {
            vm.push(Value{ .Null = {} });
        }

        return 1;
    }

    pub fn keys(vm: *VM) c_int {
        var self: *ObjMap = ObjMap.cast(vm.peek(0).Obj).?;

        var map_keys: []HashableValue = self.map.keys();
        var result = std.ArrayList(Value).init(vm.gc.allocator);
        for (map_keys) |key| {
            result.append(hashableToValue(key)) catch {
                var err: ?*ObjString = vm.gc.copyString("could not get map keys") catch null;
                vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

                return -1;
            };
        }

        var list_def: ObjList.ListDef = ObjList.ListDef.init(
            vm.gc.allocator,
            self.type_def.resolved_type.?.Map.key_type,
        );

        var list_def_union: ObjTypeDef.TypeUnion = .{
            .List = list_def,
        };

        var list_def_type: *ObjTypeDef = vm.gc.type_registry.getTypeDef(ObjTypeDef{
            .def_type = .List,
            .optional = false,
            .resolved_type = list_def_union,
        }) catch {
            var err: ?*ObjString = vm.gc.copyString("could not get map keys") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };

        // Prevent collection
        vm.push(list_def_type.toValue());

        var list = vm.gc.allocateObject(
            ObjList,
            ObjList.init(vm.gc.allocator, list_def_type),
        ) catch {
            var err: ?*ObjString = vm.gc.copyString("could not get map keys") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };

        list.items.deinit();
        list.items = result;

        _ = vm.pop();
        vm.push(list.toValue());

        return 1;
    }

    pub fn values(vm: *VM) c_int {
        var self: *ObjMap = ObjMap.cast(vm.peek(0).Obj).?;

        var map_values: []Value = self.map.values();
        var result = std.ArrayList(Value).init(vm.gc.allocator);
        result.appendSlice(map_values) catch {
            var err: ?*ObjString = vm.gc.copyString("could not get map values") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };

        var list_def: ObjList.ListDef = ObjList.ListDef.init(
            vm.gc.allocator,
            self.type_def.resolved_type.?.Map.value_type,
        );

        var list_def_union: ObjTypeDef.TypeUnion = .{
            .List = list_def,
        };

        var list_def_type: *ObjTypeDef = vm.gc.type_registry.getTypeDef(ObjTypeDef{
            .def_type = .List,
            .optional = false,
            .resolved_type = list_def_union,
        }) catch {
            var err: ?*ObjString = vm.gc.copyString("could not get map values") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };

        var list = vm.gc.allocateObject(
            ObjList,
            ObjList.init(vm.gc.allocator, list_def_type),
        ) catch {
            var err: ?*ObjString = vm.gc.copyString("could not get map values") catch null;
            vm.throw(VM.Error.OutOfBound, if (err) |uerr| uerr.toValue() else Value{ .Boolean = false }) catch unreachable;

            return -1;
        };

        list.items.deinit();
        list.items = result;

        vm.push(list.toValue());

        return 1;
    }

    pub fn rawNext(self: *Self, key: ?HashableValue) ?HashableValue {
        const map_keys: []HashableValue = self.map.keys();

        if (key) |ukey| {
            const index: usize = self.map.getIndex(ukey).?;

            if (index < map_keys.len - 1) {
                return map_keys[index + 1];
            } else {
                return null;
            }
        } else {
            return if (map_keys.len > 0) map_keys[0] else null;
        }
    }

    pub fn deinit(self: *Self) void {
        self.map.deinit();
        self.methods.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Map) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub const MapDef = struct {
        const SelfMapDef = @This();

        key_type: *ObjTypeDef,
        value_type: *ObjTypeDef,

        methods: std.StringHashMap(*ObjTypeDef),

        pub fn init(allocator: Allocator, key_type: *ObjTypeDef, value_type: *ObjTypeDef) SelfMapDef {
            return .{
                .key_type = key_type,
                .value_type = value_type,
                .methods = std.StringHashMap(*ObjTypeDef).init(allocator),
            };
        }

        pub fn deinit(self: *SelfMapDef) void {
            self.methods.deinit();
        }

        pub fn mark(self: *SelfMapDef, gc: *GarbageCollector) !void {
            try gc.markObj(self.key_type.toObj());
            try gc.markObj(self.value_type.toObj());
            var it = self.methods.iterator();
            while (it.next()) |method| {
                try gc.markObj(method.value_ptr.*.toObj());
            }
        }

        pub fn member(obj_map: *ObjTypeDef, parser: *Parser, method: []const u8) !?*ObjTypeDef {
            var self = obj_map.resolved_type.?.Map;

            if (self.methods.get(method)) |native_def| {
                return native_def;
            }

            if (mem.eql(u8, method, "size")) {
                var method_def = ObjFunction.FunctionDef{
                    .name = try parser.gc.copyString("size"),
                    .parameters = std.AutoArrayHashMap(*ObjString, *ObjTypeDef).init(parser.gc.allocator),
                    .defaults = std.AutoArrayHashMap(*ObjString, Value).init(parser.gc.allocator),
                    .return_type = try parser.gc.type_registry.getTypeDef(.{
                        .def_type = .Number,
                    }),
                    .yield_type = try parser.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{ .Function = method_def };

                var native_type = try parser.gc.type_registry.getTypeDef(
                    ObjTypeDef{
                        .def_type = .Function,
                        .resolved_type = resolved_type,
                    },
                );

                try self.methods.put("size", native_type);

                return native_type;
            } else if (mem.eql(u8, method, "remove")) {
                var parameters = std.AutoArrayHashMap(*ObjString, *ObjTypeDef).init(parser.gc.allocator);

                // We omit first arg: it'll be OP_SWAPed in and we already parsed it
                // It's always the list.

                try parameters.put(try parser.gc.copyString("at"), self.key_type);

                var method_def = ObjFunction.FunctionDef{
                    .name = try parser.gc.copyString("remove"),
                    .parameters = parameters,
                    .defaults = std.AutoArrayHashMap(*ObjString, Value).init(parser.gc.allocator),
                    .return_type = try parser.gc.type_registry.getTypeDef(.{
                        .optional = true,
                        .def_type = self.value_type.def_type,
                        .resolved_type = self.value_type.resolved_type,
                    }),
                    .yield_type = try parser.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{ .Function = method_def };

                var native_type = try parser.gc.type_registry.getTypeDef(
                    ObjTypeDef{
                        .def_type = .Function,
                        .resolved_type = resolved_type,
                    },
                );

                try self.methods.put("remove", native_type);

                return native_type;
            } else if (mem.eql(u8, method, "keys")) {
                var list_def: ObjList.ListDef = ObjList.ListDef.init(
                    parser.gc.allocator,
                    self.key_type,
                );

                var list_def_union: ObjTypeDef.TypeUnion = .{
                    .List = list_def,
                };

                var method_def = ObjFunction.FunctionDef{
                    .name = try parser.gc.copyString("keys"),
                    .parameters = std.AutoArrayHashMap(*ObjString, *ObjTypeDef).init(parser.gc.allocator),
                    .defaults = std.AutoArrayHashMap(*ObjString, Value).init(parser.gc.allocator),
                    .return_type = try parser.gc.type_registry.getTypeDef(.{
                        .def_type = .List,
                        .optional = false,
                        .resolved_type = list_def_union,
                    }),
                    .yield_type = try parser.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{ .Function = method_def };

                var native_type = try parser.gc.type_registry.getTypeDef(
                    ObjTypeDef{
                        .def_type = .Function,
                        .resolved_type = resolved_type,
                    },
                );

                try self.methods.put("keys", native_type);

                return native_type;
            } else if (mem.eql(u8, method, "values")) {
                var list_def: ObjList.ListDef = ObjList.ListDef.init(
                    parser.gc.allocator,
                    self.value_type,
                );

                var list_def_union: ObjTypeDef.TypeUnion = .{
                    .List = list_def,
                };

                var method_def = ObjFunction.FunctionDef{
                    .name = try parser.gc.copyString("values"),
                    .parameters = std.AutoArrayHashMap(*ObjString, *ObjTypeDef).init(parser.gc.allocator),
                    .defaults = std.AutoArrayHashMap(*ObjString, Value).init(parser.gc.allocator),
                    .return_type = try parser.gc.type_registry.getTypeDef(.{
                        .def_type = .List,
                        .optional = false,
                        .resolved_type = list_def_union,
                    }),
                    .yield_type = try parser.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
                };

                var resolved_type: ObjTypeDef.TypeUnion = .{ .Function = method_def };

                var native_type = try parser.gc.type_registry.getTypeDef(
                    ObjTypeDef{
                        .def_type = .Function,
                        .resolved_type = resolved_type,
                    },
                );

                try self.methods.put("values", native_type);

                return native_type;
            }

            return null;
        }
    };
};

/// Enum
pub const ObjEnum = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .Enum },

    /// Used to allow type checking at runtime
    type_def: *ObjTypeDef,

    name: *ObjString,
    cases: std.ArrayList(Value),

    pub fn init(allocator: Allocator, def: *ObjTypeDef) Self {
        return Self{
            .type_def = def,
            .name = def.resolved_type.?.Enum.name,
            .cases = std.ArrayList(Value).init(allocator),
        };
    }

    pub fn mark(self: *Self, gc: *GarbageCollector) !void {
        try gc.markObj(self.name.toObj());
        try gc.markObj(self.type_def.toObj());
        for (self.cases.items) |case| {
            try gc.markValue(case);
        }
    }

    pub fn rawNext(self: *Self, vm: *VM, enum_case: ?*ObjEnumInstance) !?*ObjEnumInstance {
        if (enum_case) |case| {
            assert(case.enum_ref == self);

            if (case.case == self.cases.items.len - 1) {
                return null;
            }

            return try vm.gc.allocateObject(ObjEnumInstance, ObjEnumInstance{
                .enum_ref = self,
                .case = @intCast(u8, case.case + 1),
            });
        } else {
            return try vm.gc.allocateObject(ObjEnumInstance, ObjEnumInstance{
                .enum_ref = self,
                .case = 0,
            });
        }
    }

    pub fn deinit(self: *Self) void {
        self.cases.deinit();
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Enum) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub const EnumDef = struct {
        const EnumDefSelf = @This();

        name: *ObjString,
        enum_type: *ObjTypeDef,
        cases: std.ArrayList([]const u8),

        pub fn init(allocator: Allocator, name: *ObjString, enum_type: *ObjTypeDef) EnumDefSelf {
            return EnumDefSelf{
                .name = name,
                .cases = std.ArrayList([]const u8).init(allocator),
                .enum_type = enum_type,
            };
        }

        pub fn deinit(self: *EnumDefSelf) void {
            self.cases.deinit();
        }

        pub fn mark(self: *EnumDefSelf, gc: *GarbageCollector) !void {
            try gc.markObj(self.name.toObj());
            try gc.markObj(self.enum_type.toObj());
        }
    };
};

pub const ObjEnumInstance = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .EnumInstance },

    enum_ref: *ObjEnum,
    case: u8,

    pub fn mark(self: *Self, gc: *GarbageCollector) !void {
        try gc.markObj(self.enum_ref.toObj());
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .EnumInstance) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub fn value(self: *Self) Value {
        return self.enum_ref.cases.items[self.case];
    }
};

/// Bound
pub const ObjBoundMethod = struct {
    const Self = @This();

    obj: Obj = .{ .obj_type = .Bound },

    receiver: Value,
    closure: ?*ObjClosure = null,
    native: ?*ObjNative = null,

    pub fn mark(self: *Self, gc: *GarbageCollector) !void {
        try gc.markValue(self.receiver);
        if (self.closure) |closure| {
            try gc.markObj(closure.toObj());
        }
        if (self.native) |native| {
            try gc.markObj(native.toObj());
        }
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Bound) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }
};

/// Type
pub const ObjTypeDef = struct {
    const Self = @This();

    // TODO: merge this with ObjType
    pub const Type = enum {
        Bool,
        Number,
        String,
        Pattern,
        ObjectInstance,
        Object,
        Enum,
        EnumInstance,
        List,
        Map,
        Function,
        Type, // Something that holds a type, not an actual type
        Void,
        Fiber,
        UserData,

        Placeholder, // Used in first-pass when we refer to a not yet parsed type
    };

    pub const TypeUnion = union(Type) {
        // For those type checking is obvious, the value is a placeholder
        Bool: void,
        Number: void,
        String: void,
        Pattern: void,
        Type: void,
        Void: void,
        UserData: void,
        Fiber: ObjFiber.FiberDef,

        // For those we check that the value is an instance of, because those are user defined types
        ObjectInstance: *ObjTypeDef,
        EnumInstance: *ObjTypeDef,

        // Those are never equal
        Object: ObjObject.ObjectDef,
        Enum: ObjEnum.EnumDef,

        // For those we compare definitions, so we own those structs, we don't use actual Obj because we don't want the data, only the types
        List: ObjList.ListDef,
        Map: ObjMap.MapDef,
        Function: ObjFunction.FunctionDef,

        Placeholder: PlaceholderDef,
    };

    obj: Obj = .{ .obj_type = .Type },

    /// True means its an optional (e.g `str?`)
    optional: bool = false,
    def_type: Type,
    /// Used when the type is not a basic type
    resolved_type: ?TypeUnion = null,

    pub fn mark(self: *Self, gc: *GarbageCollector) !void {
        if (self.resolved_type) |*resolved| {
            if (resolved.* == .ObjectInstance) {
                try gc.markObj(resolved.ObjectInstance.toObj());
            } else if (resolved.* == .EnumInstance) {
                try gc.markObj(resolved.EnumInstance.toObj());
            } else if (resolved.* == .Object) {
                try resolved.Object.mark(gc);
            } else if (resolved.* == .Enum) {
                try resolved.Enum.mark(gc);
            } else if (resolved.* == .Function) {
                try resolved.Function.mark(gc);
            } else if (resolved.* == .List) {
                try resolved.List.mark(gc);
            } else if (resolved.* == .Map) {
                try resolved.Map.mark(gc);
            } else if (resolved.* == .Fiber) {
                try resolved.Fiber.mark(gc);
            } else if (resolved.* == .Placeholder) {
                unreachable;
            }
        }
    }

    pub fn rawCloneOptional(self: *Self) ObjTypeDef {
        return .{
            .obj = .{ .obj_type = self.obj.obj_type },
            .optional = true,
            .def_type = self.def_type,
            .resolved_type = self.resolved_type,
        };
    }

    pub fn rawCloneNonOptional(self: *Self) ObjTypeDef {
        return .{
            .obj = .{ .obj_type = self.obj.obj_type },
            .optional = false,
            .def_type = self.def_type,
            .resolved_type = self.resolved_type,
        };
    }

    pub fn cloneOptional(self: *Self, type_registry: *TypeRegistry) !*ObjTypeDef {
        // If already optional return itself
        if (self.optional and self.def_type != .Placeholder) {
            return self;
        }

        const optional = try type_registry.getTypeDef(self.rawCloneOptional());

        if (self.def_type == .Placeholder) {
            // Destroyed copied placeholder link
            optional.resolved_type.?.Placeholder.parent = null;
            optional.resolved_type.?.Placeholder.parent_relation = null;
            optional.resolved_type.?.Placeholder.children = std.ArrayList(*ObjTypeDef).init(type_registry.gc.allocator);

            // Make actual link
            try PlaceholderDef.link(self, optional, .Optional);
        }

        return optional;
    }

    pub fn cloneNonOptional(self: *Self, type_registry: *TypeRegistry) !*ObjTypeDef {
        // If already non optional return itself
        if (!self.optional and self.def_type != .Placeholder) {
            return self;
        }

        const non_optional = try type_registry.getTypeDef(self.rawCloneNonOptional());

        if (self.def_type == .Placeholder) {
            // Destroyed copied placeholder link
            non_optional.resolved_type.?.Placeholder.parent = null;
            non_optional.resolved_type.?.Placeholder.parent_relation = null;
            non_optional.resolved_type.?.Placeholder.children = std.ArrayList(*ObjTypeDef).init(type_registry.gc.allocator);

            // Make actual link
            try PlaceholderDef.link(self, non_optional, .Unwrap);
        }

        return non_optional;
    }

    pub fn deinit(_: *Self) void {}

    pub fn toStringAlloc(self: *const Self, allocator: Allocator) (Allocator.Error || std.fmt.BufPrintError)![]const u8 {
        var str = std.ArrayList(u8).init(allocator);

        try self.toString(str.writer());

        return str.items;
    }

    pub fn toString(self: *const Self, writer: std.ArrayList(u8).Writer) (Allocator.Error || std.fmt.BufPrintError)!void {
        switch (self.def_type) {
            .UserData => try writer.writeAll("ud"),
            .Bool => try writer.writeAll("bool"),
            .Number => try writer.writeAll("num"),
            .String => try writer.writeAll("str"),
            .Pattern => try writer.writeAll("pat"),
            .Fiber => {
                try writer.writeAll("fib<");
                try self.resolved_type.?.Fiber.return_type.toString(writer);
                try writer.writeAll(", ");
                try self.resolved_type.?.Fiber.yield_type.toString(writer);
                try writer.writeAll(">");
            },

            // TODO: Find a key for vm.getTypeDef which is unique for each class even with the same name
            .Object => {
                const object_def = self.resolved_type.?.Object;

                try writer.writeAll(if (object_def.is_class) "class " else "object ");
                try writer.writeAll(object_def.name.string);
            },
            .Enum => {
                try writer.writeAll("enum ");
                try writer.writeAll(self.resolved_type.?.Enum.name.string);
            },

            .ObjectInstance => try writer.writeAll(self.resolved_type.?.ObjectInstance.resolved_type.?.Object.name.string),
            .EnumInstance => try writer.writeAll(self.resolved_type.?.EnumInstance.resolved_type.?.Enum.name.string),

            .List => {
                try writer.writeAll("[");
                try self.resolved_type.?.List.item_type.toString(writer);
                try writer.writeAll("]");
            },
            .Map => {
                try writer.writeAll("{");
                try self.resolved_type.?.Map.key_type.toString(writer);
                try writer.writeAll(", ");
                try self.resolved_type.?.Map.value_type.toString(writer);
                try writer.writeAll("}");
            },
            .Function => {
                var function_def = self.resolved_type.?.Function;

                try writer.writeAll("fun ");
                try writer.writeAll(function_def.name.string);
                try writer.writeAll("(");

                const size = function_def.parameters.count();
                var i: usize = 0;
                var it = function_def.parameters.iterator();
                while (it.next()) |kv| : (i = i + 1) {
                    try kv.value_ptr.*.toString(writer);
                    try writer.writeAll(" ");
                    try writer.writeAll(kv.key_ptr.*.string);

                    if (i < size - 1) {
                        try writer.writeAll(", ");
                    }
                }

                try writer.writeAll(")");

                if (function_def.yield_type.def_type != .Void) {
                    try writer.writeAll(" > ");
                    try function_def.yield_type.toString(writer);
                }

                try writer.writeAll(" > ");
                try function_def.return_type.toString(writer);
            },
            .Type => try writer.writeAll("type"),
            .Void => try writer.writeAll("void"),

            .Placeholder => {
                try writer.print("{{PlaceholderDef @{}}}", .{@ptrToInt(self)});
            },
        }

        if (self.optional) {
            try writer.writeAll("?");
        }
    }

    pub fn toObj(self: *Self) *Obj {
        return &self.obj;
    }

    pub fn toValue(self: *Self) Value {
        return Value{ .Obj = self.toObj() };
    }

    pub fn toInstance(self: *Self, allocator: Allocator, type_registry: *TypeRegistry) !*Self {
        var instance_type = try type_registry.getTypeDef(
            switch (self.def_type) {
                .Object => object: {
                    var resolved_type: ObjTypeDef.TypeUnion = ObjTypeDef.TypeUnion{ .ObjectInstance = try self.cloneNonOptional(type_registry) };

                    break :object Self{
                        .optional = self.optional,
                        .def_type = .ObjectInstance,
                        .resolved_type = resolved_type,
                    };
                },
                .Enum => enum_instance: {
                    var resolved_type: ObjTypeDef.TypeUnion = ObjTypeDef.TypeUnion{ .EnumInstance = try self.cloneNonOptional(type_registry) };

                    break :enum_instance Self{
                        .optional = self.optional,
                        .def_type = .EnumInstance,
                        .resolved_type = resolved_type,
                    };
                },
                .Placeholder => placeholder: {
                    var placeholder_resolved_type: ObjTypeDef.TypeUnion = .{
                        .Placeholder = PlaceholderDef.init(
                            allocator,
                            self.resolved_type.?.Placeholder.where.clone(),
                        ),
                    };
                    placeholder_resolved_type.Placeholder.name = self.resolved_type.?.Placeholder.name;

                    break :placeholder Self{
                        .def_type = .Placeholder,
                        .resolved_type = placeholder_resolved_type,
                    };
                },
                else => self.*,
            },
        );

        if (self.def_type == .Placeholder and instance_type.def_type == .Placeholder) {
            try PlaceholderDef.link(self, instance_type, .Instance);
        }

        return instance_type;
    }

    pub fn cast(obj: *Obj) ?*Self {
        if (obj.obj_type != .Type) {
            return null;
        }

        return @fieldParentPtr(Self, "obj", obj);
    }

    pub fn instanceEqlTypeUnion(a: *ObjTypeDef, b: *ObjTypeDef) bool {
        assert(a.def_type == .Object);
        assert(b.def_type == .Object);

        return a == b or (b.resolved_type.?.Object.super != null and instanceEqlTypeUnion(a, b.resolved_type.?.Object.super.?));
    }

    // Compare two type definitions
    pub fn eqlTypeUnion(a: TypeUnion, b: TypeUnion) bool {
        if (@as(Type, a) != @as(Type, b)) {
            return false;
        }

        return switch (a) {
            .Bool,
            .Number,
            .String,
            .Type,
            .Void,
            .Pattern,
            .UserData,
            => return true,

            .Fiber => {
                return a.Fiber.return_type.eql(b.Fiber.return_type) and a.Fiber.yield_type.eql(b.Fiber.yield_type);
            },

            .ObjectInstance => {
                return a.ObjectInstance.eql(b.ObjectInstance) or instanceEqlTypeUnion(a.ObjectInstance, b.ObjectInstance);
            },
            .EnumInstance => return a.EnumInstance.eql(b.EnumInstance),

            .Object, .Enum => false, // Those are never equal even if definition is the same

            .List => return a.List.item_type.eql(b.List.item_type),
            .Map => return a.Map.key_type.eql(b.Map.key_type) and a.Map.value_type.eql(b.Map.value_type),
            .Function => {
                // Compare return type
                if (!a.Function.return_type.eql(b.Function.return_type)) {
                    return false;
                }

                // Compare yield type
                if (!a.Function.yield_type.eql(b.Function.yield_type)) {
                    return false;
                }

                // Compare arity
                if (a.Function.parameters.count() != b.Function.parameters.count()) {
                    return false;
                }

                // Compare parameters (we ignore argument names and only compare types)
                const a_keys: []*ObjString = a.Function.parameters.keys();
                const b_keys: []*ObjString = b.Function.parameters.keys();

                if (a_keys.len != b_keys.len) {
                    return false;
                }

                for (a_keys) |_, index| {
                    if (!a.Function.parameters.get(a_keys[index]).?
                        .eql(b.Function.parameters.get(b_keys[index]).?))
                    {
                        return false;
                    }
                }

                return true;
            },

            .Placeholder => true, // TODO: should it be false?
        };
    }

    // Compare two type definitions
    pub fn eql(self: *Self, other: *Self) bool {
        // zig fmt: off
        const type_eql: bool = self.def_type == other.def_type
            and (
                (self.resolved_type == null and other.resolved_type == null)
                    or eqlTypeUnion(self.resolved_type.?, other.resolved_type.?)
            );

        // TODO: in an ideal world comparing pointers should be enough, but typedef can come from different type_registries and we can't reconcile them like we can with strings
        return self == other
            or (self.optional and other.def_type == .Void) // Void is equal to any optional type
            or (
                (type_eql or other.def_type == .Placeholder or self.def_type == .Placeholder)
                and (self.optional or !other.optional)
            );
        // zig fmt: on
    }
};

pub fn cloneObject(obj: *Obj, vm: *VM) !Value {
    switch (obj.obj_type) {
        .String,
        .Type,
        .UpValue,
        .Closure,
        .Function,
        .Object,
        .Enum,
        .EnumInstance,
        .Bound,
        .Native,
        .UserData,
        .Pattern,
        .Fiber,
        => return Value{ .Obj = obj },

        .List => {
            const list = ObjList.cast(obj).?;

            return (try vm.gc.allocateObject(
                ObjList,
                .{
                    .type_def = list.type_def,
                    .items = try list.items.clone(),
                    .methods = list.methods,
                },
            )).toValue();
        },

        .Map => {
            const map = ObjMap.cast(obj).?;

            return (try vm.gc.allocateObject(
                ObjMap,
                .{
                    .type_def = map.type_def,
                    .map = try map.map.clone(),
                    .methods = map.methods,
                },
            )).toValue();
        },

        // TODO
        .ObjectInstance => unreachable,
    }
}

pub fn objToString(writer: std.ArrayList(u8).Writer, obj: *Obj) (Allocator.Error || std.fmt.BufPrintError)!void {
    return switch (obj.obj_type) {
        .String => {
            const str = ObjString.cast(obj).?.string;

            try writer.print("{s}", .{str});
        },
        .Pattern => {
            const pattern = ObjPattern.cast(obj).?.source;

            try writer.print("{s}", .{pattern});
        },
        .Fiber => {
            const fiber = ObjFiber.cast(obj).?.fiber;

            try writer.print("fiber: 0x{x}", .{@ptrToInt(fiber)});
        },
        .Type => {
            const type_def: *ObjTypeDef = ObjTypeDef.cast(obj).?;

            try writer.print("type: 0x{x} `", .{
                @ptrToInt(type_def),
            });

            try type_def.toString(writer);

            try writer.writeAll("`");
        },
        .UpValue => {
            const upvalue: *ObjUpValue = ObjUpValue.cast(obj).?;

            try valueToString(writer, upvalue.closed orelse upvalue.location.*);
        },
        .Closure => try writer.print("closure: 0x{x} `{s}`", .{
            @ptrToInt(ObjClosure.cast(obj).?),
            ObjClosure.cast(obj).?.function.name.string,
        }),
        .Function => try writer.print("function: 0x{x} `{s}`", .{
            @ptrToInt(ObjFunction.cast(obj).?),
            ObjFunction.cast(obj).?.name.string,
        }),
        .ObjectInstance => {
            const instance = ObjObjectInstance.cast(obj).?;

            if (instance.object) |object| {
                try writer.print("object instance: 0x{x} `{s}`", .{
                    @ptrToInt(instance),
                    object.name.string,
                });
            } else {
                try writer.print("object instance: 0x{x} obj{{ ", .{
                    @ptrToInt(instance),
                });
                var it = instance.fields.iterator();
                while (it.next()) |kv| {
                    // This line is awesome
                    try instance.type_def.?.resolved_type.?.ObjectInstance.resolved_type.?.Object.fields.get(kv.key_ptr.*.string).?.toString(writer);
                    try writer.print(" {s}, ", .{kv.key_ptr.*.string});
                }
                try writer.writeAll("}");
            }
        },
        .Object => try writer.print("object: 0x{x} `{s}`", .{
            @ptrToInt(ObjObject.cast(obj).?),
            ObjObject.cast(obj).?.name.string,
        }),
        .List => {
            const list: *ObjList = ObjList.cast(obj).?;

            try writer.print("list: 0x{x} [", .{@ptrToInt(list)});

            std.debug.print("list @{} item type @{} {}\n", .{ @ptrToInt(list), @ptrToInt(list.type_def), list.type_def.def_type });
            try list.type_def.resolved_type.?.List.item_type.toString(writer);

            try writer.writeAll("]");
        },
        .Map => {
            const map: *ObjMap = ObjMap.cast(obj).?;

            try writer.print("map: 0x{x} {{", .{
                @ptrToInt(map),
            });

            try map.type_def.resolved_type.?.Map.key_type.toString(writer);

            try writer.writeAll(", ");

            try map.type_def.resolved_type.?.Map.value_type.toString(writer);

            try writer.writeAll("}");
        },
        .Enum => try writer.print("enum: 0x{x} `{s}`", .{
            @ptrToInt(ObjEnum.cast(obj).?),
            ObjEnum.cast(obj).?.name.string,
        }),
        .EnumInstance => enum_instance: {
            var instance: *ObjEnumInstance = ObjEnumInstance.cast(obj).?;
            var enum_: *ObjEnum = instance.enum_ref;

            break :enum_instance try writer.print("{s}.{s}", .{
                enum_.name.string,
                enum_.type_def.resolved_type.?.Enum.cases.items[instance.case],
            });
        },
        .Bound => {
            const bound: *ObjBoundMethod = ObjBoundMethod.cast(obj).?;

            if (bound.closure) |closure| {
                var closure_name: []const u8 = closure.function.name.string;
                try writer.writeAll("bound method: ");

                try valueToString(writer, bound.receiver);

                try writer.print(" to {s}", .{closure_name});
            } else {
                assert(bound.native != null);
                try writer.writeAll("bound method: ");

                try valueToString(writer, bound.receiver);

                try writer.print(" to native 0x{}", .{@ptrToInt(bound.native.?)});
            }
        },
        .Native => {
            var native: *ObjNative = ObjNative.cast(obj).?;

            try writer.print("native: 0x{x}", .{@ptrToInt(native)});
        },
        .UserData => {
            var userdata: *ObjUserData = ObjUserData.cast(obj).?;

            try writer.print("userdata: 0x{x}", .{@ptrToInt(userdata)});
        },
    };
}

pub const PlaceholderDef = struct {
    const Self = @This();

    // TODO: are relations enough and booleans useless?
    const PlaceholderRelation = enum {
        Call,
        Yield,
        Subscript,
        Key,
        SuperFieldAccess,
        FieldAccess,
        Assignment,
        Instance,
        Optional,
        Unwrap,
    };

    name: ?*ObjString = null,
    where: Token, // Where the placeholder was created
    // When accessing/calling/subscrit/assign a placeholder we produce another. We keep them linked so we
    // can trace back the root of the unknown type.
    parent: ?*ObjTypeDef = null,
    // What's the relation with the parent?
    parent_relation: ?PlaceholderRelation = null,
    // Children adds themselves here
    children: std.ArrayList(*ObjTypeDef),

    pub fn init(allocator: Allocator, where: Token) Self {
        return Self{
            .where = where.clone(),
            .children = std.ArrayList(*ObjTypeDef).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.children.deinit();
    }

    pub fn link(parent: *ObjTypeDef, child: *ObjTypeDef, relation: PlaceholderRelation) !void {
        assert(parent.def_type == .Placeholder);
        assert(child.def_type == .Placeholder);

        if (parent == child) {
            return;
        }

        if (child.resolved_type.?.Placeholder.parent != null) {
            if (Config.debug_placeholders) {
                std.debug.print(
                    ">>> Placeholder @{} ({s}) has already a {} relation with @{} ({s})\n",
                    .{
                        @ptrToInt(child),
                        if (child.resolved_type.?.Placeholder.name) |name| name.string else "unknown",
                        child.resolved_type.?.Placeholder.parent_relation.?,
                        @ptrToInt(child.resolved_type.?.Placeholder.parent.?),
                        if (child.resolved_type.?.Placeholder.parent.?.resolved_type.?.Placeholder.name) |name| name.string else "unknown",
                    },
                );
            }
            return;
        }

        child.resolved_type.?.Placeholder.parent = parent;
        try parent.resolved_type.?.Placeholder.children.append(child);
        child.resolved_type.?.Placeholder.parent_relation = relation;

        if (Config.debug_placeholders) {
            std.debug.print(
                "Linking @{} (root: {}) with @{} as {}\n",
                .{
                    @ptrToInt(parent),
                    parent.resolved_type.?.Placeholder.parent == null,
                    @ptrToInt(child),
                    relation,
                },
            );
        }
    }
};
