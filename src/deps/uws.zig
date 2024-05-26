pub const is_bindgen = @import("std").meta.globalOption("bindgen", bool) orelse false;
const bun = @import("root").bun;
const Api = bun.ApiSchema;
const std = @import("std");
const Environment = bun.Environment;
pub const u_int8_t = u8;
pub const u_int16_t = c_ushort;
pub const u_int32_t = c_uint;
pub const u_int64_t = c_ulonglong;
pub const LIBUS_LISTEN_DEFAULT: i32 = 0;
pub const LIBUS_LISTEN_EXCLUSIVE_PORT: i32 = 1;
pub const Socket = opaque {};
pub const ConnectingSocket = opaque {};
const debug = bun.Output.scoped(.uws, false);
const uws = @This();

const BoringSSL = bun.BoringSSL;
fn NativeSocketHandleType(comptime ssl: bool) type {
    if (ssl) {
        return BoringSSL.SSL;
    } else {
        return anyopaque;
    }
}
pub const InternalLoopData = extern struct {
    pub const us_internal_async = opaque {};

    sweep_timer: ?*Timer,
    wakeup_async: ?*us_internal_async,
    last_write_failed: i32,
    head: ?*SocketContext,
    iterator: ?*SocketContext,
    recv_buf: [*]u8,
    send_buf: [*]u8,
    ssl_data: ?*anyopaque,
    pre_cb: ?*fn (?*Loop) callconv(.C) void,
    post_cb: ?*fn (?*Loop) callconv(.C) void,
    closed_udp_head: ?*udp.Socket,
    closed_head: ?*Socket,
    low_prio_head: ?*Socket,
    low_prio_budget: i32,
    dns_ready_head: *ConnectingSocket,
    closed_connecting_head: *ConnectingSocket,
    mutex: u32, // this is actually a bun.Lock
    parent_ptr: ?*anyopaque,
    parent_tag: c_char,

    iteration_nr: c_longlong,

    pub fn recvSlice(this: *InternalLoopData) []u8 {
        return this.recv_buf[0..LIBUS_RECV_BUFFER_LENGTH];
    }

    pub fn setParentEventLoop(this: *InternalLoopData, parent: bun.JSC.EventLoopHandle) void {
        switch (parent) {
            .js => |ptr| {
                this.parent_tag = 1;
                this.parent_ptr = ptr;
            },
            .mini => |ptr| {
                this.parent_tag = 2;
                this.parent_ptr = ptr;
            },
        }
    }

    pub fn getParent(this: *InternalLoopData) bun.JSC.EventLoopHandle {
        const parent = this.parent_ptr orelse @panic("Parent loop not set - pointer is null");
        return switch (this.parent_tag) {
            0 => @panic("Parent loop not set - tag is zero"),
            1 => .{ .js = bun.cast(*bun.JSC.EventLoop, parent) },
            2 => .{ .mini = bun.cast(*bun.JSC.MiniEventLoop, parent) },
            else => @panic("Parent loop data corrupted - tag is invalid"),
        };
    }
};

pub const InternalSocket = union(enum) {
    done: *Socket,
    connecting: *ConnectingSocket,

    pub fn get(this: @This()) ?*Socket {
        return switch (this) {
            .done => this.done,
            .connecting => null,
        };
    }

    pub fn eq(this: @This(), other: @This()) bool {
        return switch (this) {
            .done => switch (other) {
                .done => this.done == other.done,
                .connecting => false,
            },
            .connecting => switch (other) {
                .done => false,
                .connecting => this.connecting == other.connecting,
            },
        };
    }
};

pub fn NewSocketHandler(comptime is_ssl: bool) type {
    return struct {
        const ssl_int: i32 = @intFromBool(is_ssl);
        socket: InternalSocket,
        const ThisSocket = @This();

        pub fn verifyError(this: ThisSocket) us_bun_verify_error_t {
            const socket = this.socket.get() orelse return std.mem.zeroes(us_bun_verify_error_t);
            const ssl_error: us_bun_verify_error_t = uws.us_socket_verify_error(comptime ssl_int, socket);
            return ssl_error;
        }

        pub fn isEstablished(this: ThisSocket) bool {
            const socket = this.socket.get() orelse return false;
            return us_socket_is_established(comptime ssl_int, socket) > 0;
        }

        pub fn timeout(this: ThisSocket, seconds: c_uint) void {
            switch (this.socket) {
                .done => |socket| us_socket_timeout(comptime ssl_int, socket, seconds),
                .connecting => |socket| us_connecting_socket_timeout(comptime ssl_int, socket, seconds),
            }
        }

        pub fn setTimeout(this: ThisSocket, seconds: c_uint) void {
            switch (this.socket) {
                .done => |socket| {
                    if (seconds > 240) {
                        us_socket_timeout(comptime ssl_int, socket, 0);
                        us_socket_long_timeout(comptime ssl_int, socket, seconds / 60);
                    } else {
                        us_socket_timeout(comptime ssl_int, socket, seconds);
                        us_socket_long_timeout(comptime ssl_int, socket, 0);
                    }
                },
                .connecting => |socket| {
                    if (seconds > 240) {
                        us_connecting_socket_timeout(comptime ssl_int, socket, 0);
                        us_connecting_socket_long_timeout(comptime ssl_int, socket, seconds / 60);
                    } else {
                        us_connecting_socket_timeout(comptime ssl_int, socket, seconds);
                        us_connecting_socket_long_timeout(comptime ssl_int, socket, 0);
                    }
                },
            }
        }

        pub fn setTimeoutMinutes(this: ThisSocket, minutes: c_uint) void {
            switch (this.socket) {
                .done => |socket| {
                    us_socket_timeout(comptime ssl_int, socket, 0);
                    us_socket_long_timeout(comptime ssl_int, socket, minutes);
                },
                .connecting => |socket| {
                    us_connecting_socket_timeout(comptime ssl_int, socket, 0);
                    us_connecting_socket_long_timeout(comptime ssl_int, socket, minutes);
                },
            }
        }

        pub fn startTLS(this: ThisSocket, is_client: bool) void {
            const socket = this.socket.get() orelse @panic("socket is not open");
            _ = us_socket_open(comptime ssl_int, socket, @intFromBool(is_client), null, 0);
        }

        pub fn ssl(this: ThisSocket) *BoringSSL.SSL {
            if (comptime is_ssl) {
                return @as(*BoringSSL.SSL, @ptrCast(this.getNativeHandle()));
            }
            @panic("socket is not a TLS socket");
        }

        // Note: this assumes that the socket is non-TLS and will be adopted and wrapped with a new TLS context
        // context ext will not be copied to the new context, new context will contain us_wrapped_socket_context_t on ext
        pub fn wrapTLS(
            this: ThisSocket,
            options: us_bun_socket_context_options_t,
            socket_ext_size: i32,
            comptime deref: bool,
            comptime ContextType: type,
            comptime Fields: anytype,
        ) ?NewSocketHandler(true) {
            const TLSSocket = NewSocketHandler(true);
            const SocketHandler = struct {
                const alignment = if (ContextType == anyopaque)
                    @sizeOf(usize)
                else
                    std.meta.alignment(ContextType);
                const deref_ = deref;
                const ValueType = if (deref) ContextType else *ContextType;
                fn getValue(socket: *Socket) ValueType {
                    if (comptime ContextType == anyopaque) {
                        return us_socket_ext(1, socket);
                    }

                    if (comptime deref_) {
                        return (TLSSocket.from(socket)).ext(ContextType).*;
                    }

                    return (TLSSocket.from(socket)).ext(ContextType);
                }

                pub fn on_open(socket: *Socket, is_client: i32, _: [*c]u8, _: i32) callconv(.C) ?*Socket {
                    if (comptime @hasDecl(Fields, "onCreate")) {
                        if (is_client == 0) {
                            Fields.onCreate(
                                TLSSocket.from(socket),
                            );
                        }
                    }
                    Fields.onOpen(
                        getValue(socket),
                        TLSSocket.from(socket),
                    );
                    return socket;
                }
                pub fn on_close(socket: *Socket, code: i32, reason: ?*anyopaque) callconv(.C) ?*Socket {
                    Fields.onClose(
                        getValue(socket),
                        TLSSocket.from(socket),
                        code,
                        reason,
                    );
                    return socket;
                }
                pub fn on_data(socket: *Socket, buf: ?[*]u8, len: i32) callconv(.C) ?*Socket {
                    Fields.onData(
                        getValue(socket),
                        TLSSocket.from(socket),
                        buf.?[0..@as(usize, @intCast(len))],
                    );
                    return socket;
                }
                pub fn on_writable(socket: *Socket) callconv(.C) ?*Socket {
                    Fields.onWritable(
                        getValue(socket),
                        TLSSocket.from(socket),
                    );
                    return socket;
                }
                pub fn on_timeout(socket: *Socket) callconv(.C) ?*Socket {
                    Fields.onTimeout(
                        getValue(socket),
                        TLSSocket.from(socket),
                    );
                    return socket;
                }
                pub fn on_long_timeout(socket: *Socket) callconv(.C) ?*Socket {
                    Fields.onLongTimeout(
                        getValue(socket),
                        TLSSocket.from(socket),
                    );
                    return socket;
                }
                pub fn on_connect_error(socket: *Socket, code: i32) callconv(.C) ?*Socket {
                    Fields.onConnectError(
                        TLSSocket.from(socket).ext(ContextType).*,
                        TLSSocket.from(socket),
                        code,
                    );
                    return socket;
                }
                pub fn on_connect_error_connecting_socket(socket: *ConnectingSocket, code: i32) callconv(.C) ?*ConnectingSocket {
                    Fields.onConnectError(
                        @as(*align(alignment) ContextType, @ptrCast(@alignCast(us_connecting_socket_ext(1, socket)))).*,
                        TLSSocket.fromConnecting(socket),
                        code,
                    );
                    return socket;
                }
                pub fn on_end(socket: *Socket) callconv(.C) ?*Socket {
                    Fields.onEnd(
                        getValue(socket),
                        TLSSocket.from(socket),
                    );
                    return socket;
                }
                pub fn on_handshake(socket: *Socket, success: i32, verify_error: us_bun_verify_error_t, _: ?*anyopaque) callconv(.C) void {
                    Fields.onHandshake(getValue(socket), TLSSocket.from(socket), success, verify_error);
                }
            };

            const events: us_socket_events_t = .{
                .on_open = SocketHandler.on_open,
                .on_close = SocketHandler.on_close,
                .on_data = SocketHandler.on_data,
                .on_writable = SocketHandler.on_writable,
                .on_timeout = SocketHandler.on_timeout,
                .on_connect_error = SocketHandler.on_connect_error,
                .on_connect_error_connecting_socket = SocketHandler.on_connect_error_connecting_socket,
                .on_end = SocketHandler.on_end,
                .on_handshake = SocketHandler.on_handshake,
                .on_long_timeout = SocketHandler.on_long_timeout,
            };

            const this_socket = this.socket.get() orelse @panic("socket is not open");

            const socket = us_socket_wrap_with_tls(ssl_int, this_socket, options, events, socket_ext_size) orelse return null;
            return NewSocketHandler(true).from(socket);
        }

        pub fn getNativeHandle(this: ThisSocket) ?*NativeSocketHandleType(is_ssl) {
            return @ptrCast(switch (this.socket) {
                .done => |socket| us_socket_get_native_handle(comptime ssl_int, socket),
                .connecting => |socket| us_connecting_socket_get_native_handle(comptime ssl_int, socket),
            } orelse return null);
        }

        pub inline fn fd(this: ThisSocket) bun.FileDescriptor {
            if (comptime is_ssl) {
                @compileError("SSL sockets do not have a file descriptor accessible this way");
            }
            const socket = this.socket.get() orelse return bun.invalid_fd;
            return if (comptime Environment.isWindows)
                // on windows uSockets exposes SOCKET
                bun.toFD(@as(bun.FDImpl.System, @ptrCast(us_socket_get_native_handle(0, socket))))
            else
                bun.toFD(@as(i32, @intCast(@intFromPtr(us_socket_get_native_handle(0, socket)))));
        }

        pub fn markNeedsMoreForSendfile(this: ThisSocket) void {
            if (comptime is_ssl) {
                @compileError("SSL sockets do not support sendfile yet");
            }
            const socket = this.socket.get() orelse return;
            us_socket_sendfile_needs_more(socket);
        }

        pub fn ext(this: ThisSocket, comptime ContextType: type) *ContextType {
            const alignment = if (ContextType == *anyopaque)
                @sizeOf(usize)
            else
                std.meta.alignment(ContextType);

            const ptr = switch (this.socket) {
                .done => |sock| us_socket_ext(comptime ssl_int, sock),
                .connecting => |sock| us_connecting_socket_ext(comptime ssl_int, sock),
            };

            return @as(*align(alignment) ContextType, @ptrCast(@alignCast(ptr)));
        }

        /// This can be null if the socket was closed.
        pub fn context(this: ThisSocket) ?*SocketContext {
            switch (this.socket) {
                .done => |socket| return us_socket_context(comptime ssl_int, socket),
                .connecting => |socket| return us_connecting_socket_context(comptime ssl_int, socket),
            }
        }

        pub fn flush(this: ThisSocket) void {
            const socket = this.socket.get() orelse return;
            return us_socket_flush(
                comptime ssl_int,
                socket,
            );
        }
        pub fn write(this: ThisSocket, data: []const u8, msg_more: bool) i32 {
            const socket = this.socket.get() orelse return 0;
            const result = us_socket_write(
                comptime ssl_int,
                socket,
                data.ptr,
                // truncate to 31 bits since sign bit exists
                @as(i32, @intCast(@as(u31, @truncate(data.len)))),
                @as(i32, @intFromBool(msg_more)),
            );

            if (comptime Environment.allow_assert) {
                debug("us_socket_write({*}, {d}) = {d}", .{ this.getNativeHandle(), data.len, result });
            }

            return result;
        }

        pub fn rawWrite(this: ThisSocket, data: []const u8, msg_more: bool) i32 {
            const socket = this.socket.get() orelse return 0;
            return us_socket_raw_write(
                comptime ssl_int,
                socket,
                data.ptr,
                // truncate to 31 bits since sign bit exists
                @as(i32, @intCast(@as(u31, @truncate(data.len)))),
                @as(i32, @intFromBool(msg_more)),
            );
        }
        pub fn shutdown(this: ThisSocket) void {
            // debug("us_socket_shutdown({d})", .{@intFromPtr(this.socket)});
            switch (this.socket) {
                .done => |socket| {
                    return us_socket_shutdown(
                        comptime ssl_int,
                        socket,
                    );
                },
                .connecting => |socket| {
                    return us_connecting_socket_shutdown(
                        comptime ssl_int,
                        socket,
                    );
                },
            }
        }

        pub fn shutdownRead(this: ThisSocket) void {
            switch (this.socket) {
                .done => |socket| {
                    // debug("us_socket_shutdown_read({d})", .{@intFromPtr(socket)});
                    return us_socket_shutdown_read(
                        comptime ssl_int,
                        socket,
                    );
                },
                .connecting => |socket| {
                    // debug("us_connecting_socket_shutdown_read({d})", .{@intFromPtr(socket)});
                    return us_connecting_socket_shutdown_read(
                        comptime ssl_int,
                        socket,
                    );
                },
            }
        }

        pub fn isShutdown(this: ThisSocket) bool {
            switch (this.socket) {
                .done => |socket| {
                    return us_socket_is_shut_down(
                        comptime ssl_int,
                        socket,
                    ) > 0;
                },
                .connecting => |socket| {
                    return us_connecting_socket_is_shut_down(
                        comptime ssl_int,
                        socket,
                    ) > 0;
                },
            }
        }

        pub fn isClosedOrHasError(this: ThisSocket) bool {
            if (this.isClosed() or this.isShutdown()) {
                return true;
            }

            return this.getError() != 0;
        }

        pub fn getError(this: ThisSocket) i32 {
            switch (this.socket) {
                .done => |socket| {
                    return us_socket_get_error(
                        comptime ssl_int,
                        socket,
                    );
                },
                .connecting => |socket| {
                    return us_connecting_socket_get_error(
                        comptime ssl_int,
                        socket,
                    );
                },
            }
        }

        pub fn isClosed(this: ThisSocket) bool {
            switch (this.socket) {
                .done => |socket| {
                    return us_socket_is_closed(
                        comptime ssl_int,
                        socket,
                    ) > 0;
                },
                .connecting => |socket| {
                    return us_connecting_socket_is_closed(
                        comptime ssl_int,
                        socket,
                    ) > 0;
                },
            }
        }

        pub fn close(this: ThisSocket, code: i32, reason: ?*anyopaque) void {
            // debug("us_socket_close({d})", .{@intFromPtr(this.socket)});
            switch (this.socket) {
                .done => |socket| {
                    _ = us_socket_close(
                        comptime ssl_int,
                        socket,
                        code,
                        reason,
                    );
                },
                .connecting => |socket| {
                    _ = us_connecting_socket_close(
                        comptime ssl_int,
                        socket,
                    );
                },
            }
        }
        pub fn localPort(this: ThisSocket) i32 {
            const socket = this.socket.get() orelse return 0;
            return us_socket_local_port(
                comptime ssl_int,
                socket,
            );
        }
        pub fn remoteAddress(this: ThisSocket, buf: [*]u8, length: *i32) void {
            const socket = this.socket.get() orelse {
                length.* = 0;
                return;
            };
            return us_socket_remote_address(
                comptime ssl_int,
                socket,
                buf,
                length,
            );
        }

        /// Get the local address of a socket in binary format.
        ///
        /// # Arguments
        /// - `buf`: A buffer to store the binary address data.
        ///
        /// # Returns
        /// This function returns a slice of the buffer on success, or null on failure.
        pub fn localAddressBinary(this: ThisSocket, buf: []u8) ?[]const u8 {
            const socket = this.socket.get() orelse return null;
            var length: i32 = @intCast(buf.len);
            us_socket_local_address(
                comptime ssl_int,
                socket,
                buf.ptr,
                &length,
            );

            if (length <= 0) {
                return null;
            }
            return buf[0..@intCast(length)];
        }

        /// Get the local address of a socket in text format.
        ///
        /// # Arguments
        /// - `buf`: A buffer to store the text address data.
        /// - `is_ipv6`: A pointer to a boolean representing whether the address is IPv6.
        ///
        /// # Returns
        /// This function returns a slice of the buffer on success, or null on failure.
        pub fn localAddressText(this: ThisSocket, buf: []u8, is_ipv6: *bool) ?[]const u8 {
            const addr_v4_len = @sizeOf(std.meta.FieldType(std.os.sockaddr.in, .addr));
            const addr_v6_len = @sizeOf(std.meta.FieldType(std.os.sockaddr.in6, .addr));

            var sa_buf: [addr_v6_len + 1]u8 = undefined;
            const binary = this.localAddressBinary(&sa_buf) orelse return null;
            const addr_len: usize = binary.len;
            sa_buf[addr_len] = 0;

            var ret: ?[*:0]const u8 = null;
            if (addr_len == addr_v4_len) {
                ret = bun.c_ares.ares_inet_ntop(std.os.AF.INET, &sa_buf, buf.ptr, @as(u32, @intCast(buf.len)));
                is_ipv6.* = false;
            } else if (addr_len == addr_v6_len) {
                ret = bun.c_ares.ares_inet_ntop(std.os.AF.INET6, &sa_buf, buf.ptr, @as(u32, @intCast(buf.len)));
                is_ipv6.* = true;
            }

            if (ret) |_| {
                const length: usize = @intCast(bun.len(bun.cast([*:0]u8, buf)));
                return buf[0..length];
            }
            return null;
        }

        pub fn connect(
            host: []const u8,
            port: i32,
            socket_ctx: *SocketContext,
            comptime Context: type,
            ctx: Context,
            comptime socket_field_name: []const u8,
        ) ?*Context {
            debug("connect({s}, {d})", .{ host, port });

            var stack_fallback = std.heap.stackFallback(1024, bun.default_allocator);
            var allocator = stack_fallback.get();

            // remove brackets from IPv6 addresses, as getaddrinfo doesn't understand them
            const clean_host = if (host.len > 1 and host[0] == '[' and host[host.len - 1] == ']')
                host[1 .. host.len - 1]
            else
                host;

            const host_ = allocator.dupeZ(u8, clean_host) catch bun.outOfMemory();
            defer allocator.free(host);

            var did_dns_resolve: i32 = 0;
            const socket = us_socket_context_connect(comptime ssl_int, socket_ctx, host_, port, 0, @sizeOf(Context), &did_dns_resolve) orelse return null;
            const socket_ = if (did_dns_resolve == 1)
                ThisSocket{
                    .socket = .{ .done = @ptrCast(socket) },
                }
            else
                ThisSocket{
                    .socket = .{ .connecting = @ptrCast(socket) },
                };

            var holder = socket_.ext(Context);
            holder.* = ctx;
            @field(holder, socket_field_name) = socket_;
            return holder;
        }

        pub fn connectPtr(
            host: []const u8,
            port: i32,
            socket_ctx: *SocketContext,
            comptime Context: type,
            ctx: *Context,
            comptime socket_field_name: []const u8,
        ) !*Context {
            const this_socket = try connectAnon(host, port, socket_ctx, ctx);
            @field(ctx, socket_field_name) = this_socket;
            return ctx;
        }

        pub fn fromFd(
            ctx: *SocketContext,
            handle: bun.FileDescriptor,
            comptime This: type,
            this: *This,
            comptime socket_field_name: ?[]const u8,
        ) ?ThisSocket {
            const socket_ = ThisSocket{ .socket = .{ .done = us_socket_from_fd(ctx, @sizeOf(*anyopaque), bun.socketcast(handle)) orelse return null } };

            const holder = socket_.ext(*anyopaque);
            holder.* = this;

            if (comptime socket_field_name) |field| {
                @field(this, field) = socket_;
            }

            return socket_;
        }

        pub fn connectUnixPtr(
            path: []const u8,
            socket_ctx: *SocketContext,
            comptime Context: type,
            ctx: *Context,
            comptime socket_field_name: []const u8,
        ) !*Context {
            const this_socket = try connectUnixAnon(path, socket_ctx, ctx);
            @field(ctx, socket_field_name) = this_socket;
            return ctx;
        }

        pub fn connectUnixAnon(
            path: []const u8,
            socket_ctx: *SocketContext,
            ctx: *anyopaque,
        ) !ThisSocket {
            debug("connect(unix:{s})", .{path});
            var stack_fallback = std.heap.stackFallback(1024, bun.default_allocator);
            var allocator = stack_fallback.get();
            const path_ = allocator.dupeZ(u8, path) catch bun.outOfMemory();
            defer allocator.free(path_);

            const socket = us_socket_context_connect_unix(comptime ssl_int, socket_ctx, path_, path_.len, 0, 8) orelse
                return error.FailedToOpenSocket;

            const socket_ = ThisSocket{ .socket = .{ .done = socket } };
            const holder = socket_.ext(*anyopaque);
            holder.* = ctx;
            return socket_;
        }

        pub fn connectAnon(
            raw_host: []const u8,
            port: i32,
            socket_ctx: *SocketContext,
            ptr: *anyopaque,
        ) !ThisSocket {
            debug("connect({s}, {d})", .{ raw_host, port });
            var stack_fallback = std.heap.stackFallback(1024, bun.default_allocator);
            var allocator = stack_fallback.get();

            // remove brackets from IPv6 addresses, as getaddrinfo doesn't understand them
            const clean_host = if (raw_host.len > 1 and raw_host[0] == '[' and raw_host[raw_host.len - 1] == ']')
                raw_host[1 .. raw_host.len - 1]
            else
                raw_host;

            const host = allocator.dupeZ(u8, clean_host) catch bun.outOfMemory();
            defer allocator.free(host);

            var did_dns_resolve: i32 = 0;
            const socket_ptr = us_socket_context_connect(
                comptime ssl_int,
                socket_ctx,
                host.ptr,
                port,
                0,
                @sizeOf(*anyopaque),
                &did_dns_resolve,
            ) orelse return error.FailedToOpenSocket;
            const socket = if (did_dns_resolve == 1)
                ThisSocket{
                    .socket = .{ .done = @ptrCast(socket_ptr) },
                }
            else
                ThisSocket{
                    .socket = .{ .connecting = @ptrCast(socket_ptr) },
                };

            const holder = socket.ext(*anyopaque);
            holder.* = ptr;
            return socket;
        }

        pub fn unsafeConfigure(
            ctx: *SocketContext,
            comptime ssl_type: bool,
            comptime deref: bool,
            comptime ContextType: type,
            comptime Fields: anytype,
        ) void {
            const SocketHandlerType = NewSocketHandler(ssl_type);
            const ssl_type_int: i32 = @intFromBool(ssl_type);
            const Type = comptime if (@TypeOf(Fields) != type) @TypeOf(Fields) else Fields;

            const SocketHandler = struct {
                const alignment = if (ContextType == anyopaque)
                    @sizeOf(usize)
                else
                    std.meta.alignment(ContextType);
                const deref_ = deref;
                const ValueType = if (deref) ContextType else *ContextType;
                fn getValue(socket: *Socket) ValueType {
                    if (comptime ContextType == anyopaque) {
                        return us_socket_ext(ssl_type_int, socket).?;
                    }

                    if (comptime deref_) {
                        return (SocketHandlerType.from(socket)).ext(ContextType).*;
                    }

                    return (SocketHandlerType.from(socket)).ext(ContextType);
                }

                pub fn on_open(socket: *Socket, is_client: i32, _: [*c]u8, _: i32) callconv(.C) ?*Socket {
                    if (comptime @hasDecl(Fields, "onCreate")) {
                        if (is_client == 0) {
                            Fields.onCreate(
                                SocketHandlerType.from(socket),
                            );
                        }
                    }
                    Fields.onOpen(
                        getValue(socket),
                        SocketHandlerType.from(socket),
                    );
                    return socket;
                }
                pub fn on_close(socket: *Socket, code: i32, reason: ?*anyopaque) callconv(.C) ?*Socket {
                    Fields.onClose(
                        getValue(socket),
                        SocketHandlerType.from(socket),
                        code,
                        reason,
                    );
                    return socket;
                }
                pub fn on_data(socket: *Socket, buf: ?[*]u8, len: i32) callconv(.C) ?*Socket {
                    Fields.onData(
                        getValue(socket),
                        SocketHandlerType.from(socket),
                        buf.?[0..@as(usize, @intCast(len))],
                    );
                    return socket;
                }
                pub fn on_writable(socket: *Socket) callconv(.C) ?*Socket {
                    Fields.onWritable(
                        getValue(socket),
                        SocketHandlerType.from(socket),
                    );
                    return socket;
                }
                pub fn on_timeout(socket: *Socket) callconv(.C) ?*Socket {
                    Fields.onTimeout(
                        getValue(socket),
                        SocketHandlerType.from(socket),
                    );
                    return socket;
                }
                pub fn on_connect_error_connecting_socket(socket: *ConnectingSocket, code: i32) callconv(.C) ?*ConnectingSocket {
                    const val = if (comptime ContextType == anyopaque)
                        us_connecting_socket_ext(comptime ssl_int, socket)
                    else if (comptime deref_)
                        SocketHandlerType.fromConnecting(socket).ext(ContextType).*
                    else
                        SocketHandlerType.fromConnecting(socket).ext(ContextType);
                    Fields.onConnectError(
                        val,
                        SocketHandlerType.fromConnecting(socket),
                        code,
                    );
                    return socket;
                }
                pub fn on_connect_error(socket: *Socket, code: i32) callconv(.C) ?*Socket {
                    const val = if (comptime ContextType == anyopaque)
                        us_socket_ext(comptime ssl_int, socket)
                    else if (comptime deref_)
                        SocketHandlerType.from(socket).ext(ContextType).*
                    else
                        SocketHandlerType.from(socket).ext(ContextType);
                    Fields.onConnectError(
                        val,
                        SocketHandlerType.from(socket),
                        code,
                    );
                    return socket;
                }
                pub fn on_end(socket: *Socket) callconv(.C) ?*Socket {
                    Fields.onEnd(
                        getValue(socket),
                        SocketHandlerType.from(socket),
                    );
                    return socket;
                }
                pub fn on_handshake(socket: *Socket, success: i32, verify_error: us_bun_verify_error_t, _: ?*anyopaque) callconv(.C) void {
                    Fields.onHandshake(getValue(socket), SocketHandlerType.from(socket), success, verify_error);
                }
            };

            if (comptime @hasDecl(Type, "onOpen") and @typeInfo(@TypeOf(Type.onOpen)) != .Null)
                us_socket_context_on_open(ssl_int, ctx, SocketHandler.on_open);
            if (comptime @hasDecl(Type, "onClose") and @typeInfo(@TypeOf(Type.onClose)) != .Null)
                us_socket_context_on_close(ssl_int, ctx, SocketHandler.on_close);
            if (comptime @hasDecl(Type, "onData") and @typeInfo(@TypeOf(Type.onData)) != .Null)
                us_socket_context_on_data(ssl_int, ctx, SocketHandler.on_data);
            if (comptime @hasDecl(Type, "onWritable") and @typeInfo(@TypeOf(Type.onWritable)) != .Null)
                us_socket_context_on_writable(ssl_int, ctx, SocketHandler.on_writable);
            if (comptime @hasDecl(Type, "onTimeout") and @typeInfo(@TypeOf(Type.onTimeout)) != .Null)
                us_socket_context_on_timeout(ssl_int, ctx, SocketHandler.on_timeout);
            if (comptime @hasDecl(Type, "onConnectError") and @typeInfo(@TypeOf(Type.onConnectError)) != .Null) {
                us_socket_context_on_socket_connect_error(ssl_int, ctx, SocketHandler.on_connect_error);
                us_socket_context_on_connect_error(ssl_int, ctx, SocketHandler.on_connect_error_connecting_socket);
            }
            if (comptime @hasDecl(Type, "onEnd") and @typeInfo(@TypeOf(Type.onEnd)) != .Null)
                us_socket_context_on_end(ssl_int, ctx, SocketHandler.on_end);
            if (comptime @hasDecl(Type, "onHandshake") and @typeInfo(@TypeOf(Type.onHandshake)) != .Null)
                us_socket_context_on_handshake(ssl_int, ctx, SocketHandler.on_handshake, null);
        }

        pub fn configure(
            ctx: *SocketContext,
            comptime deref: bool,
            comptime ContextType: type,
            comptime Fields: anytype,
        ) void {
            const Type = comptime if (@TypeOf(Fields) != type) @TypeOf(Fields) else Fields;

            const SocketHandler = struct {
                const alignment = if (ContextType == anyopaque)
                    @sizeOf(usize)
                else
                    std.meta.alignment(ContextType);
                const deref_ = deref;
                const ValueType = if (deref) ContextType else *ContextType;
                fn getValue(socket: *Socket) ValueType {
                    if (comptime ContextType == anyopaque) {
                        return us_socket_ext(comptime ssl_int, socket);
                    }

                    if (comptime deref_) {
                        return (ThisSocket.from(socket)).ext(ContextType).*;
                    }

                    return (ThisSocket.from(socket)).ext(ContextType);
                }

                pub fn on_open(socket: *Socket, is_client: i32, _: [*c]u8, _: i32) callconv(.C) ?*Socket {
                    if (comptime @hasDecl(Fields, "onCreate")) {
                        if (is_client == 0) {
                            Fields.onCreate(
                                ThisSocket.from(socket),
                            );
                        }
                    }
                    Fields.onOpen(
                        getValue(socket),
                        ThisSocket.from(socket),
                    );
                    return socket;
                }
                pub fn on_close(socket: *Socket, code: i32, reason: ?*anyopaque) callconv(.C) ?*Socket {
                    Fields.onClose(
                        getValue(socket),
                        ThisSocket.from(socket),
                        code,
                        reason,
                    );
                    return socket;
                }
                pub fn on_data(socket: *Socket, buf: ?[*]u8, len: i32) callconv(.C) ?*Socket {
                    Fields.onData(
                        getValue(socket),
                        ThisSocket.from(socket),
                        buf.?[0..@as(usize, @intCast(len))],
                    );
                    return socket;
                }
                pub fn on_writable(socket: *Socket) callconv(.C) ?*Socket {
                    Fields.onWritable(
                        getValue(socket),
                        ThisSocket.from(socket),
                    );
                    return socket;
                }
                pub fn on_timeout(socket: *Socket) callconv(.C) ?*Socket {
                    Fields.onTimeout(
                        getValue(socket),
                        ThisSocket.from(socket),
                    );
                    return socket;
                }
                pub fn on_long_timeout(socket: *Socket) callconv(.C) ?*Socket {
                    Fields.onLongTimeout(
                        getValue(socket),
                        ThisSocket.from(socket),
                    );
                    return socket;
                }
                pub fn on_connect_error_connecting_socket(socket: *ConnectingSocket, code: i32) callconv(.C) ?*ConnectingSocket {
                    const val = if (comptime ContextType == anyopaque)
                        us_connecting_socket_ext(comptime ssl_int, socket)
                    else if (comptime deref_)
                        ThisSocket.fromConnecting(socket).ext(ContextType).*
                    else
                        ThisSocket.fromConnecting(socket).ext(ContextType);
                    Fields.onConnectError(
                        val,
                        ThisSocket.fromConnecting(socket),
                        code,
                    );
                    return socket;
                }
                pub fn on_connect_error(socket: *Socket, code: i32) callconv(.C) ?*Socket {
                    const val = if (comptime ContextType == anyopaque)
                        us_socket_ext(comptime ssl_int, socket)
                    else if (comptime deref_)
                        ThisSocket.from(socket).ext(ContextType).*
                    else
                        ThisSocket.from(socket).ext(ContextType);

                    // We close immediately in this case
                    // uSockets doesn't know if this is a TLS socket or not.
                    // So we have to do that logic in here.
                    ThisSocket.from(socket).close(0, null);

                    Fields.onConnectError(
                        val,
                        ThisSocket.from(socket),
                        code,
                    );
                    return socket;
                }
                pub fn on_end(socket: *Socket) callconv(.C) ?*Socket {
                    Fields.onEnd(
                        getValue(socket),
                        ThisSocket.from(socket),
                    );
                    return socket;
                }
                pub fn on_handshake(socket: *Socket, success: i32, verify_error: us_bun_verify_error_t, _: ?*anyopaque) callconv(.C) void {
                    Fields.onHandshake(getValue(socket), ThisSocket.from(socket), success, verify_error);
                }
            };

            if (comptime @hasDecl(Type, "onOpen") and @typeInfo(@TypeOf(Type.onOpen)) != .Null)
                us_socket_context_on_open(ssl_int, ctx, SocketHandler.on_open);
            if (comptime @hasDecl(Type, "onClose") and @typeInfo(@TypeOf(Type.onClose)) != .Null)
                us_socket_context_on_close(ssl_int, ctx, SocketHandler.on_close);
            if (comptime @hasDecl(Type, "onData") and @typeInfo(@TypeOf(Type.onData)) != .Null)
                us_socket_context_on_data(ssl_int, ctx, SocketHandler.on_data);
            if (comptime @hasDecl(Type, "onWritable") and @typeInfo(@TypeOf(Type.onWritable)) != .Null)
                us_socket_context_on_writable(ssl_int, ctx, SocketHandler.on_writable);
            if (comptime @hasDecl(Type, "onTimeout") and @typeInfo(@TypeOf(Type.onTimeout)) != .Null)
                us_socket_context_on_timeout(ssl_int, ctx, SocketHandler.on_timeout);
            if (comptime @hasDecl(Type, "onConnectError") and @typeInfo(@TypeOf(Type.onConnectError)) != .Null) {
                us_socket_context_on_socket_connect_error(ssl_int, ctx, SocketHandler.on_connect_error);
                us_socket_context_on_connect_error(ssl_int, ctx, SocketHandler.on_connect_error_connecting_socket);
            }
            if (comptime @hasDecl(Type, "onEnd") and @typeInfo(@TypeOf(Type.onEnd)) != .Null)
                us_socket_context_on_end(ssl_int, ctx, SocketHandler.on_end);
            if (comptime @hasDecl(Type, "onHandshake") and @typeInfo(@TypeOf(Type.onHandshake)) != .Null)
                us_socket_context_on_handshake(ssl_int, ctx, SocketHandler.on_handshake, null);
            if (comptime @hasDecl(Type, "onLongTimeout") and @typeInfo(@TypeOf(Type.onLongTimeout)) != .Null)
                us_socket_context_on_long_timeout(ssl_int, ctx, SocketHandler.on_long_timeout);
        }

        pub fn from(socket: *Socket) ThisSocket {
            return ThisSocket{ .socket = .{ .done = socket } };
        }

        pub fn fromConnecting(connecting: *ConnectingSocket) ThisSocket {
            return ThisSocket{ .socket = .{ .connecting = connecting } };
        }

        pub fn fromAny(socket: InternalSocket) ThisSocket {
            return ThisSocket{ .socket = socket };
        }

        pub fn adoptPtr(
            socket: *Socket,
            socket_ctx: *SocketContext,
            comptime Context: type,
            comptime socket_field_name: []const u8,
            ctx: *Context,
        ) bool {
            // ext_size of -1 means we want to keep the current ext size
            // in particular, we don't want to allocate a new socket
            const new_socket = us_socket_context_adopt_socket(comptime ssl_int, socket_ctx, socket, -1) orelse return false;
            bun.assert(new_socket == socket);
            var adopted = ThisSocket.from(new_socket);
            const holder = adopted.ext(*anyopaque);
            holder.* = ctx;
            @field(ctx, socket_field_name) = adopted;
            return true;
        }
    };
}

pub const SocketTCP = NewSocketHandler(false);
pub const SocketTLS = NewSocketHandler(true);

pub const Timer = opaque {
    pub fn create(loop: *Loop, ptr: anytype) *Timer {
        const Type = @TypeOf(ptr);

        // never fallthrough poll
        // the problem is uSockets hardcodes it on the other end
        // so we can never free non-fallthrough polls
        return us_create_timer(loop, 0, @sizeOf(Type));
    }

    pub fn createFallthrough(loop: *Loop, ptr: anytype) *Timer {
        const Type = @TypeOf(ptr);

        // never fallthrough poll
        // the problem is uSockets hardcodes it on the other end
        // so we can never free non-fallthrough polls
        return us_create_timer(loop, 1, @sizeOf(Type));
    }

    pub fn set(this: *Timer, ptr: anytype, cb: ?*const fn (*Timer) callconv(.C) void, ms: i32, repeat_ms: i32) void {
        us_timer_set(this, cb, ms, repeat_ms);
        const value_ptr = us_timer_ext(this);
        @setRuntimeSafety(false);
        @as(*@TypeOf(ptr), @ptrCast(@alignCast(value_ptr))).* = ptr;
    }

    pub fn deinit(this: *Timer, comptime fallthrough: bool) void {
        debug("Timer.deinit()", .{});
        us_timer_close(this, @intFromBool(fallthrough));
    }

    pub fn ext(this: *Timer, comptime Type: type) ?*Type {
        return @as(*Type, @ptrCast(@alignCast(us_timer_ext(this).*.?)));
    }

    pub fn as(this: *Timer, comptime Type: type) Type {
        @setRuntimeSafety(false);
        return @as(*?Type, @ptrCast(@alignCast(us_timer_ext(this)))).*.?;
    }
};

pub const SocketContext = opaque {
    pub fn getNativeHandle(this: *SocketContext, comptime ssl: bool) *anyopaque {
        return us_socket_context_get_native_handle(comptime @as(i32, @intFromBool(ssl)), this).?;
    }

    fn _deinit_ssl(this: *SocketContext) void {
        us_socket_context_free(@as(i32, 1), this);
    }

    fn _deinit(this: *SocketContext) void {
        us_socket_context_free(@as(i32, 0), this);
    }

    pub fn cleanCallbacks(ctx: *SocketContext, is_ssl: bool) void {
        const ssl_int: i32 = @intFromBool(is_ssl);
        // replace callbacks with dummy ones
        const DummyCallbacks = struct {
            fn open(socket: *Socket, _: i32, _: [*c]u8, _: i32) callconv(.C) ?*Socket {
                return socket;
            }
            fn close(socket: *Socket, _: i32, _: ?*anyopaque) callconv(.C) ?*Socket {
                return socket;
            }
            fn data(socket: *Socket, _: [*c]u8, _: i32) callconv(.C) ?*Socket {
                return socket;
            }
            fn writable(socket: *Socket) callconv(.C) ?*Socket {
                return socket;
            }
            fn timeout(socket: *Socket) callconv(.C) ?*Socket {
                return socket;
            }
            fn connect_error(socket: *ConnectingSocket, _: i32) callconv(.C) ?*ConnectingSocket {
                return socket;
            }
            fn socket_connect_error(socket: *Socket, _: i32) callconv(.C) ?*Socket {
                return socket;
            }
            fn end(socket: *Socket) callconv(.C) ?*Socket {
                return socket;
            }
            fn handshake(_: *Socket, _: i32, _: us_bun_verify_error_t, _: ?*anyopaque) callconv(.C) void {}
            fn long_timeout(socket: *Socket) callconv(.C) ?*Socket {
                return socket;
            }
        };
        us_socket_context_on_open(ssl_int, ctx, DummyCallbacks.open);
        us_socket_context_on_close(ssl_int, ctx, DummyCallbacks.close);
        us_socket_context_on_data(ssl_int, ctx, DummyCallbacks.data);
        us_socket_context_on_writable(ssl_int, ctx, DummyCallbacks.writable);
        us_socket_context_on_timeout(ssl_int, ctx, DummyCallbacks.timeout);
        us_socket_context_on_connect_error(ssl_int, ctx, DummyCallbacks.connect_error);
        us_socket_context_on_socket_connect_error(ssl_int, ctx, DummyCallbacks.socket_connect_error);
        us_socket_context_on_end(ssl_int, ctx, DummyCallbacks.end);
        us_socket_context_on_handshake(ssl_int, ctx, DummyCallbacks.handshake, null);
        us_socket_context_on_long_timeout(ssl_int, ctx, DummyCallbacks.long_timeout);
    }

    fn getLoop(this: *SocketContext, ssl: bool) ?*Loop {
        if (ssl) {
            return us_socket_context_loop(@as(i32, 1), this);
        }
        return us_socket_context_loop(@as(i32, 0), this);
    }

    /// closes and deinit the SocketContexts
    pub fn deinit(this: *SocketContext, ssl: bool) void {
        // we clean the callbacks to avoid UAF because we are deiniting
        this.cleanCallbacks(ssl);
        this.close(ssl);
        //always deinit in next iteration
        if (ssl) {
            Loop.get().nextTick(*SocketContext, this, SocketContext._deinit_ssl);
        } else {
            Loop.get().nextTick(*SocketContext, this, SocketContext._deinit);
        }
    }

    pub fn close(this: *SocketContext, ssl: bool) void {
        debug("us_socket_context_close({d})", .{@intFromPtr(this)});
        us_socket_context_close(@as(i32, @intFromBool(ssl)), this);
    }

    pub fn ext(this: *SocketContext, ssl: bool, comptime ContextType: type) ?*ContextType {
        const alignment = if (ContextType == *anyopaque)
            @sizeOf(usize)
        else
            std.meta.alignment(ContextType);

        const ptr = us_socket_context_ext(
            @intFromBool(ssl),
            this,
        ) orelse return null;

        return @as(*align(alignment) ContextType, @ptrCast(@alignCast(ptr)));
    }
};
pub const PosixLoop = extern struct {
    internal_loop_data: InternalLoopData align(16),

    /// Number of non-fallthrough polls in the loop
    num_polls: i32,

    /// Number of ready polls this iteration
    num_ready_polls: i32,

    /// Current index in list of ready polls
    current_ready_poll: i32,

    /// Loop's own file descriptor
    fd: i32,

    /// Number of polls owned by Bun
    active: u32 = 0,

    /// The list of ready polls
    ready_polls: [1024]EventType align(16),

    const EventType = switch (Environment.os) {
        .linux => std.os.linux.epoll_event,
        .mac => std.os.system.kevent64_s,
        // TODO:
        .windows => *anyopaque,
        else => @compileError("Unsupported OS"),
    };

    const log = bun.Output.scoped(.Loop, false);

    pub fn iterationNumber(this: *const PosixLoop) c_longlong {
        return this.internal_loop_data.iteration_nr;
    }

    pub fn inc(this: *PosixLoop) void {
        this.num_polls += 1;
    }

    pub fn dec(this: *PosixLoop) void {
        this.num_polls -= 1;
    }

    pub fn ref(this: *PosixLoop) void {
        log("ref", .{});
        this.num_polls += 1;
        this.active += 1;
    }

    pub fn unref(this: *PosixLoop) void {
        log("unref", .{});
        this.num_polls -= 1;
        this.active -|= 1;
    }

    pub fn isActive(this: *const Loop) bool {
        return this.active > 0;
    }

    // This exists as a method so that we can stick a debugger in here
    pub fn addActive(this: *PosixLoop, value: u32) void {
        log("add {d} + {d} = {d}", .{ this.active, value, this.active +| value });
        this.active +|= value;
    }

    // This exists as a method so that we can stick a debugger in here
    pub fn subActive(this: *PosixLoop, value: u32) void {
        log("sub {d} - {d} = {d}", .{ this.active, value, this.active -| value });
        this.active -|= value;
    }

    pub fn unrefCount(this: *PosixLoop, count: i32) void {
        log("unref x {d}", .{count});
        this.num_polls -|= count;
        this.active -|= @as(u32, @intCast(count));
    }

    pub fn get() *Loop {
        return uws_get_loop();
    }

    pub fn create(comptime Handler: anytype) *Loop {
        return us_create_loop(
            null,
            Handler.wakeup,
            if (@hasDecl(Handler, "pre")) Handler.pre else null,
            if (@hasDecl(Handler, "post")) Handler.post else null,
            0,
        ).?;
    }

    pub fn wakeup(this: *PosixLoop) void {
        return us_wakeup_loop(this);
    }

    pub const wake = wakeup;

    pub fn tick(this: *PosixLoop) void {
        us_loop_run_bun_tick(this, 0);
    }

    pub fn tickWithoutIdle(this: *PosixLoop) void {
        us_loop_run_bun_tick(this, std.math.maxInt(i64));
    }

    pub fn tickWithTimeout(this: *PosixLoop, timeoutMs: i64) void {
        us_loop_run_bun_tick(this, timeoutMs);
    }

    extern fn us_loop_run_bun_tick(loop: ?*Loop, timouetMs: i64) void;

    pub fn nextTick(this: *PosixLoop, comptime UserType: type, user_data: UserType, comptime deferCallback: fn (ctx: UserType) void) void {
        const Handler = struct {
            pub fn callback(data: *anyopaque) callconv(.C) void {
                deferCallback(@as(UserType, @ptrCast(@alignCast(data))));
            }
        };
        uws_loop_defer(this, user_data, Handler.callback);
    }

    fn NewHandler(comptime UserType: type, comptime callback_fn: fn (UserType) void) type {
        return struct {
            loop: *Loop,
            pub fn removePost(handler: @This()) void {
                return uws_loop_removePostHandler(handler.loop, callback);
            }
            pub fn removePre(handler: @This()) void {
                return uws_loop_removePostHandler(handler.loop, callback);
            }
            pub fn callback(data: *anyopaque, _: *Loop) callconv(.C) void {
                callback_fn(@as(UserType, @ptrCast(@alignCast(data))));
            }
        };
    }

    pub fn addPostHandler(this: *PosixLoop, comptime UserType: type, ctx: UserType, comptime callback: fn (UserType) void) NewHandler(UserType, callback) {
        const Handler = NewHandler(UserType, callback);

        uws_loop_addPostHandler(this, ctx, Handler.callback);
        return Handler{
            .loop = this,
        };
    }

    pub fn addPreHandler(this: *PosixLoop, comptime UserType: type, ctx: UserType, comptime callback: fn (UserType) void) NewHandler(UserType, callback) {
        const Handler = NewHandler(UserType, callback);

        uws_loop_addPreHandler(this, ctx, Handler.callback);
        return Handler{
            .loop = this,
        };
    }

    pub fn run(this: *PosixLoop) void {
        us_loop_run(this);
    }
};

extern fn uws_loop_defer(loop: *Loop, ctx: *anyopaque, cb: *const (fn (ctx: *anyopaque) callconv(.C) void)) void;

extern fn us_create_timer(loop: ?*Loop, fallthrough: i32, ext_size: c_uint) *Timer;
extern fn us_timer_ext(timer: ?*Timer) *?*anyopaque;
extern fn us_timer_close(timer: ?*Timer, fallthrough: i32) void;
extern fn us_timer_set(timer: ?*Timer, cb: ?*const fn (*Timer) callconv(.C) void, ms: i32, repeat_ms: i32) void;
extern fn us_timer_loop(t: ?*Timer) ?*Loop;
pub const us_socket_context_options_t = extern struct {
    key_file_name: [*c]const u8 = null,
    cert_file_name: [*c]const u8 = null,
    passphrase: [*c]const u8 = null,
    dh_params_file_name: [*c]const u8 = null,
    ca_file_name: [*c]const u8 = null,
    ssl_ciphers: [*c]const u8 = null,
    ssl_prefer_low_memory_usage: i32 = 0,
};

pub const us_bun_socket_context_options_t = extern struct {
    key_file_name: [*c]const u8 = null,
    cert_file_name: [*c]const u8 = null,
    passphrase: [*c]const u8 = null,
    dh_params_file_name: [*c]const u8 = null,
    ca_file_name: [*c]const u8 = null,
    ssl_ciphers: [*c]const u8 = null,
    ssl_prefer_low_memory_usage: i32 = 0,
    key: [*c][*c]const u8 = null,
    key_count: u32 = 0,
    cert: [*c][*c]const u8 = null,
    cert_count: u32 = 0,
    ca: [*c][*c]const u8 = null,
    ca_count: u32 = 0,
    secure_options: u32 = 0,
    reject_unauthorized: i32 = 0,
    request_cert: i32 = 0,
    client_renegotiation_limit: u32 = 3,
    client_renegotiation_window: u32 = 600,
};

pub const us_bun_verify_error_t = extern struct {
    error_no: i32 = 0,
    code: [*c]const u8 = null,
    reason: [*c]const u8 = null,
};

pub const us_socket_events_t = extern struct {
    on_open: ?*const fn (*Socket, i32, [*c]u8, i32) callconv(.C) ?*Socket = null,
    on_data: ?*const fn (*Socket, [*c]u8, i32) callconv(.C) ?*Socket = null,
    on_writable: ?*const fn (*Socket) callconv(.C) ?*Socket = null,
    on_close: ?*const fn (*Socket, i32, ?*anyopaque) callconv(.C) ?*Socket = null,

    on_timeout: ?*const fn (*Socket) callconv(.C) ?*Socket = null,
    on_long_timeout: ?*const fn (*Socket) callconv(.C) ?*Socket = null,
    on_end: ?*const fn (*Socket) callconv(.C) ?*Socket = null,
    on_connect_error: ?*const fn (*Socket, i32) callconv(.C) ?*Socket = null,
    on_connect_error_connecting_socket: ?*const fn (*ConnectingSocket, i32) callconv(.C) ?*ConnectingSocket = null,
    on_handshake: ?*const fn (*Socket, i32, us_bun_verify_error_t, ?*anyopaque) callconv(.C) void = null,
};

pub extern fn us_socket_wrap_with_tls(ssl: i32, s: *Socket, options: us_bun_socket_context_options_t, events: us_socket_events_t, socket_ext_size: i32) ?*Socket;
extern fn us_socket_verify_error(ssl: i32, context: *Socket) us_bun_verify_error_t;
extern fn SocketContextimestamp(ssl: i32, context: ?*SocketContext) c_ushort;
pub extern fn us_socket_context_add_server_name(ssl: i32, context: ?*SocketContext, hostname_pattern: [*c]const u8, options: us_socket_context_options_t, ?*anyopaque) void;
pub extern fn us_socket_context_remove_server_name(ssl: i32, context: ?*SocketContext, hostname_pattern: [*c]const u8) void;
extern fn us_socket_context_on_server_name(ssl: i32, context: ?*SocketContext, cb: ?*const fn (?*SocketContext, [*c]const u8) callconv(.C) void) void;
extern fn us_socket_context_get_native_handle(ssl: i32, context: ?*SocketContext) ?*anyopaque;
pub extern fn us_create_socket_context(ssl: i32, loop: ?*Loop, ext_size: i32, options: us_socket_context_options_t) ?*SocketContext;
pub extern fn us_create_bun_socket_context(ssl: i32, loop: ?*Loop, ext_size: i32, options: us_bun_socket_context_options_t) ?*SocketContext;
pub extern fn us_bun_socket_context_add_server_name(ssl: i32, context: ?*SocketContext, hostname_pattern: [*c]const u8, options: us_bun_socket_context_options_t, ?*anyopaque) void;
pub extern fn us_socket_context_free(ssl: i32, context: ?*SocketContext) void;
extern fn us_socket_context_on_open(ssl: i32, context: ?*SocketContext, on_open: *const fn (*Socket, i32, [*c]u8, i32) callconv(.C) ?*Socket) void;
extern fn us_socket_context_on_close(ssl: i32, context: ?*SocketContext, on_close: *const fn (*Socket, i32, ?*anyopaque) callconv(.C) ?*Socket) void;
extern fn us_socket_context_on_data(ssl: i32, context: ?*SocketContext, on_data: *const fn (*Socket, [*c]u8, i32) callconv(.C) ?*Socket) void;
extern fn us_socket_context_on_writable(ssl: i32, context: ?*SocketContext, on_writable: *const fn (*Socket) callconv(.C) ?*Socket) void;

extern fn us_socket_context_on_handshake(ssl: i32, context: ?*SocketContext, on_handshake: *const fn (*Socket, i32, us_bun_verify_error_t, ?*anyopaque) callconv(.C) void, ?*anyopaque) void;

extern fn us_socket_context_on_timeout(ssl: i32, context: ?*SocketContext, on_timeout: *const fn (*Socket) callconv(.C) ?*Socket) void;
extern fn us_socket_context_on_long_timeout(ssl: i32, context: ?*SocketContext, on_timeout: *const fn (*Socket) callconv(.C) ?*Socket) void;
extern fn us_socket_context_on_connect_error(ssl: i32, context: ?*SocketContext, on_connect_error: *const fn (*ConnectingSocket, i32) callconv(.C) ?*ConnectingSocket) void;
extern fn us_socket_context_on_socket_connect_error(ssl: i32, context: ?*SocketContext, on_connect_error: *const fn (*Socket, i32) callconv(.C) ?*Socket) void;
extern fn us_socket_context_on_end(ssl: i32, context: ?*SocketContext, on_end: *const fn (*Socket) callconv(.C) ?*Socket) void;
extern fn us_socket_context_ext(ssl: i32, context: ?*SocketContext) ?*anyopaque;

pub extern fn us_socket_context_listen(ssl: i32, context: ?*SocketContext, host: ?[*:0]const u8, port: i32, options: i32, socket_ext_size: i32) ?*ListenSocket;
pub extern fn us_socket_context_listen_unix(ssl: i32, context: ?*SocketContext, path: [*:0]const u8, pathlen: usize, options: i32, socket_ext_size: i32) ?*ListenSocket;
pub extern fn us_socket_context_connect(ssl: i32, context: ?*SocketContext, host: [*:0]const u8, port: i32, options: i32, socket_ext_size: i32, has_dns_resolved: *i32) ?*anyopaque;
pub extern fn us_socket_context_connect_unix(ssl: i32, context: ?*SocketContext, path: [*c]const u8, pathlen: usize, options: i32, socket_ext_size: i32) ?*Socket;
pub extern fn us_socket_is_established(ssl: i32, s: ?*Socket) i32;
pub extern fn us_socket_context_loop(ssl: i32, context: ?*SocketContext) ?*Loop;
pub extern fn us_socket_context_adopt_socket(ssl: i32, context: ?*SocketContext, s: ?*Socket, ext_size: i32) ?*Socket;
pub extern fn us_create_child_socket_context(ssl: i32, context: ?*SocketContext, context_ext_size: i32) ?*SocketContext;

pub const Poll = opaque {
    pub fn create(
        loop: *Loop,
        comptime Data: type,
        file: i32,
        val: Data,
        fallthrough: bool,
        flags: Flags,
    ) ?*Poll {
        var poll = us_create_poll(loop, @as(i32, @intFromBool(fallthrough)), @sizeOf(Data));
        if (comptime Data != void) {
            poll.data(Data).* = val;
        }
        var flags_int: i32 = 0;
        if (flags.read) {
            flags_int |= Flags.read_flag;
        }

        if (flags.write) {
            flags_int |= Flags.write_flag;
        }
        us_poll_init(poll, file, flags_int);
        return poll;
    }

    pub fn stop(self: *Poll, loop: *Loop) void {
        us_poll_stop(self, loop);
    }

    pub fn change(self: *Poll, loop: *Loop, events: i32) void {
        us_poll_change(self, loop, events);
    }

    pub fn getEvents(self: *Poll) i32 {
        return us_poll_events(self);
    }

    pub fn data(self: *Poll, comptime Data: type) *Data {
        return us_poll_ext(self).?;
    }

    pub fn fd(self: *Poll) std.os.fd_t {
        return us_poll_fd(self);
    }

    pub fn start(self: *Poll, loop: *Loop, flags: Flags) void {
        var flags_int: i32 = 0;
        if (flags.read) {
            flags_int |= Flags.read_flag;
        }

        if (flags.write) {
            flags_int |= Flags.write_flag;
        }

        us_poll_start(self, loop, flags_int);
    }

    pub const Flags = struct {
        read: bool = false,
        write: bool = false,

        //#define LIBUS_SOCKET_READABLE
        pub const read_flag = if (Environment.isLinux) std.os.linux.EPOLL.IN else 1;
        // #define LIBUS_SOCKET_WRITABLE
        pub const write_flag = if (Environment.isLinux) std.os.linux.EPOLL.OUT else 2;
    };

    pub fn deinit(self: *Poll, loop: *Loop) void {
        us_poll_free(self, loop);
    }

    // (void* userData, int fd, int events, int error, struct us_poll_t *poll)
    pub const CallbackType = *const fn (?*anyopaque, i32, i32, i32, *Poll) callconv(.C) void;
    extern fn us_create_poll(loop: ?*Loop, fallthrough: i32, ext_size: c_uint) *Poll;
    extern fn us_poll_set(poll: *Poll, events: i32, callback: CallbackType) *Poll;
    extern fn us_poll_free(p: ?*Poll, loop: ?*Loop) void;
    extern fn us_poll_init(p: ?*Poll, fd: i32, poll_type: i32) void;
    extern fn us_poll_start(p: ?*Poll, loop: ?*Loop, events: i32) void;
    extern fn us_poll_change(p: ?*Poll, loop: ?*Loop, events: i32) void;
    extern fn us_poll_stop(p: ?*Poll, loop: ?*Loop) void;
    extern fn us_poll_events(p: ?*Poll) i32;
    extern fn us_poll_ext(p: ?*Poll) ?*anyopaque;
    extern fn us_poll_fd(p: ?*Poll) std.os.fd_t;
    extern fn us_poll_resize(p: ?*Poll, loop: ?*Loop, ext_size: c_uint) ?*Poll;
};

extern fn us_socket_get_native_handle(ssl: i32, s: ?*Socket) ?*anyopaque;
extern fn us_connecting_socket_get_native_handle(ssl: i32, s: ?*ConnectingSocket) ?*anyopaque;

extern fn us_socket_timeout(ssl: i32, s: ?*Socket, seconds: c_uint) void;
extern fn us_socket_long_timeout(ssl: i32, s: ?*Socket, seconds: c_uint) void;
extern fn us_socket_ext(ssl: i32, s: ?*Socket) *anyopaque;
extern fn us_socket_context(ssl: i32, s: ?*Socket) ?*SocketContext;
extern fn us_socket_flush(ssl: i32, s: ?*Socket) void;
extern fn us_socket_write(ssl: i32, s: ?*Socket, data: [*c]const u8, length: i32, msg_more: i32) i32;
extern fn us_socket_raw_write(ssl: i32, s: ?*Socket, data: [*c]const u8, length: i32, msg_more: i32) i32;
extern fn us_socket_shutdown(ssl: i32, s: ?*Socket) void;
extern fn us_socket_shutdown_read(ssl: i32, s: ?*Socket) void;
extern fn us_socket_is_shut_down(ssl: i32, s: ?*Socket) i32;
extern fn us_socket_is_closed(ssl: i32, s: ?*Socket) i32;
extern fn us_socket_close(ssl: i32, s: ?*Socket, code: i32, reason: ?*anyopaque) ?*Socket;

extern fn us_connecting_socket_timeout(ssl: i32, s: ?*ConnectingSocket, seconds: c_uint) void;
extern fn us_connecting_socket_long_timeout(ssl: i32, s: ?*ConnectingSocket, seconds: c_uint) void;
extern fn us_connecting_socket_ext(ssl: i32, s: ?*ConnectingSocket) *anyopaque;
extern fn us_connecting_socket_context(ssl: i32, s: ?*ConnectingSocket) ?*SocketContext;
extern fn us_connecting_socket_shutdown(ssl: i32, s: ?*ConnectingSocket) void;
extern fn us_connecting_socket_is_closed(ssl: i32, s: ?*ConnectingSocket) i32;
extern fn us_connecting_socket_close(ssl: i32, s: ?*ConnectingSocket) void;
extern fn us_connecting_socket_shutdown_read(ssl: i32, s: ?*ConnectingSocket) void;
extern fn us_connecting_socket_is_shut_down(ssl: i32, s: ?*ConnectingSocket) i32;
extern fn us_connecting_socket_get_error(ssl: i32, s: ?*ConnectingSocket) i32;

pub extern fn us_connecting_socket_get_loop(s: *ConnectingSocket) *Loop;

// if a TLS socket calls this, it will start SSL instance and call open event will also do TLS handshake if required
// will have no effect if the socket is closed or is not TLS
extern fn us_socket_open(ssl: i32, s: ?*Socket, is_client: i32, ip: [*c]const u8, ip_length: i32) ?*Socket;

extern fn us_socket_local_port(ssl: i32, s: ?*Socket) i32;
extern fn us_socket_remote_address(ssl: i32, s: ?*Socket, buf: [*c]u8, length: [*c]i32) void;
extern fn us_socket_local_address(ssl: i32, s: ?*Socket, buf: [*c]u8, length: [*c]i32) void;
pub const uws_app_s = opaque {};
pub const uws_req_s = opaque {};
pub const uws_header_iterator_s = opaque {};
pub const uws_app_t = uws_app_s;

pub const uws_socket_context_s = opaque {};
pub const uws_socket_context_t = uws_socket_context_s;
pub const AnyWebSocket = union(enum) {
    ssl: *NewApp(true).WebSocket,
    tcp: *NewApp(false).WebSocket,

    pub fn raw(this: AnyWebSocket) *RawWebSocket {
        return switch (this) {
            .ssl => this.ssl.raw(),
            .tcp => this.tcp.raw(),
        };
    }
    pub fn as(this: AnyWebSocket, comptime Type: type) ?*Type {
        @setRuntimeSafety(false);
        return switch (this) {
            .ssl => this.ssl.as(Type),
            .tcp => this.tcp.as(Type),
        };
    }

    pub fn close(this: AnyWebSocket) void {
        const ssl_flag = @intFromBool(this == .ssl);
        return uws_ws_close(ssl_flag, this.raw());
    }

    pub fn send(this: AnyWebSocket, message: []const u8, opcode: Opcode, compress: bool, fin: bool) SendStatus {
        return switch (this) {
            .ssl => uws_ws_send_with_options(1, this.ssl.raw(), message.ptr, message.len, opcode, compress, fin),
            .tcp => uws_ws_send_with_options(0, this.tcp.raw(), message.ptr, message.len, opcode, compress, fin),
        };
    }
    pub fn sendLastFragment(this: AnyWebSocket, message: []const u8, compress: bool) SendStatus {
        switch (this) {
            .tcp => return uws_ws_send_last_fragment(0, this.raw(), message.ptr, message.len, compress),
            .ssl => return uws_ws_send_last_fragment(1, this.raw(), message.ptr, message.len, compress),
        }
    }
    pub fn end(this: AnyWebSocket, code: i32, message: []const u8) void {
        switch (this) {
            .tcp => uws_ws_end(0, this.tcp.raw(), code, message.ptr, message.len),
            .ssl => uws_ws_end(1, this.ssl.raw(), code, message.ptr, message.len),
        }
    }
    pub fn cork(this: AnyWebSocket, ctx: anytype, comptime callback: anytype) void {
        const ContextType = @TypeOf(ctx);
        const Wrapper = struct {
            pub fn wrap(user_data: ?*anyopaque) callconv(.C) void {
                @call(bun.callmod_inline, callback, .{bun.cast(ContextType, user_data.?)});
            }
        };

        switch (this) {
            .ssl => uws_ws_cork(1, this.raw(), Wrapper.wrap, ctx),
            .tcp => uws_ws_cork(0, this.raw(), Wrapper.wrap, ctx),
        }
    }
    pub fn subscribe(this: AnyWebSocket, topic: []const u8) bool {
        return switch (this) {
            .ssl => uws_ws_subscribe(1, this.ssl.raw(), topic.ptr, topic.len),
            .tcp => uws_ws_subscribe(0, this.tcp.raw(), topic.ptr, topic.len),
        };
    }
    pub fn unsubscribe(this: AnyWebSocket, topic: []const u8) bool {
        return switch (this) {
            .ssl => uws_ws_unsubscribe(1, this.raw(), topic.ptr, topic.len),
            .tcp => uws_ws_unsubscribe(0, this.raw(), topic.ptr, topic.len),
        };
    }
    pub fn isSubscribed(this: AnyWebSocket, topic: []const u8) bool {
        return switch (this) {
            .ssl => uws_ws_is_subscribed(1, this.raw(), topic.ptr, topic.len),
            .tcp => uws_ws_is_subscribed(0, this.raw(), topic.ptr, topic.len),
        };
    }
    // pub fn iterateTopics(this: AnyWebSocket) {
    //     return uws_ws_iterate_topics(ssl_flag, this.raw(), callback: ?*const fn ([*c]const u8, usize, ?*anyopaque) callconv(.C) void, user_data: ?*anyopaque) void;
    // }
    pub fn publish(this: AnyWebSocket, topic: []const u8, message: []const u8, opcode: Opcode, compress: bool) bool {
        return switch (this) {
            .ssl => uws_ws_publish_with_options(1, this.ssl.raw(), topic.ptr, topic.len, message.ptr, message.len, opcode, compress),
            .tcp => uws_ws_publish_with_options(0, this.tcp.raw(), topic.ptr, topic.len, message.ptr, message.len, opcode, compress),
        };
    }
    pub fn publishWithOptions(ssl: bool, app: *anyopaque, topic: []const u8, message: []const u8, opcode: Opcode, compress: bool) bool {
        return uws_publish(
            @intFromBool(ssl),
            @as(*uws_app_t, @ptrCast(app)),
            topic.ptr,
            topic.len,
            message.ptr,
            message.len,
            opcode,
            compress,
        );
    }
    pub fn getBufferedAmount(this: AnyWebSocket) u32 {
        return switch (this) {
            .ssl => uws_ws_get_buffered_amount(1, this.ssl.raw()),
            .tcp => uws_ws_get_buffered_amount(0, this.tcp.raw()),
        };
    }

    pub fn getRemoteAddress(this: AnyWebSocket, buf: []u8) []u8 {
        return switch (this) {
            .ssl => this.ssl.getRemoteAddress(buf),
            .tcp => this.tcp.getRemoteAddress(buf),
        };
    }
};

pub const RawWebSocket = opaque {};

pub const uws_websocket_handler = ?*const fn (*RawWebSocket) callconv(.C) void;
pub const uws_websocket_message_handler = ?*const fn (*RawWebSocket, [*c]const u8, usize, Opcode) callconv(.C) void;
pub const uws_websocket_close_handler = ?*const fn (*RawWebSocket, i32, [*c]const u8, usize) callconv(.C) void;
pub const uws_websocket_upgrade_handler = ?*const fn (*anyopaque, *uws_res, *Request, *uws_socket_context_t, usize) callconv(.C) void;

pub const uws_websocket_ping_pong_handler = ?*const fn (*RawWebSocket, [*c]const u8, usize) callconv(.C) void;

pub const WebSocketBehavior = extern struct {
    compression: uws_compress_options_t = 0,
    maxPayloadLength: c_uint = std.math.maxInt(u32),
    idleTimeout: c_ushort = 120,
    maxBackpressure: c_uint = 1024 * 1024,
    closeOnBackpressureLimit: bool = false,
    resetIdleTimeoutOnSend: bool = true,
    sendPingsAutomatically: bool = true,
    maxLifetime: c_ushort = 0,
    upgrade: uws_websocket_upgrade_handler = null,
    open: uws_websocket_handler = null,
    message: uws_websocket_message_handler = null,
    drain: uws_websocket_handler = null,
    ping: uws_websocket_ping_pong_handler = null,
    pong: uws_websocket_ping_pong_handler = null,
    close: uws_websocket_close_handler = null,

    pub fn Wrap(
        comptime ServerType: type,
        comptime Type: type,
        comptime ssl: bool,
    ) type {
        return extern struct {
            const is_ssl = ssl;
            const WebSocket = NewApp(is_ssl).WebSocket;
            const Server = ServerType;

            const active_field_name = if (is_ssl) "ssl" else "tcp";

            pub fn _open(raw_ws: *RawWebSocket) callconv(.C) void {
                var ws = @unionInit(AnyWebSocket, active_field_name, @as(*WebSocket, @ptrCast(raw_ws)));
                const this = ws.as(Type).?;
                @call(bun.callmod_inline, Type.onOpen, .{ this, ws });
            }
            pub fn _message(raw_ws: *RawWebSocket, message: [*c]const u8, length: usize, opcode: Opcode) callconv(.C) void {
                var ws = @unionInit(AnyWebSocket, active_field_name, @as(*WebSocket, @ptrCast(raw_ws)));
                const this = ws.as(Type).?;
                @call(
                    .always_inline,
                    Type.onMessage,
                    .{ this, ws, if (length > 0) message[0..length] else "", opcode },
                );
            }
            pub fn _drain(raw_ws: *RawWebSocket) callconv(.C) void {
                var ws = @unionInit(AnyWebSocket, active_field_name, @as(*WebSocket, @ptrCast(raw_ws)));
                const this = ws.as(Type).?;
                @call(bun.callmod_inline, Type.onDrain, .{
                    this,
                    ws,
                });
            }
            pub fn _ping(raw_ws: *RawWebSocket, message: [*c]const u8, length: usize) callconv(.C) void {
                var ws = @unionInit(AnyWebSocket, active_field_name, @as(*WebSocket, @ptrCast(raw_ws)));
                const this = ws.as(Type).?;
                @call(bun.callmod_inline, Type.onPing, .{
                    this,
                    ws,
                    if (length > 0) message[0..length] else "",
                });
            }
            pub fn _pong(raw_ws: *RawWebSocket, message: [*c]const u8, length: usize) callconv(.C) void {
                var ws = @unionInit(AnyWebSocket, active_field_name, @as(*WebSocket, @ptrCast(raw_ws)));
                const this = ws.as(Type).?;
                @call(bun.callmod_inline, Type.onPong, .{
                    this,
                    ws,
                    if (length > 0) message[0..length] else "",
                });
            }
            pub fn _close(raw_ws: *RawWebSocket, code: i32, message: [*c]const u8, length: usize) callconv(.C) void {
                var ws = @unionInit(AnyWebSocket, active_field_name, @as(*WebSocket, @ptrCast(raw_ws)));
                const this = ws.as(Type).?;
                @call(
                    .always_inline,
                    Type.onClose,
                    .{
                        this,
                        ws,
                        code,
                        if (length > 0) message[0..length] else "",
                    },
                );
            }
            pub fn _upgrade(ptr: *anyopaque, res: *uws_res, req: *Request, context: *uws_socket_context_t, id: usize) callconv(.C) void {
                @call(
                    .always_inline,
                    Server.onWebSocketUpgrade,
                    .{ bun.cast(*Server, ptr), @as(*NewApp(is_ssl).Response, @ptrCast(res)), req, context, id },
                );
            }

            pub fn apply(behavior: WebSocketBehavior) WebSocketBehavior {
                return WebSocketBehavior{
                    .compression = behavior.compression,
                    .maxPayloadLength = behavior.maxPayloadLength,
                    .idleTimeout = behavior.idleTimeout,
                    .maxBackpressure = behavior.maxBackpressure,
                    .closeOnBackpressureLimit = behavior.closeOnBackpressureLimit,
                    .resetIdleTimeoutOnSend = behavior.resetIdleTimeoutOnSend,
                    .sendPingsAutomatically = behavior.sendPingsAutomatically,
                    .maxLifetime = behavior.maxLifetime,
                    .upgrade = _upgrade,
                    .open = _open,
                    .message = _message,
                    .drain = _drain,
                    .ping = _ping,
                    .pong = _pong,
                    .close = _close,
                };
            }
        };
    }
};
pub const uws_listen_handler = ?*const fn (?*ListenSocket, ?*anyopaque) callconv(.C) void;
pub const uws_method_handler = ?*const fn (*uws_res, *Request, ?*anyopaque) callconv(.C) void;
pub const uws_filter_handler = ?*const fn (*uws_res, i32, ?*anyopaque) callconv(.C) void;
pub const uws_missing_server_handler = ?*const fn ([*c]const u8, ?*anyopaque) callconv(.C) void;

pub const Request = opaque {
    pub fn isAncient(req: *Request) bool {
        return uws_req_is_ancient(req);
    }
    pub fn getYield(req: *Request) bool {
        return uws_req_get_yield(req);
    }
    pub fn setYield(req: *Request, yield: bool) void {
        uws_req_set_yield(req, yield);
    }
    pub fn url(req: *Request) []const u8 {
        var ptr: [*]const u8 = undefined;
        return ptr[0..req.uws_req_get_url(&ptr)];
    }
    pub fn method(req: *Request) []const u8 {
        var ptr: [*]const u8 = undefined;
        return ptr[0..req.uws_req_get_method(&ptr)];
    }
    pub fn header(req: *Request, name: []const u8) ?[]const u8 {
        bun.assert(std.ascii.isLower(name[0]));

        var ptr: [*]const u8 = undefined;
        const len = req.uws_req_get_header(name.ptr, name.len, &ptr);
        if (len == 0) return null;
        return ptr[0..len];
    }
    pub fn query(req: *Request, name: []const u8) []const u8 {
        var ptr: [*]const u8 = undefined;
        return ptr[0..req.uws_req_get_query(name.ptr, name.len, &ptr)];
    }
    pub fn parameter(req: *Request, index: u16) []const u8 {
        var ptr: [*]const u8 = undefined;
        return ptr[0..req.uws_req_get_parameter(@as(c_ushort, @intCast(index)), &ptr)];
    }

    extern fn uws_req_is_ancient(res: *Request) bool;
    extern fn uws_req_get_yield(res: *Request) bool;
    extern fn uws_req_set_yield(res: *Request, yield: bool) void;
    extern fn uws_req_get_url(res: *Request, dest: *[*]const u8) usize;
    extern fn uws_req_get_method(res: *Request, dest: *[*]const u8) usize;
    extern fn uws_req_get_header(res: *Request, lower_case_header: [*]const u8, lower_case_header_length: usize, dest: *[*]const u8) usize;
    extern fn uws_req_get_query(res: *Request, key: [*c]const u8, key_length: usize, dest: *[*]const u8) usize;
    extern fn uws_req_get_parameter(res: *Request, index: c_ushort, dest: *[*]const u8) usize;
};

pub const ListenSocket = opaque {
    pub fn close(this: *ListenSocket, ssl: bool) void {
        us_listen_socket_close(@intFromBool(ssl), this);
    }
    pub fn getLocalPort(this: *ListenSocket, ssl: bool) i32 {
        return us_socket_local_port(@intFromBool(ssl), @as(*uws.Socket, @ptrCast(this)));
    }
};
extern fn us_listen_socket_close(ssl: i32, ls: *ListenSocket) void;
extern fn uws_app_close(ssl: i32, app: *uws_app_s) void;
extern fn us_socket_context_close(ssl: i32, ctx: *anyopaque) void;

pub const SocketAddress = struct {
    ip: []const u8,
    port: i32,
    is_ipv6: bool,
};

pub fn NewApp(comptime ssl: bool) type {
    return opaque {
        const ssl_flag = @as(i32, @intFromBool(ssl));
        const ThisApp = @This();

        pub fn close(this: *ThisApp) void {
            if (comptime is_bindgen) {
                unreachable;
            }

            return uws_app_close(ssl_flag, @as(*uws_app_s, @ptrCast(this)));
        }

        pub fn create(opts: us_bun_socket_context_options_t) *ThisApp {
            if (comptime is_bindgen) {
                unreachable;
            }
            return @as(*ThisApp, @ptrCast(uws_create_app(ssl_flag, opts)));
        }
        pub fn destroy(app: *ThisApp) void {
            if (comptime is_bindgen) {
                unreachable;
            }

            return uws_app_destroy(ssl_flag, @as(*uws_app_s, @ptrCast(app)));
        }

        fn RouteHandler(comptime UserDataType: type, comptime handler: fn (UserDataType, *Request, *Response) void) type {
            return struct {
                pub fn handle(res: *uws_res, req: *Request, user_data: ?*anyopaque) callconv(.C) void {
                    if (comptime is_bindgen) {
                        unreachable;
                    }

                    if (comptime UserDataType == void) {
                        return @call(
                            .always_inline,
                            handler,
                            .{
                                {},
                                req,
                                @as(*Response, @ptrCast(@alignCast(res))),
                            },
                        );
                    } else {
                        return @call(
                            .always_inline,
                            handler,
                            .{
                                @as(UserDataType, @ptrCast(@alignCast(user_data.?))),
                                req,
                                @as(*Response, @ptrCast(@alignCast(res))),
                            },
                        );
                    }
                }
            };
        }

        pub const ListenSocket = opaque {
            pub inline fn close(this: *ThisApp.ListenSocket) void {
                if (comptime is_bindgen) {
                    unreachable;
                }
                return us_listen_socket_close(ssl_flag, @as(*uws.ListenSocket, @ptrCast(this)));
            }
            pub inline fn getLocalPort(this: *ThisApp.ListenSocket) i32 {
                if (comptime is_bindgen) {
                    unreachable;
                }
                return us_socket_local_port(ssl_flag, @as(*uws.Socket, @ptrCast(this)));
            }

            pub fn socket(this: *@This()) NewSocketHandler(ssl) {
                return NewSocketHandler(ssl).from(@ptrCast(this));
            }
        };

        pub fn get(
            app: *ThisApp,
            pattern: [:0]const u8,
            comptime UserDataType: type,
            user_data: UserDataType,
            comptime handler: (fn (UserDataType, *Request, *Response) void),
        ) void {
            if (comptime is_bindgen) {
                unreachable;
            }
            uws_app_get(ssl_flag, @as(*uws_app_t, @ptrCast(app)), pattern, RouteHandler(UserDataType, handler).handle, user_data);
        }
        pub fn post(
            app: *ThisApp,
            pattern: [:0]const u8,
            comptime UserDataType: type,
            user_data: UserDataType,
            comptime handler: (fn (UserDataType, *Request, *Response) void),
        ) void {
            if (comptime is_bindgen) {
                unreachable;
            }
            uws_app_post(ssl_flag, @as(*uws_app_t, @ptrCast(app)), pattern, RouteHandler(UserDataType, handler).handle, user_data);
        }
        pub fn options(
            app: *ThisApp,
            pattern: [:0]const u8,
            comptime UserDataType: type,
            user_data: UserDataType,
            comptime handler: (fn (UserDataType, *Request, *Response) void),
        ) void {
            if (comptime is_bindgen) {
                unreachable;
            }
            uws_app_options(ssl_flag, @as(*uws_app_t, @ptrCast(app)), pattern, RouteHandler(UserDataType, handler).handle, user_data);
        }
        pub fn delete(
            app: *ThisApp,
            pattern: [:0]const u8,
            comptime UserDataType: type,
            user_data: UserDataType,
            comptime handler: (fn (UserDataType, *Request, *Response) void),
        ) void {
            if (comptime is_bindgen) {
                unreachable;
            }
            uws_app_delete(ssl_flag, @as(*uws_app_t, @ptrCast(app)), pattern, RouteHandler(UserDataType, handler).handle, user_data);
        }
        pub fn patch(
            app: *ThisApp,
            pattern: [:0]const u8,
            comptime UserDataType: type,
            user_data: UserDataType,
            comptime handler: (fn (UserDataType, *Request, *Response) void),
        ) void {
            if (comptime is_bindgen) {
                unreachable;
            }
            uws_app_patch(ssl_flag, @as(*uws_app_t, @ptrCast(app)), pattern, RouteHandler(UserDataType, handler).handle, user_data);
        }
        pub fn put(
            app: *ThisApp,
            pattern: [:0]const u8,
            comptime UserDataType: type,
            user_data: UserDataType,
            comptime handler: (fn (UserDataType, *Request, *Response) void),
        ) void {
            if (comptime is_bindgen) {
                unreachable;
            }
            uws_app_put(ssl_flag, @as(*uws_app_t, @ptrCast(app)), pattern, RouteHandler(UserDataType, handler).handle, user_data);
        }
        pub fn head(
            app: *ThisApp,
            pattern: [:0]const u8,
            comptime UserDataType: type,
            user_data: UserDataType,
            comptime handler: (fn (UserDataType, *Request, *Response) void),
        ) void {
            if (comptime is_bindgen) {
                unreachable;
            }
            uws_app_head(ssl_flag, @as(*uws_app_t, @ptrCast(app)), pattern, RouteHandler(UserDataType, handler).handle, user_data);
        }
        pub fn connect(
            app: *ThisApp,
            pattern: [:0]const u8,
            comptime UserDataType: type,
            user_data: UserDataType,
            comptime handler: (fn (UserDataType, *Request, *Response) void),
        ) void {
            if (comptime is_bindgen) {
                unreachable;
            }
            uws_app_connect(ssl_flag, @as(*uws_app_t, @ptrCast(app)), pattern, RouteHandler(UserDataType, handler).handle, user_data);
        }
        pub fn trace(
            app: *ThisApp,
            pattern: [:0]const u8,
            comptime UserDataType: type,
            user_data: UserDataType,
            comptime handler: (fn (UserDataType, *Request, *Response) void),
        ) void {
            if (comptime is_bindgen) {
                unreachable;
            }
            uws_app_trace(ssl_flag, @as(*uws_app_t, @ptrCast(app)), pattern, RouteHandler(UserDataType, handler).handle, user_data);
        }
        pub fn any(
            app: *ThisApp,
            pattern: [:0]const u8,
            comptime UserDataType: type,
            user_data: UserDataType,
            comptime handler: (fn (UserDataType, *Request, *Response) void),
        ) void {
            if (comptime is_bindgen) {
                unreachable;
            }
            uws_app_any(ssl_flag, @as(*uws_app_t, @ptrCast(app)), pattern, RouteHandler(UserDataType, handler).handle, user_data);
        }
        pub fn domain(app: *ThisApp, pattern: [:0]const u8) void {
            uws_app_domain(ssl_flag, @as(*uws_app_t, @ptrCast(app)), pattern);
        }
        pub fn run(app: *ThisApp) void {
            if (comptime is_bindgen) {
                unreachable;
            }
            return uws_app_run(ssl_flag, @as(*uws_app_t, @ptrCast(app)));
        }
        pub fn listen(
            app: *ThisApp,
            port: i32,
            comptime UserData: type,
            user_data: UserData,
            comptime handler: fn (UserData, ?*ThisApp.ListenSocket, uws_app_listen_config_t) void,
        ) void {
            if (comptime is_bindgen) {
                unreachable;
            }
            const Wrapper = struct {
                pub fn handle(socket: ?*uws.ListenSocket, conf: uws_app_listen_config_t, data: ?*anyopaque) callconv(.C) void {
                    if (comptime UserData == void) {
                        @call(bun.callmod_inline, handler, .{ {}, @as(?*ThisApp.ListenSocket, @ptrCast(socket)), conf });
                    } else {
                        @call(bun.callmod_inline, handler, .{
                            @as(UserData, @ptrCast(@alignCast(data.?))),
                            @as(?*ThisApp.ListenSocket, @ptrCast(socket)),
                            conf,
                        });
                    }
                }
            };
            return uws_app_listen(ssl_flag, @as(*uws_app_t, @ptrCast(app)), port, Wrapper.handle, user_data);
        }

        pub fn listenWithConfig(
            app: *ThisApp,
            comptime UserData: type,
            user_data: UserData,
            comptime handler: fn (UserData, ?*ThisApp.ListenSocket) void,
            config: uws_app_listen_config_t,
        ) void {
            const Wrapper = struct {
                pub fn handle(socket: ?*uws.ListenSocket, data: ?*anyopaque) callconv(.C) void {
                    if (comptime UserData == void) {
                        @call(bun.callmod_inline, handler, .{ {}, @as(?*ThisApp.ListenSocket, @ptrCast(socket)) });
                    } else {
                        @call(bun.callmod_inline, handler, .{
                            @as(UserData, @ptrCast(@alignCast(data.?))),
                            @as(?*ThisApp.ListenSocket, @ptrCast(socket)),
                        });
                    }
                }
            };
            return uws_app_listen_with_config(ssl_flag, @as(*uws_app_t, @ptrCast(app)), config.host, @as(u16, @intCast(config.port)), config.options, Wrapper.handle, user_data);
        }

        pub fn listenOnUnixSocket(
            app: *ThisApp,
            comptime UserData: type,
            user_data: UserData,
            comptime handler: fn (UserData, ?*ThisApp.ListenSocket) void,
            domain_name: [:0]const u8,
            flags: i32,
        ) void {
            const Wrapper = struct {
                pub fn handle(socket: ?*uws.ListenSocket, _: [*:0]const u8, _: i32, data: *anyopaque) callconv(.C) void {
                    if (comptime UserData == void) {
                        @call(bun.callmod_inline, handler, .{ {}, @as(?*ThisApp.ListenSocket, @ptrCast(socket)) });
                    } else {
                        @call(bun.callmod_inline, handler, .{
                            @as(UserData, @ptrCast(@alignCast(data))),
                            @as(?*ThisApp.ListenSocket, @ptrCast(socket)),
                        });
                    }
                }
            };
            return uws_app_listen_domain_with_options(
                ssl_flag,
                @as(*uws_app_t, @ptrCast(app)),
                domain_name.ptr,
                domain_name.len,
                flags,
                Wrapper.handle,
                user_data,
            );
        }

        pub fn constructorFailed(app: *ThisApp) bool {
            return uws_constructor_failed(ssl_flag, app);
        }
        pub fn num_subscribers(app: *ThisApp, topic: []const u8) c_uint {
            return uws_num_subscribers(ssl_flag, @as(*uws_app_t, @ptrCast(app)), topic.ptr, topic.len);
        }
        pub fn publish(app: *ThisApp, topic: []const u8, message: []const u8, opcode: Opcode, compress: bool) bool {
            return uws_publish(ssl_flag, @as(*uws_app_t, @ptrCast(app)), topic.ptr, topic.len, message.ptr, message.len, opcode, compress);
        }
        pub fn getNativeHandle(app: *ThisApp) ?*anyopaque {
            return uws_get_native_handle(ssl_flag, app);
        }
        pub fn removeServerName(app: *ThisApp, hostname_pattern: [*:0]const u8) void {
            return uws_remove_server_name(ssl_flag, @as(*uws_app_t, @ptrCast(app)), hostname_pattern);
        }
        pub fn addServerName(app: *ThisApp, hostname_pattern: [*:0]const u8) void {
            return uws_add_server_name(ssl_flag, @as(*uws_app_t, @ptrCast(app)), hostname_pattern);
        }
        pub fn addServerNameWithOptions(app: *ThisApp, hostname_pattern: [*:0]const u8, opts: us_bun_socket_context_options_t) void {
            return uws_add_server_name_with_options(ssl_flag, @as(*uws_app_t, @ptrCast(app)), hostname_pattern, opts);
        }
        pub fn missingServerName(app: *ThisApp, handler: uws_missing_server_handler, user_data: ?*anyopaque) void {
            return uws_missing_server_name(ssl_flag, @as(*uws_app_t, @ptrCast(app)), handler, user_data);
        }
        pub fn filter(app: *ThisApp, handler: uws_filter_handler, user_data: ?*anyopaque) void {
            return uws_filter(ssl_flag, @as(*uws_app_t, @ptrCast(app)), handler, user_data);
        }
        pub fn ws(app: *ThisApp, pattern: []const u8, ctx: *anyopaque, id: usize, behavior_: WebSocketBehavior) void {
            var behavior = behavior_;
            uws_ws(ssl_flag, @as(*uws_app_t, @ptrCast(app)), ctx, pattern.ptr, pattern.len, id, &behavior);
        }

        pub const Response = opaque {
            inline fn castRes(res: *uws_res) *Response {
                return @as(*Response, @ptrCast(@alignCast(res)));
            }

            pub inline fn downcast(res: *Response) *uws_res {
                return @as(*uws_res, @ptrCast(@alignCast(res)));
            }

            pub fn end(res: *Response, data: []const u8, close_connection: bool) void {
                uws_res_end(ssl_flag, res.downcast(), data.ptr, data.len, close_connection);
            }

            pub fn tryEnd(res: *Response, data: []const u8, total: usize, close_: bool) bool {
                return uws_res_try_end(ssl_flag, res.downcast(), data.ptr, data.len, total, close_);
            }

            pub fn state(res: *const Response) State {
                return uws_res_state(ssl_flag, @as(*const uws_res, @ptrCast(@alignCast(res))));
            }

            pub fn prepareForSendfile(res: *Response) void {
                return uws_res_prepare_for_sendfile(ssl_flag, res.downcast());
            }

            pub fn uncork(_: *Response) void {
                // uws_res_uncork(
                //     ssl_flag,
                //     res.downcast(),
                // );
            }
            pub fn pause(res: *Response) void {
                uws_res_pause(ssl_flag, res.downcast());
            }
            pub fn @"resume"(res: *Response) void {
                uws_res_resume(ssl_flag, res.downcast());
            }
            pub fn writeContinue(res: *Response) void {
                uws_res_write_continue(ssl_flag, res.downcast());
            }
            pub fn writeStatus(res: *Response, status: []const u8) void {
                uws_res_write_status(ssl_flag, res.downcast(), status.ptr, status.len);
            }
            pub fn writeHeader(res: *Response, key: []const u8, value: []const u8) void {
                uws_res_write_header(ssl_flag, res.downcast(), key.ptr, key.len, value.ptr, value.len);
            }
            pub fn writeHeaderInt(res: *Response, key: []const u8, value: u64) void {
                uws_res_write_header_int(ssl_flag, res.downcast(), key.ptr, key.len, value);
            }
            pub fn endWithoutBody(res: *Response, close_connection: bool) void {
                uws_res_end_without_body(ssl_flag, res.downcast(), close_connection);
            }
            pub fn write(res: *Response, data: []const u8) bool {
                return uws_res_write(ssl_flag, res.downcast(), data.ptr, data.len);
            }
            pub fn getWriteOffset(res: *Response) u64 {
                return uws_res_get_write_offset(ssl_flag, res.downcast());
            }
            pub fn overrideWriteOffset(res: *Response, offset: anytype) void {
                uws_res_override_write_offset(ssl_flag, res.downcast(), @as(u64, @intCast(offset)));
            }
            pub fn hasResponded(res: *Response) bool {
                return uws_res_has_responded(ssl_flag, res.downcast());
            }

            pub fn getNativeHandle(res: *Response) bun.FileDescriptor {
                if (comptime Environment.isWindows) {
                    // on windows uSockets exposes SOCKET
                    return bun.toFD(@as(bun.FDImpl.System, @ptrCast(uws_res_get_native_handle(ssl_flag, res.downcast()))));
                }

                return bun.toFD(@as(i32, @intCast(@intFromPtr(uws_res_get_native_handle(ssl_flag, res.downcast())))));
            }
            pub fn getRemoteAddress(res: *Response) ?[]const u8 {
                var buf: [*]const u8 = undefined;
                const size = uws_res_get_remote_address(ssl_flag, res.downcast(), &buf);
                return if (size > 0) buf[0..size] else null;
            }
            pub fn getRemoteAddressAsText(res: *Response) ?[]const u8 {
                var buf: [*]const u8 = undefined;
                const size = uws_res_get_remote_address_as_text(ssl_flag, res.downcast(), &buf);
                return if (size > 0) buf[0..size] else null;
            }
            pub fn getRemoteSocketInfo(res: *Response) ?SocketAddress {
                var address = SocketAddress{
                    .ip = undefined,
                    .port = undefined,
                    .is_ipv6 = undefined,
                };
                // This function will fill in the slots and return len.
                // if len is zero it will not fill in the slots so it is ub to
                // return the struct in that case.
                address.ip.len = uws_res_get_remote_address_info(
                    res.downcast(),
                    &address.ip.ptr,
                    &address.port,
                    &address.is_ipv6,
                );
                return if (address.ip.len > 0) address else null;
            }
            pub fn onWritable(
                res: *Response,
                comptime UserDataType: type,
                comptime handler: fn (UserDataType, u64, *Response) callconv(.C) bool,
                user_data: UserDataType,
            ) void {
                const Wrapper = struct {
                    pub fn handle(this: *uws_res, amount: u64, data: ?*anyopaque) callconv(.C) bool {
                        if (comptime UserDataType == void) {
                            return @call(bun.callmod_inline, handler, .{ {}, amount, castRes(this) });
                        } else {
                            return @call(bun.callmod_inline, handler, .{
                                @as(UserDataType, @ptrCast(@alignCast(data.?))),
                                amount,
                                castRes(this),
                            });
                        }
                    }
                };
                uws_res_on_writable(ssl_flag, res.downcast(), Wrapper.handle, user_data);
            }

            pub fn clearOnWritable(res: *Response) void {
                uws_res_clear_on_writable(ssl_flag, res.downcast());
            }
            pub inline fn markNeedsMore(res: *Response) void {
                if (!ssl) {
                    us_socket_mark_needs_more_not_ssl(res.downcast());
                }
            }
            pub fn onAborted(res: *Response, comptime UserDataType: type, comptime handler: fn (UserDataType, *Response) void, opcional_data: UserDataType) void {
                const Wrapper = struct {
                    pub fn handle(this: *uws_res, user_data: ?*anyopaque) callconv(.C) void {
                        if (comptime UserDataType == void) {
                            @call(bun.callmod_inline, handler, .{ {}, castRes(this), {} });
                        } else {
                            @call(bun.callmod_inline, handler, .{ @as(UserDataType, @ptrCast(@alignCast(user_data.?))), castRes(this) });
                        }
                    }
                };
                uws_res_on_aborted(ssl_flag, res.downcast(), Wrapper.handle, opcional_data);
            }

            pub fn clearAborted(res: *Response) void {
                uws_res_on_aborted(ssl_flag, res.downcast(), null, null);
            }

            pub fn clearOnData(res: *Response) void {
                uws_res_on_data(ssl_flag, res.downcast(), null, null);
            }

            pub fn onData(
                res: *Response,
                comptime UserDataType: type,
                comptime handler: fn (UserDataType, *Response, chunk: []const u8, last: bool) void,
                opcional_data: UserDataType,
            ) void {
                const Wrapper = struct {
                    pub fn handle(this: *uws_res, chunk_ptr: [*c]const u8, len: usize, last: bool, user_data: ?*anyopaque) callconv(.C) void {
                        if (comptime UserDataType == void) {
                            @call(bun.callmod_inline, handler, .{
                                {},
                                castRes(this),
                                if (len > 0) chunk_ptr[0..len] else "",
                                last,
                            });
                        } else {
                            @call(bun.callmod_inline, handler, .{
                                @as(UserDataType, @ptrCast(@alignCast(user_data.?))),
                                castRes(this),
                                if (len > 0) chunk_ptr[0..len] else "",
                                last,
                            });
                        }
                    }
                };

                uws_res_on_data(ssl_flag, res.downcast(), Wrapper.handle, opcional_data);
            }

            pub fn endStream(res: *Response, close_connection: bool) void {
                uws_res_end_stream(ssl_flag, res.downcast(), close_connection);
            }

            pub fn corked(
                res: *Response,
                comptime Function: anytype,
                args: anytype,
            ) @typeInfo(@TypeOf(Function)).Fn.return_type.? {
                const Wrapper = struct {
                    opts: @TypeOf(args),
                    result: @typeInfo(@TypeOf(Function)).Fn.return_type.? = undefined,
                    pub fn run(this: *@This()) void {
                        this.result = Function(this.opts);
                    }
                };
                var wrapped = Wrapper{
                    .opts = args,
                    .result = undefined,
                };
                runCorkedWithType(res, *Wrapper, Wrapper.run, &wrapped);
                return wrapped.result;
            }

            pub fn runCorkedWithType(
                res: *Response,
                comptime UserDataType: type,
                comptime handler: fn (UserDataType) void,
                opcional_data: UserDataType,
            ) void {
                const Wrapper = struct {
                    pub fn handle(user_data: ?*anyopaque) callconv(.C) void {
                        if (comptime UserDataType == void) {
                            @call(bun.callmod_inline, handler, .{
                                {},
                            });
                        } else {
                            @call(bun.callmod_inline, handler, .{
                                @as(UserDataType, @ptrCast(@alignCast(user_data.?))),
                            });
                        }
                    }
                };

                uws_res_cork(ssl_flag, res.downcast(), opcional_data, Wrapper.handle);
            }

            // pub fn onSocketWritable(
            //     res: *Response,
            //     comptime UserDataType: type,
            //     comptime handler: fn (UserDataType, fd: i32) void,
            //     opcional_data: UserDataType,
            // ) void {
            //     const Wrapper = struct {
            //         pub fn handle(user_data: ?*anyopaque, fd: i32) callconv(.C) void {
            //             if (comptime UserDataType == void) {
            //                 @call(bun.callmod_inline, handler, .{
            //                     {},
            //                     fd,
            //                 });
            //             } else {
            //                 @call(bun.callmod_inline, handler, .{
            //                     @ptrCast(
            //                         UserDataType,
            //                         @alignCast( user_data.?),
            //                     ),
            //                     fd,
            //                 });
            //             }
            //         }
            //     };

            //     const OnWritable = struct {
            //         pub fn handle(socket: *Socket) callconv(.C) ?*Socket {
            //             if (comptime UserDataType == void) {
            //                 @call(bun.callmod_inline, handler, .{
            //                     {},
            //                     fd,
            //                 });
            //             } else {
            //                 @call(bun.callmod_inline, handler, .{
            //                     @ptrCast(
            //                         UserDataType,
            //                         @alignCast( user_data.?),
            //                     ),
            //                     fd,
            //                 });
            //             }

            //             return socket;
            //         }
            //     };

            //     var socket_ctx = us_socket_context(ssl_flag, uws_res_get_native_handle(ssl_flag, res)).?;
            //     var child = us_create_child_socket_context(ssl_flag, socket_ctx, 8);

            // }

            pub fn writeHeaders(
                res: *Response,
                names: []const Api.StringPointer,
                values: []const Api.StringPointer,
                buf: []const u8,
            ) void {
                uws_res_write_headers(ssl_flag, res.downcast(), names.ptr, values.ptr, values.len, buf.ptr);
            }

            pub fn upgrade(
                res: *Response,
                comptime Data: type,
                data: Data,
                sec_web_socket_key: []const u8,
                sec_web_socket_protocol: []const u8,
                sec_web_socket_extensions: []const u8,
                ctx: ?*uws_socket_context_t,
            ) void {
                uws_res_upgrade(
                    ssl_flag,
                    res.downcast(),
                    data,
                    sec_web_socket_key.ptr,
                    sec_web_socket_key.len,
                    sec_web_socket_protocol.ptr,
                    sec_web_socket_protocol.len,
                    sec_web_socket_extensions.ptr,
                    sec_web_socket_extensions.len,
                    ctx,
                );
            }
        };

        pub const WebSocket = opaque {
            pub fn raw(this: *WebSocket) *RawWebSocket {
                return @as(*RawWebSocket, @ptrCast(this));
            }
            pub fn as(this: *WebSocket, comptime Type: type) ?*Type {
                @setRuntimeSafety(false);
                return @as(?*Type, @ptrCast(@alignCast(uws_ws_get_user_data(ssl_flag, this.raw()))));
            }

            pub fn close(this: *WebSocket) void {
                return uws_ws_close(ssl_flag, this.raw());
            }
            pub fn send(this: *WebSocket, message: []const u8, opcode: Opcode) SendStatus {
                return uws_ws_send(ssl_flag, this.raw(), message.ptr, message.len, opcode);
            }
            pub fn sendWithOptions(this: *WebSocket, message: []const u8, opcode: Opcode, compress: bool, fin: bool) SendStatus {
                return uws_ws_send_with_options(ssl_flag, this.raw(), message.ptr, message.len, opcode, compress, fin);
            }
            // pub fn sendFragment(this: *WebSocket, message: []const u8) SendStatus {
            //     return uws_ws_send_fragment(ssl_flag, this.raw(), message: [*c]const u8, length: usize, compress: bool);
            // }
            // pub fn sendFirstFragment(this: *WebSocket, message: []const u8) SendStatus {
            //     return uws_ws_send_first_fragment(ssl_flag, this.raw(), message: [*c]const u8, length: usize, compress: bool);
            // }
            // pub fn sendFirstFragmentWithOpcode(this: *WebSocket, message: []const u8, opcode: u32, compress: bool) SendStatus {
            //     return uws_ws_send_first_fragment_with_opcode(ssl_flag, this.raw(), message: [*c]const u8, length: usize, opcode: Opcode, compress: bool);
            // }
            pub fn sendLastFragment(this: *WebSocket, message: []const u8, compress: bool) SendStatus {
                return uws_ws_send_last_fragment(ssl_flag, this.raw(), message.ptr, message.len, compress);
            }
            pub fn end(this: *WebSocket, code: i32, message: []const u8) void {
                return uws_ws_end(ssl_flag, this.raw(), code, message.ptr, message.len);
            }
            pub fn cork(this: *WebSocket, ctx: anytype, comptime callback: anytype) void {
                const ContextType = @TypeOf(ctx);
                const Wrapper = struct {
                    pub fn wrap(user_data: ?*anyopaque) callconv(.C) void {
                        @call(bun.callmod_inline, callback, .{bun.cast(ContextType, user_data.?)});
                    }
                };

                return uws_ws_cork(ssl_flag, this.raw(), Wrapper.wrap, ctx);
            }
            pub fn subscribe(this: *WebSocket, topic: []const u8) bool {
                return uws_ws_subscribe(ssl_flag, this.raw(), topic.ptr, topic.len);
            }
            pub fn unsubscribe(this: *WebSocket, topic: []const u8) bool {
                return uws_ws_unsubscribe(ssl_flag, this.raw(), topic.ptr, topic.len);
            }
            pub fn isSubscribed(this: *WebSocket, topic: []const u8) bool {
                return uws_ws_is_subscribed(ssl_flag, this.raw(), topic.ptr, topic.len);
            }
            // pub fn iterateTopics(this: *WebSocket) {
            //     return uws_ws_iterate_topics(ssl_flag, this.raw(), callback: ?*const fn ([*c]const u8, usize, ?*anyopaque) callconv(.C) void, user_data: ?*anyopaque) void;
            // }
            pub fn publish(this: *WebSocket, topic: []const u8, message: []const u8) bool {
                return uws_ws_publish(ssl_flag, this.raw(), topic.ptr, topic.len, message.ptr, message.len);
            }
            pub fn publishWithOptions(this: *WebSocket, topic: []const u8, message: []const u8, opcode: Opcode, compress: bool) bool {
                return uws_ws_publish_with_options(ssl_flag, this.raw(), topic.ptr, topic.len, message.ptr, message.len, opcode, compress);
            }
            pub fn getBufferedAmount(this: *WebSocket) u32 {
                return uws_ws_get_buffered_amount(ssl_flag, this.raw());
            }
            pub fn getRemoteAddress(this: *WebSocket, buf: []u8) []u8 {
                var ptr: [*]u8 = undefined;
                const len = uws_ws_get_remote_address(ssl_flag, this.raw(), &ptr);
                bun.copy(u8, buf, ptr[0..len]);
                return buf[0..len];
            }
        };
    };
}
extern fn uws_res_end_stream(ssl: i32, res: *uws_res, close_connection: bool) void;
extern fn uws_res_prepare_for_sendfile(ssl: i32, res: *uws_res) void;
extern fn uws_res_get_native_handle(ssl: i32, res: *uws_res) *Socket;
extern fn uws_res_get_remote_address(ssl: i32, res: *uws_res, dest: *[*]const u8) usize;
extern fn uws_res_get_remote_address_as_text(ssl: i32, res: *uws_res, dest: *[*]const u8) usize;
extern fn uws_create_app(ssl: i32, options: us_bun_socket_context_options_t) *uws_app_t;
extern fn uws_app_destroy(ssl: i32, app: *uws_app_t) void;
extern fn uws_app_get(ssl: i32, app: *uws_app_t, pattern: [*c]const u8, handler: uws_method_handler, user_data: ?*anyopaque) void;
extern fn uws_app_post(ssl: i32, app: *uws_app_t, pattern: [*c]const u8, handler: uws_method_handler, user_data: ?*anyopaque) void;
extern fn uws_app_options(ssl: i32, app: *uws_app_t, pattern: [*c]const u8, handler: uws_method_handler, user_data: ?*anyopaque) void;
extern fn uws_app_delete(ssl: i32, app: *uws_app_t, pattern: [*c]const u8, handler: uws_method_handler, user_data: ?*anyopaque) void;
extern fn uws_app_patch(ssl: i32, app: *uws_app_t, pattern: [*c]const u8, handler: uws_method_handler, user_data: ?*anyopaque) void;
extern fn uws_app_put(ssl: i32, app: *uws_app_t, pattern: [*c]const u8, handler: uws_method_handler, user_data: ?*anyopaque) void;
extern fn uws_app_head(ssl: i32, app: *uws_app_t, pattern: [*c]const u8, handler: uws_method_handler, user_data: ?*anyopaque) void;
extern fn uws_app_connect(ssl: i32, app: *uws_app_t, pattern: [*c]const u8, handler: uws_method_handler, user_data: ?*anyopaque) void;
extern fn uws_app_trace(ssl: i32, app: *uws_app_t, pattern: [*c]const u8, handler: uws_method_handler, user_data: ?*anyopaque) void;
extern fn uws_app_any(ssl: i32, app: *uws_app_t, pattern: [*c]const u8, handler: uws_method_handler, user_data: ?*anyopaque) void;
extern fn uws_app_run(ssl: i32, *uws_app_t) void;
extern fn uws_app_domain(ssl: i32, app: *uws_app_t, domain: [*c]const u8) void;
extern fn uws_app_listen(ssl: i32, app: *uws_app_t, port: i32, handler: uws_listen_handler, user_data: ?*anyopaque) void;
extern fn uws_app_listen_with_config(
    ssl: i32,
    app: *uws_app_t,
    host: [*c]const u8,
    port: u16,
    options: i32,
    handler: uws_listen_handler,
    user_data: ?*anyopaque,
) void;
extern fn uws_constructor_failed(ssl: i32, app: *uws_app_t) bool;
extern fn uws_num_subscribers(ssl: i32, app: *uws_app_t, topic: [*c]const u8, topic_length: usize) c_uint;
extern fn uws_publish(ssl: i32, app: *uws_app_t, topic: [*c]const u8, topic_length: usize, message: [*c]const u8, message_length: usize, opcode: Opcode, compress: bool) bool;
extern fn uws_get_native_handle(ssl: i32, app: *anyopaque) ?*anyopaque;
extern fn uws_remove_server_name(ssl: i32, app: *uws_app_t, hostname_pattern: [*c]const u8) void;
extern fn uws_add_server_name(ssl: i32, app: *uws_app_t, hostname_pattern: [*c]const u8) void;
extern fn uws_add_server_name_with_options(ssl: i32, app: *uws_app_t, hostname_pattern: [*c]const u8, options: us_bun_socket_context_options_t) void;
extern fn uws_missing_server_name(ssl: i32, app: *uws_app_t, handler: uws_missing_server_handler, user_data: ?*anyopaque) void;
extern fn uws_filter(ssl: i32, app: *uws_app_t, handler: uws_filter_handler, user_data: ?*anyopaque) void;
extern fn uws_ws(ssl: i32, app: *uws_app_t, ctx: *anyopaque, pattern: [*]const u8, pattern_len: usize, id: usize, behavior: *const WebSocketBehavior) void;

extern fn uws_ws_get_user_data(ssl: i32, ws: ?*RawWebSocket) ?*anyopaque;
extern fn uws_ws_close(ssl: i32, ws: ?*RawWebSocket) void;
extern fn uws_ws_send(ssl: i32, ws: ?*RawWebSocket, message: [*c]const u8, length: usize, opcode: Opcode) SendStatus;
extern fn uws_ws_send_with_options(ssl: i32, ws: ?*RawWebSocket, message: [*c]const u8, length: usize, opcode: Opcode, compress: bool, fin: bool) SendStatus;
extern fn uws_ws_send_fragment(ssl: i32, ws: ?*RawWebSocket, message: [*c]const u8, length: usize, compress: bool) SendStatus;
extern fn uws_ws_send_first_fragment(ssl: i32, ws: ?*RawWebSocket, message: [*c]const u8, length: usize, compress: bool) SendStatus;
extern fn uws_ws_send_first_fragment_with_opcode(ssl: i32, ws: ?*RawWebSocket, message: [*c]const u8, length: usize, opcode: Opcode, compress: bool) SendStatus;
extern fn uws_ws_send_last_fragment(ssl: i32, ws: ?*RawWebSocket, message: [*c]const u8, length: usize, compress: bool) SendStatus;
extern fn uws_ws_end(ssl: i32, ws: ?*RawWebSocket, code: i32, message: [*c]const u8, length: usize) void;
extern fn uws_ws_cork(ssl: i32, ws: ?*RawWebSocket, handler: ?*const fn (?*anyopaque) callconv(.C) void, user_data: ?*anyopaque) void;
extern fn uws_ws_subscribe(ssl: i32, ws: ?*RawWebSocket, topic: [*c]const u8, length: usize) bool;
extern fn uws_ws_unsubscribe(ssl: i32, ws: ?*RawWebSocket, topic: [*c]const u8, length: usize) bool;
extern fn uws_ws_is_subscribed(ssl: i32, ws: ?*RawWebSocket, topic: [*c]const u8, length: usize) bool;
extern fn uws_ws_iterate_topics(ssl: i32, ws: ?*RawWebSocket, callback: ?*const fn ([*c]const u8, usize, ?*anyopaque) callconv(.C) void, user_data: ?*anyopaque) void;
extern fn uws_ws_publish(ssl: i32, ws: ?*RawWebSocket, topic: [*c]const u8, topic_length: usize, message: [*c]const u8, message_length: usize) bool;
extern fn uws_ws_publish_with_options(ssl: i32, ws: ?*RawWebSocket, topic: [*c]const u8, topic_length: usize, message: [*c]const u8, message_length: usize, opcode: Opcode, compress: bool) bool;
extern fn uws_ws_get_buffered_amount(ssl: i32, ws: ?*RawWebSocket) c_uint;
extern fn uws_ws_get_remote_address(ssl: i32, ws: ?*RawWebSocket, dest: *[*]u8) usize;
extern fn uws_ws_get_remote_address_as_text(ssl: i32, ws: ?*RawWebSocket, dest: *[*]u8) usize;
extern fn uws_res_get_remote_address_info(res: *uws_res, dest: *[*]const u8, port: *i32, is_ipv6: *bool) usize;

const uws_res = opaque {};
extern fn uws_res_uncork(ssl: i32, res: *uws_res) void;
extern fn uws_res_end(ssl: i32, res: *uws_res, data: [*c]const u8, length: usize, close_connection: bool) void;
extern fn uws_res_try_end(
    ssl: i32,
    res: *uws_res,
    data: [*c]const u8,
    length: usize,
    total: usize,
    close: bool,
) bool;
extern fn uws_res_pause(ssl: i32, res: *uws_res) void;
extern fn uws_res_resume(ssl: i32, res: *uws_res) void;
extern fn uws_res_write_continue(ssl: i32, res: *uws_res) void;
extern fn uws_res_write_status(ssl: i32, res: *uws_res, status: [*c]const u8, length: usize) void;
extern fn uws_res_write_header(ssl: i32, res: *uws_res, key: [*c]const u8, key_length: usize, value: [*c]const u8, value_length: usize) void;
extern fn uws_res_write_header_int(ssl: i32, res: *uws_res, key: [*c]const u8, key_length: usize, value: u64) void;
extern fn uws_res_end_without_body(ssl: i32, res: *uws_res, close_connection: bool) void;
extern fn uws_res_write(ssl: i32, res: *uws_res, data: [*c]const u8, length: usize) bool;
extern fn uws_res_get_write_offset(ssl: i32, res: *uws_res) u64;
extern fn uws_res_override_write_offset(ssl: i32, res: *uws_res, u64) void;
extern fn uws_res_has_responded(ssl: i32, res: *uws_res) bool;
extern fn uws_res_on_writable(ssl: i32, res: *uws_res, handler: ?*const fn (*uws_res, u64, ?*anyopaque) callconv(.C) bool, user_data: ?*anyopaque) void;
extern fn uws_res_clear_on_writable(ssl: i32, res: *uws_res) void;
extern fn uws_res_on_aborted(ssl: i32, res: *uws_res, handler: ?*const fn (*uws_res, ?*anyopaque) callconv(.C) void, opcional_data: ?*anyopaque) void;
extern fn uws_res_on_data(
    ssl: i32,
    res: *uws_res,
    handler: ?*const fn (*uws_res, [*c]const u8, usize, bool, ?*anyopaque) callconv(.C) void,
    opcional_data: ?*anyopaque,
) void;
extern fn uws_res_upgrade(
    ssl: i32,
    res: *uws_res,
    data: ?*anyopaque,
    sec_web_socket_key: [*c]const u8,
    sec_web_socket_key_length: usize,
    sec_web_socket_protocol: [*c]const u8,
    sec_web_socket_protocol_length: usize,
    sec_web_socket_extensions: [*c]const u8,
    sec_web_socket_extensions_length: usize,
    ws: ?*uws_socket_context_t,
) void;
extern fn uws_res_cork(i32, res: *uws_res, ctx: *anyopaque, corker: *const (fn (?*anyopaque) callconv(.C) void)) void;
extern fn uws_res_write_headers(i32, res: *uws_res, names: [*]const Api.StringPointer, values: [*]const Api.StringPointer, count: usize, buf: [*]const u8) void;
pub const LIBUS_RECV_BUFFER_LENGTH = 524288;
pub const LIBUS_TIMEOUT_GRANULARITY = @as(i32, 4);
pub const LIBUS_RECV_BUFFER_PADDING = @as(i32, 32);
pub const LIBUS_EXT_ALIGNMENT = @as(i32, 16);
pub const LIBUS_SOCKET_DESCRIPTOR = std.os.socket_t;

pub const _COMPRESSOR_MASK: i32 = 255;
pub const _DECOMPRESSOR_MASK: i32 = 3840;
pub const DISABLED: i32 = 0;
pub const SHARED_COMPRESSOR: i32 = 1;
pub const SHARED_DECOMPRESSOR: i32 = 256;
pub const DEDICATED_DECOMPRESSOR_32KB: i32 = 3840;
pub const DEDICATED_DECOMPRESSOR_16KB: i32 = 3584;
pub const DEDICATED_DECOMPRESSOR_8KB: i32 = 3328;
pub const DEDICATED_DECOMPRESSOR_4KB: i32 = 3072;
pub const DEDICATED_DECOMPRESSOR_2KB: i32 = 2816;
pub const DEDICATED_DECOMPRESSOR_1KB: i32 = 2560;
pub const DEDICATED_DECOMPRESSOR_512B: i32 = 2304;
pub const DEDICATED_DECOMPRESSOR: i32 = 3840;
pub const DEDICATED_COMPRESSOR_3KB: i32 = 145;
pub const DEDICATED_COMPRESSOR_4KB: i32 = 146;
pub const DEDICATED_COMPRESSOR_8KB: i32 = 163;
pub const DEDICATED_COMPRESSOR_16KB: i32 = 180;
pub const DEDICATED_COMPRESSOR_32KB: i32 = 197;
pub const DEDICATED_COMPRESSOR_64KB: i32 = 214;
pub const DEDICATED_COMPRESSOR_128KB: i32 = 231;
pub const DEDICATED_COMPRESSOR_256KB: i32 = 248;
pub const DEDICATED_COMPRESSOR: i32 = 248;
pub const uws_compress_options_t = i32;
pub const CONTINUATION: i32 = 0;
pub const TEXT: i32 = 1;
pub const BINARY: i32 = 2;
pub const CLOSE: i32 = 8;
pub const PING: i32 = 9;
pub const PONG: i32 = 10;

pub const Opcode = enum(i32) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

pub const SendStatus = enum(c_uint) {
    backpressure = 0,
    success = 1,
    dropped = 2,
};
pub const uws_app_listen_config_t = extern struct {
    port: i32,
    host: [*c]const u8 = null,
    options: i32,
};

extern fn us_socket_mark_needs_more_not_ssl(socket: ?*uws_res) void;

extern fn uws_res_state(ssl: c_int, res: *const uws_res) State;

pub const State = enum(i32) {
    HTTP_STATUS_CALLED = 1,
    HTTP_WRITE_CALLED = 2,
    HTTP_END_CALLED = 4,
    HTTP_RESPONSE_PENDING = 8,
    HTTP_CONNECTION_CLOSE = 16,

    _,

    pub inline fn isResponsePending(this: State) bool {
        return @intFromEnum(this) & @intFromEnum(State.HTTP_RESPONSE_PENDING) != 0;
    }

    pub inline fn isHttpEndCalled(this: State) bool {
        return @intFromEnum(this) & @intFromEnum(State.HTTP_END_CALLED) != 0;
    }

    pub inline fn isHttpWriteCalled(this: State) bool {
        return @intFromEnum(this) & @intFromEnum(State.HTTP_WRITE_CALLED) != 0;
    }

    pub inline fn isHttpStatusCalled(this: State) bool {
        return @intFromEnum(this) & @intFromEnum(State.HTTP_STATUS_CALLED) != 0;
    }

    pub inline fn isHttpConnectionClose(this: State) bool {
        return @intFromEnum(this) & @intFromEnum(State.HTTP_CONNECTION_CLOSE) != 0;
    }
};

extern fn us_socket_sendfile_needs_more(socket: *Socket) void;

extern fn uws_app_listen_domain_with_options(
    ssl_flag: c_int,
    app: *uws_app_t,
    domain: [*:0]const u8,
    pathlen: usize,
    i32,
    *const (fn (*ListenSocket, domain: [*:0]const u8, i32, *anyopaque) callconv(.C) void),
    ?*anyopaque,
) void;

/// This extends off of uws::Loop on Windows
pub const WindowsLoop = extern struct {
    const uv = bun.windows.libuv;

    internal_loop_data: InternalLoopData align(16),

    uv_loop: *uv.Loop,
    is_default: c_int,
    pre: *uv.uv_prepare_t,
    check: *uv.uv_check_t,

    pub fn get() *WindowsLoop {
        return uws_get_loop_with_native(bun.windows.libuv.Loop.get());
    }

    extern fn uws_get_loop_with_native(*anyopaque) *WindowsLoop;

    pub fn iterationNumber(this: *const WindowsLoop) c_longlong {
        return this.internal_loop_data.iteration_nr;
    }

    pub fn addActive(this: *const WindowsLoop, val: u32) void {
        this.uv_loop.addActive(val);
    }

    pub fn subActive(this: *const WindowsLoop, val: u32) void {
        this.uv_loop.subActive(val);
    }

    pub fn isActive(this: *const WindowsLoop) bool {
        return this.uv_loop.isActive();
    }

    pub fn wakeup(this: *WindowsLoop) void {
        us_wakeup_loop(this);
    }

    pub const wake = wakeup;

    pub fn tickWithTimeout(this: *WindowsLoop, _: i64) void {
        us_loop_run(this);
    }

    pub fn tickWithoutIdle(this: *WindowsLoop) void {
        us_loop_pump(this);
    }

    pub fn create(comptime Handler: anytype) *WindowsLoop {
        return us_create_loop(
            null,
            Handler.wakeup,
            if (@hasDecl(Handler, "pre")) Handler.pre else null,
            if (@hasDecl(Handler, "post")) Handler.post else null,
            0,
        ).?;
    }

    pub fn run(this: *WindowsLoop) void {
        us_loop_run(this);
    }

    // TODO: remove these two aliases
    pub const tick = run;
    pub const wait = run;

    pub fn inc(this: *WindowsLoop) void {
        this.uv_loop.inc();
    }

    pub fn dec(this: *WindowsLoop) void {
        this.uv_loop.dec();
    }

    pub const ref = inc;
    pub const unref = dec;

    pub fn nextTick(this: *Loop, comptime UserType: type, user_data: UserType, comptime deferCallback: fn (ctx: UserType) void) void {
        const Handler = struct {
            pub fn callback(data: *anyopaque) callconv(.C) void {
                deferCallback(@as(UserType, @ptrCast(@alignCast(data))));
            }
        };
        uws_loop_defer(this, user_data, Handler.callback);
    }

    fn NewHandler(comptime UserType: type, comptime callback_fn: fn (UserType) void) type {
        return struct {
            loop: *Loop,
            pub fn removePost(handler: @This()) void {
                return uws_loop_removePostHandler(handler.loop, callback);
            }
            pub fn removePre(handler: @This()) void {
                return uws_loop_removePostHandler(handler.loop, callback);
            }
            pub fn callback(data: *anyopaque, _: *Loop) callconv(.C) void {
                callback_fn(@as(UserType, @ptrCast(@alignCast(data))));
            }
        };
    }
};

pub const Loop = if (bun.Environment.isWindows) WindowsLoop else PosixLoop;

extern fn uws_get_loop() *Loop;
extern fn us_create_loop(
    hint: ?*anyopaque,
    wakeup_cb: ?*const fn (*Loop) callconv(.C) void,
    pre_cb: ?*const fn (*Loop) callconv(.C) void,
    post_cb: ?*const fn (*Loop) callconv(.C) void,
    ext_size: c_uint,
) ?*Loop;
extern fn us_loop_free(loop: ?*Loop) void;
extern fn us_loop_ext(loop: ?*Loop) ?*anyopaque;
extern fn us_loop_run(loop: ?*Loop) void;
extern fn us_loop_pump(loop: ?*Loop) void;
extern fn us_wakeup_loop(loop: ?*Loop) void;
extern fn us_loop_integrate(loop: ?*Loop) void;
extern fn us_loop_iteration_number(loop: ?*Loop) c_longlong;
extern fn uws_loop_addPostHandler(loop: *Loop, ctx: *anyopaque, cb: *const (fn (ctx: *anyopaque, loop: *Loop) callconv(.C) void)) void;
extern fn uws_loop_removePostHandler(loop: *Loop, ctx: *anyopaque, cb: *const (fn (ctx: *anyopaque, loop: *Loop) callconv(.C) void)) void;
extern fn uws_loop_addPreHandler(loop: *Loop, ctx: *anyopaque, cb: *const (fn (ctx: *anyopaque, loop: *Loop) callconv(.C) void)) void;
extern fn uws_loop_removePreHandler(loop: *Loop, ctx: *anyopaque, cb: *const (fn (ctx: *anyopaque, loop: *Loop) callconv(.C) void)) void;
extern fn us_socket_pair(
    ctx: *SocketContext,
    ext_size: c_int,
    fds: *[2]LIBUS_SOCKET_DESCRIPTOR,
) ?*Socket;

pub extern fn us_socket_from_fd(
    ctx: *SocketContext,
    ext_size: c_int,
    fd: LIBUS_SOCKET_DESCRIPTOR,
) ?*Socket;

pub fn newSocketFromPair(ctx: *SocketContext, ext_size: c_int, fds: *[2]LIBUS_SOCKET_DESCRIPTOR) ?SocketTCP {
    return SocketTCP{
        .socket = us_socket_pair(ctx, ext_size, fds) orelse return null,
    };
}

extern fn us_socket_get_error(ssl_flag: c_int, socket: *Socket) c_int;

pub const udp = struct {
    pub const Socket = opaque {
        const This = @This();

        pub fn create(loop: *Loop, data_cb: *const fn (*This, *PacketBuffer, c_int) callconv(.C) void, drain_cb: *const fn (*This) callconv(.C) void, close_cb: *const fn (*This) callconv(.C) void, host: [*c]const u8, port: c_ushort, user_data: ?*anyopaque) ?*This {
            return us_create_udp_socket(loop, data_cb, drain_cb, close_cb, host, port, user_data);
        }

        pub fn send(this: *This, payloads: []const [*]const u8, lengths: []const usize, addresses: []const ?*const anyopaque) c_int {
            bun.assert(payloads.len == lengths.len and payloads.len == addresses.len);
            return us_udp_socket_send(this, payloads.ptr, lengths.ptr, addresses.ptr, @intCast(payloads.len));
        }

        pub fn user(this: *This) ?*anyopaque {
            return us_udp_socket_user(this);
        }

        pub fn bind(this: *This, hostname: [*c]const u8, port: c_uint) c_int {
            return us_udp_socket_bind(this, hostname, port);
        }

        pub fn boundPort(this: *This) c_int {
            return us_udp_socket_bound_port(this);
        }

        pub fn boundIp(this: *This, buf: [*c]u8, length: *i32) void {
            return us_udp_socket_bound_ip(this, buf, length);
        }

        pub fn remoteIp(this: *This, buf: [*c]u8, length: *i32) void {
            return us_udp_socket_remote_ip(this, buf, length);
        }

        pub fn close(this: *This) void {
            return us_udp_socket_close(this);
        }

        pub fn connect(this: *This, hostname: [*c]const u8, port: c_uint) c_int {
            return us_udp_socket_connect(this, hostname, port);
        }

        pub fn disconnect(this: *This) c_int {
            return us_udp_socket_disconnect(this);
        }
    };

    extern fn us_create_udp_socket(loop: ?*Loop, data_cb: *const fn (*udp.Socket, *PacketBuffer, c_int) callconv(.C) void, drain_cb: *const fn (*udp.Socket) callconv(.C) void, close_cb: *const fn (*udp.Socket) callconv(.C) void, host: [*c]const u8, port: c_ushort, user_data: ?*anyopaque) ?*udp.Socket;
    extern fn us_udp_socket_connect(socket: ?*udp.Socket, hostname: [*c]const u8, port: c_uint) c_int;
    extern fn us_udp_socket_disconnect(socket: ?*udp.Socket) c_int;
    extern fn us_udp_socket_send(socket: ?*udp.Socket, [*c]const [*c]const u8, [*c]const usize, [*c]const ?*const anyopaque, c_int) c_int;
    extern fn us_udp_socket_user(socket: ?*udp.Socket) ?*anyopaque;
    extern fn us_udp_socket_bind(socket: ?*udp.Socket, hostname: [*c]const u8, port: c_uint) c_int;
    extern fn us_udp_socket_bound_port(socket: ?*udp.Socket) c_int;
    extern fn us_udp_socket_bound_ip(socket: ?*udp.Socket, buf: [*c]u8, length: [*c]i32) void;
    extern fn us_udp_socket_remote_ip(socket: ?*udp.Socket, buf: [*c]u8, length: [*c]i32) void;
    extern fn us_udp_socket_close(socket: ?*udp.Socket) void;

    pub const PacketBuffer = opaque {
        const This = @This();

        pub fn getPeer(this: *This, index: c_int) *std.os.sockaddr.storage {
            return us_udp_packet_buffer_peer(this, index);
        }

        pub fn getPayload(this: *This, index: c_int) []u8 {
            const payload = us_udp_packet_buffer_payload(this, index);
            const len = us_udp_packet_buffer_payload_length(this, index);
            return payload[0..@as(usize, @intCast(len))];
        }
    };

    extern fn us_udp_packet_buffer_peer(buf: ?*PacketBuffer, index: c_int) *std.os.sockaddr.storage;
    extern fn us_udp_packet_buffer_payload(buf: ?*PacketBuffer, index: c_int) [*]u8;
    extern fn us_udp_packet_buffer_payload_length(buf: ?*PacketBuffer, index: c_int) c_int;
};
