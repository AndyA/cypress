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

inline fn parseParam(comptime tag: []const u8) struct { []const u8, []const u8 } {
    comptime {
        const colon = std.mem.indexOfScalar(u8, tag, ':') orelse
            @compileError("No colon found in string");
        return .{ tag[0..colon], tag[colon + 1 ..] };
    }
}

fn routeParamType(comptime route: []const u8) type {
    comptime {
        const params = paramCount(route);

        if (params == 0) return void;

        const placebo = structField("placebo", void);
        var fields: [params]std.builtin.Type.StructField = @splat(placebo);
        var index = 0;
        var it = pathIter(route);

        while (it.next()) |part| {
            if (!isParam(part)) continue;
            const field_name, const type_name = parseParam(part[1..]);
            fields[index] = structField(field_name, parseType(type_name));
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

fn makeMatcher(comptime route: []const u8) type {
    comptime {
        const ParamType = routeParamType(route);
        const route_len = pathCount(route);
        var route_parts: [route_len]struct { part: []const u8, is_parm: bool } = undefined;
        var it = pathIter(route);
        var index: usize = 0;

        while (it.next()) |part| {
            route_parts[index] = .{
                .part = part,
                .is_parm = isParam(part),
            };
            index += 1;
        }

        std.debug.assert(index == route_len);

        return struct {
            pub fn match(params: *ParamType, path: []const u8) !bool {
                var path_it = pathIter(path);
                inline for (route_parts) |route_part| {
                    const path_part = path_it.next() orelse return false;
                    if (route_part.is_parm) {
                        const field_name, const type_name = parseParam(route_part.part[1..]);
                        const parser = @field(TypeParser, type_name);
                        @field(params, field_name) = try parser(path_part);
                    } else {
                        if (!std.mem.eql(u8, route_part.part, path_part)) return false;
                    }
                }
                return true;
            }
        };
    }
}

fn makeDespatcher(comptime router: anytype) type {
    comptime {
        const RT = @TypeOf(router);
        switch (@typeInfo(RT)) {
            .@"struct" => |info| {
                var matchers: [info.decls.len]fn (path: []const u8) anyerror!bool = undefined;
                var index: usize = 0;

                for (info.decls) |decl| {
                    const pattern = decl.name;
                    if (!isPath(pattern)) continue;
                    const matcher = makeMatcher(pattern);
                    const ParamType = routeParamType(pattern);
                    const shim = struct {
                        pub fn match(path: []const u8) !bool {
                            var params: ParamType = undefined;
                            if (try matcher.match(&params, path)) {
                                const method = @field(RT, pattern);
                                if (ParamType == void) {
                                    try method(router);
                                } else {
                                    try method(router, params);
                                }
                                return true;
                            }
                            return false;
                        }
                    };
                    matchers[index] = shim.match;
                    index += 1;
                }

                if (index == 0)
                    @compileError("No valid routes found in the router");

                return struct {
                    pub fn despatch(path: []const u8) !bool {
                        inline for (matchers) |matcher| {
                            if (try matcher(path))
                                return true;
                        }
                        return false;
                    }
                };
            },
            else => @compileError("Expected a struct type"),
        }
    }
}

const TypeParser = struct {
    fn @"[]u8"(src: []const u8) ![]const u8 {
        return src;
    }

    fn @"u32"(src: []const u8) !u32 {
        return std.fmt.parseInt(u32, src, 10);
    }
};

const Router = struct {
    app: []const u8,
    const Self = @This();

    fn header(self: Self) void {
        std.debug.print("[{s}] ", .{self.app});
    }

    pub fn @"/index"(self: Self) !void {
        self.header();
        std.debug.print("Hello, world!\n", .{});
    }

    pub fn @"/user/:id:u32/name/:name:[]u8"(self: Self, params: anytype) !void {
        self.header();
        std.debug.print("user {d} {s}\n", .{ params.id, params.name });
    }

    pub fn @"/tags/:tag:[]u8"(self: Self, params: anytype) !void {
        self.header();
        std.debug.print("tag {s}\n", .{params.tag});
    }
};

const urls = [_][]const u8{
    "/index",
    "/user/42/name/Andy",
    "/user/999/name/Smoo",
    "/tags/fishing",
    "/foo/bar/123",
};

pub fn main() !void {
    const router = Router{ .app = "cypress" };
    const despatcher = makeDespatcher(router);
    for (urls) |url| {
        if (!try despatcher.despatch(url)) {
            std.debug.print("No route found for {s}\n", .{url});
        }
    }
}
