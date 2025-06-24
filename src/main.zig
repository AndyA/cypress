const std = @import("std");

fn isPath(str: []const u8) bool {
    return std.mem.startsWith(u8, str, "/");
}

fn isParam(str: []const u8) bool {
    return std.mem.startsWith(u8, str, ":");
}

fn pathIter(path: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, path[1..], '/');
}

fn pathCount(path: []const u8) usize {
    var count: usize = 0;
    var it = pathIter(path);
    while (it.next()) |_| {
        count += 1;
    }
    return count;
}

fn paramCount(path: []const u8) usize {
    var count: usize = 0;
    var it = pathIter(path);
    while (it.next()) |part| {
        if (isParam(part)) count += 1;
    }
    return count;
}

fn stripError(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |info| info.payload,
        else => T,
    };
}

const TypeParser = struct {
    fn @"[]u8"(src: []const u8) ![]const u8 {
        return src;
    }

    fn @"u32"(src: []const u8) !u32 {
        return std.fmt.parseInt(u32, src, 10);
    }
};

fn parseType(comptime type_name: []const u8) type {
    const method = @field(TypeParser, type_name);
    switch (@typeInfo(@TypeOf(method))) {
        .@"fn" => |f| {
            const rt = f.return_type orelse @compileError("Function must return a type");
            return stripError(rt);
        },
        else => @compileError("Expected a function type"),
    }
}

fn structField(comptime name: []const u8, comptime T: type) std.builtin.Type.StructField {
    var z_name: [name.len:0]u8 = @splat(' ');
    @memcpy(&z_name, name);
    return .{
        .name = &z_name,
        .type = T,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = 0,
    };
}

fn routeType(comptime route: []const u8) type {
    comptime {
        var it = pathIter(route);
        const placebo = structField("placebo", void);
        var fields: [paramCount(route)]std.builtin.Type.StructField = @splat(placebo);
        var index = 0;

        while (it.next()) |part| {
            if (!isParam(part)) continue;
            const tag = part[1..];
            const colon = std.mem.indexOfScalar(u8, tag, ':') orelse
                @compileError("Invalid path parameter format");
            fields[index] = structField(tag[0..colon], parseType(tag[colon + 1 ..]));
            index += 1;
        }

        return @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = &fields,
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_tuple = false,
            },
        });
    }
}

inline fn parseParam(comptime tag: []const u8) struct { []const u8, []const u8 } {
    comptime {
        const colon = std.mem.indexOfScalar(u8, tag, ':') orelse
            @compileError("No colon found in string");
        return .{ tag[0..colon], tag[colon + 1 ..] };
    }
}

fn makeMatcher(comptime route: []const u8) type {
    comptime {
        const ParamType = routeType(route);
        const route_len = pathCount(route);
        var r_parts: [route_len]struct { part: []const u8, is_parm: bool } = undefined;
        var it = pathIter(route);
        var index: usize = 0;

        while (it.next()) |part| {
            r_parts[index] = .{
                .part = part,
                .is_parm = isParam(part),
            };
            index += 1;
        }

        std.debug.assert(index == route_len);

        return struct {
            pub fn match(slot: *ParamType, path: []const u8) bool {
                var p_it = pathIter(path);
                inline for (r_parts) |r_part| {
                    const p_part = p_it.next() orelse return false;
                    if (r_part.is_parm) {
                        const field_name, const type_name = parseParam(r_part.part[1..]);
                        const parser = @field(TypeParser, type_name);
                        @field(slot, field_name) = parser(p_part) catch return false;
                    } else {
                        if (!std.mem.eql(u8, r_part.part, p_part)) return false;
                    }
                }
                return true;
            }
        };
    }
}

fn makeDespatcher(comptime router: anytype) type {
    comptime {
        switch (@typeInfo(@TypeOf(router))) {
            .@"struct" => |info| {
                var matchers: [info.decls.len]fn (path: []const u8) bool = undefined;
                var index: usize = 0;
                for (info.decls) |decl| {
                    const pattern = decl.name;
                    if (!isPath(pattern)) continue;
                    const m = makeMatcher(pattern);
                    const T = routeType(pattern);
                    const shim = struct {
                        pub fn match(path: []const u8) bool {
                            var slot: T = undefined;
                            if (m.match(&slot, path)) {
                                std.debug.print("Matched {s}\n", .{pattern});
                                const handler = @field(router, pattern);
                                handler(&router, slot);
                                return true;
                            }
                            return false;
                        }
                    };
                    matchers[index] = shim.match;
                    index += 1;
                }

                return struct {
                    pub fn despatch(path: []const u8) void {
                        inline for (matchers) |matcher| {
                            if (matcher(path))
                                return;
                        }
                        std.debug.print("No match found for {s}\n", .{path});
                    }
                };
            },
            else => @compileError("Expected a struct type"),
        }
    }
}

const Router = struct {
    const Self = @This();

    pub fn @"/index"(_: *Self) void {
        std.debug.print("Hello, world!\n", .{});
    }

    pub fn @"/user/:id:u32"(_: *Self, params: anytype) void {
        std.debug.print("user {d}\n", .{params.id});
    }

    // pub fn @"/tags/:tag:[]u8"(_: Self, params: struct { tag: []const u8 }) void {
    //     std.debug.print("tag {s}\n", .{params.tag});
    // }
};

pub fn main() !void {
    // const user = routeType("/user/:id:u32/name/:name:[]u8"){ .id = 999, .name = "John Doe" };
    // std.debug.print("User ID: {d}, Name: {s}\n", .{ user.id, user.name });

    // const page = routeType("/page/:page:u32/:para:u32"){ .page = 1, .para = 42 };
    // std.debug.print("Page: {d}, Para: {d}\n", .{ page.page, page.para });

    const route = "/user/:id:u32/name/:name:[]u8";
    const m = makeMatcher(route);
    var slot: routeType(route) = undefined;
    if (m.match(&slot, "/user/123/name/Andy")) {
        std.debug.print("Matched user ID: {d}, Name: {s}\n", .{ slot.id, slot.name });
    } else {
        std.debug.print("No match found\n", .{});
    }

    const router = Router{};
    const despatcher = makeDespatcher(router);
    despatcher.despatch("/index");
    despatcher.despatch("/user/42");
}
