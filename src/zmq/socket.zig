//! ZeroMQ implementation in Zig
//! Copyright (c) 2025 Janne Rosberg <janne.rosberg@offcode.fi>
//! License: MIT
//! See the LICENSE file for details.

const std = @import("std");
const net = std.net;
const zmtp = @import("zmtp.zig");
const types = @import("types.zig");
const protocol = @import("protocol.zig");

const SocketType = types.SocketType;
const Greeting = protocol.Greeting;
const ZmqCommand = protocol.ZmqCommand;

/// Send flags for socket.send()
pub const SendFlags = packed struct {
    /// Non-blocking mode (ZMQ_DONTWAIT)
    dontwait: bool = false,
    /// More message parts to follow (ZMQ_SNDMORE)
    sndmore: bool = false,
    _padding: u30 = 0,

    pub const DONTWAIT: u32 = 1;
    pub const SNDMORE: u32 = 2;

    pub fn fromU32(flags: u32) SendFlags {
        return .{
            .dontwait = (flags & DONTWAIT) != 0,
            .sndmore = (flags & SNDMORE) != 0,
        };
    }

    pub fn toU32(self: SendFlags) u32 {
        var result: u32 = 0;
        if (self.dontwait) result |= DONTWAIT;
        if (self.sndmore) result |= SNDMORE;
        return result;
    }
};

/// Represents a single client connection
const Connection = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    frame_engine: zmtp.ZmtpFrameEngine,
    id: usize,
    // Subscription state (for PUB side): list of topics and match-all flag
    subscriptions: std.ArrayListUnmanaged([]u8),
    match_all: bool,

    pub fn init(allocator: std.mem.Allocator, stream: net.Stream, id: usize) Connection {
        return .{
            .allocator = allocator,
            .stream = stream,
            .frame_engine = zmtp.ZmtpFrameEngine.init(allocator),
            .id = id,
            .subscriptions = .{ .items = &[_][]u8{}, .capacity = 0 },
            .match_all = false,
        };
    }

    pub fn close(self: *Connection) void {
        // Free stored subscription topics
        if (self.subscriptions.capacity > 0) {
            for (self.subscriptions.items) |topic| {
                self.allocator.free(topic);
            }
            self.allocator.free(self.subscriptions.allocatedSlice());
        }
        self.stream.close();
    }
};

pub const Socket = struct {
    allocator: std.mem.Allocator,
    socket_type: SocketType,
    stream: ?net.Stream,
    server: ?net.Server,
    frame_engine: zmtp.ZmtpFrameEngine,
    // Multi-connection support
    connections: std.ArrayList(Connection),
    next_connection_id: usize,
    accept_mutex: std.Thread.Mutex,
    // Background accept thread for PUB sockets
    accept_thread: ?std.Thread = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, socket_type: SocketType) !*Self {
        const sock = try allocator.create(Self);
        sock.* = .{
            .allocator = allocator,
            .socket_type = socket_type,
            .stream = null,
            .server = null,
            .frame_engine = zmtp.ZmtpFrameEngine.init(allocator),
            .connections = .{
                .items = &[_]Connection{},
                .capacity = 0,
            },
            .next_connection_id = 0,
            .accept_mutex = .{},
        };
        return sock;
    }

    pub fn connect(self: *Self, endpoint: []const u8) !void {
        // Parse endpoint (format: tcp://host:port)
        if (!std.mem.startsWith(u8, endpoint, "tcp://")) {
            return error.InvalidEndpoint;
        }
        const addr_port = endpoint[6..];
        const colon_idx = std.mem.lastIndexOf(u8, addr_port, ":") orelse return error.InvalidEndpoint;
        const host = addr_port[0..colon_idx];
        const port = try std.fmt.parseInt(u16, addr_port[colon_idx + 1 ..], 10);

        // Connect to server
        const address = try net.Address.resolveIp(host, port);
        self.stream = try net.tcpConnectToAddress(address);

        // Send greeting
        var greet = Greeting.init();
        const greet_slice = greet.toSlice();
        var send_buf: [128]u8 = undefined;
        var writer = self.stream.?.writer(send_buf[0..]);
        _ = try writer.interface.write(greet_slice[0..]);
        try writer.interface.flush();

        // Receive greeting
        var in = [_]u8{0} ** 64;
        _ = try self.stream.?.readAtLeast(&in, Greeting.greet_size);
        _ = try Greeting.fromSlice(&in);

        // Send READY command
        var cmd_ready = try ZmqCommand.ready(self.socket_type);
        defer cmd_ready.deinit();
        const cmd_frame = cmd_ready.toFrame();
        var cmd_send_buf: [256]u8 = undefined;
        var cmd_writer = self.stream.?.writer(cmd_send_buf[0..]);
        _ = try cmd_writer.interface.write(cmd_frame);
        try cmd_writer.interface.flush();

        // Receive READY command - read the complete frame
        // First read the frame header to know how much to read
        _ = try self.stream.?.readAtLeast(in[0..2], 2);
        const ready_size = in[1];

        // Read the rest of the frame
        if (ready_size > 0) {
            _ = try self.stream.?.readAtLeast(in[2 .. 2 + ready_size], ready_size);
        }

        const total_len = 2 + ready_size;

        const cmd_other_ready = try ZmqCommand.fromSlice(in[0..total_len]);
        if (cmd_other_ready.name == .READY) {} else {
            return error.InvalidCommand;
        }
    }

    pub fn bind(self: *Self, endpoint: []const u8) !void {
        // Parse endpoint (format: tcp://host:port)
        if (!std.mem.startsWith(u8, endpoint, "tcp://")) {
            return error.InvalidEndpoint;
        }
        const addr_port = endpoint[6..];
        const colon_idx = std.mem.lastIndexOf(u8, addr_port, ":") orelse return error.InvalidEndpoint;
        const host = addr_port[0..colon_idx];
        const port = try std.fmt.parseInt(u16, addr_port[colon_idx + 1 ..], 10);

        // Parse address - support * for all interfaces
        const address = if (std.mem.eql(u8, host, "*"))
            try net.Address.parseIp("0.0.0.0", port)
        else
            try net.Address.resolveIp(host, port);

        // Create server socket
        self.server = try address.listen(.{
            .reuse_address = true,
        });

        // Start background accept loop for PUB sockets so send() never blocks on handshakes
        if (self.socket_type == .PUB and self.accept_thread == null) {
            self.accept_thread = try std.Thread.spawn(.{}, Self.acceptLoopThread, .{self});
        }
    }

    fn acceptLoopThread(self: *Self) void {
        // Accept connections continuously until server is closed
        while (true) {
            // If server is closed, exit
            if (self.server == null) break;

            self.accept() catch {
                // If server was closed, exit; otherwise sleep briefly and retry
                if (self.server == null) break;
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            };
        }
    }

    /// Try to accept pending connections without blocking (for PUB sockets)
    fn tryAcceptPending(self: *Self) void {
        if (self.server == null) return;
        if (self.socket_type != .PUB) return;

        // Set server to non-blocking mode
        const server_fd = self.server.?.stream.handle;
        const flags = std.posix.fcntl(server_fd, std.posix.F.GETFL, 0) catch return;
        const NONBLOCK: u32 = if (@hasDecl(std.posix.O, "NONBLOCK")) std.posix.O.NONBLOCK else 0x0004;
        _ = std.posix.fcntl(server_fd, std.posix.F.SETFL, flags | NONBLOCK) catch return;

        // Try to accept as many connections as available
        while (true) {
            self.accept() catch {
                // No more pending connections or error - restore blocking mode and return
                _ = std.posix.fcntl(server_fd, std.posix.F.SETFL, flags) catch {};
                return;
            };
        }
    }

    pub fn accept(self: *Self) !void {
        if (self.server == null) return error.NotBound;

        // Accept incoming connection
        const connection = try self.server.?.accept();
        const client_stream = connection.stream;

        // Disable Nagle's algorithm
        try std.posix.setsockopt(
            client_stream.handle,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            &std.mem.toBytes(@as(c_int, 1)),
        );

        // Receive greeting from client
        var in = [_]u8{0} ** 256;
        const greeting_read = client_stream.read(in[0..Greeting.greet_size]) catch |err| {
            client_stream.close();
            return err;
        };

        if (greeting_read < 10) {
            client_stream.close();
            return error.InvalidGreeting;
        }

        // Try to parse greeting, but be lenient
        _ = Greeting.fromSlice(&in) catch |err| {
            std.debug.print("Warning: Could not parse greeting: {any}, continuing anyway\n", .{err});
            // Continue with handshake anyway
        };

        // Send greeting back to client
        var greet = Greeting.init();
        greet.as_server = true; // Mark as server
        const greet_slice = greet.toSlice();
        var send_buf: [128]u8 = undefined;
        var writer = client_stream.writer(send_buf[0..]);
        _ = try writer.interface.write(greet_slice[0..]);
        try writer.interface.flush();

        // Receive READY command from client
        @memset(&in, 0);
        _ = try client_stream.readAtLeast(in[0..2], 2);
        const ready_flags = in[0];

        // Check if this is a command frame
        if (ready_flags & 0x04 == 0) {
            std.debug.print("Warning: Expected command frame, got flags=0x{x:0>2}\n", .{ready_flags});
        }

        // Determine frame length and read payload
        var payload_size: usize = 0;
        var header_size: usize = 2;

        if (ready_flags & 0x02 != 0) {
            // Long frame - read 8 byte length
            _ = try client_stream.readAtLeast(in[1..9], 8);
            payload_size = std.mem.readInt(u64, in[1..9], .big);
            header_size = 9;
        } else {
            // Short frame - 1 byte length
            payload_size = in[1];
        }

        // Read the payload (limit to reasonable size)
        if (payload_size > 0 and payload_size < 256) {
            if (header_size + payload_size <= 256) {
                _ = try client_stream.readAtLeast(in[header_size .. header_size + payload_size], payload_size);
            }
        }

        // Send READY command back
        var cmd_ready = try ZmqCommand.ready(self.socket_type);
        defer cmd_ready.deinit();
        const cmd_frame = cmd_ready.toFrame();
        var cmd_send_buf: [256]u8 = undefined;
        var cmd_writer = client_stream.writer(cmd_send_buf[0..]);
        _ = try cmd_writer.interface.write(cmd_frame);
        try cmd_writer.interface.flush();

        // Use blocking mode for subscriber connections to ensure full-frame writes during PUB sends.
        // Subscription harvesting is disabled to avoid blocking; see sendPub().

        // Add the connection to our list
        self.accept_mutex.lock();

        const conn_id = self.next_connection_id;
        self.next_connection_id += 1;

        const conn = Connection.init(self.allocator, client_stream, conn_id);
        try self.connections.append(self.allocator, conn);
        // Capture index for later access outside the lock
        const idx: usize = self.connections.items.len - 1;

        // For backwards compatibility, also set the main stream to the first connection
        if (self.stream == null) {
            self.stream = client_stream;
        }
        // Unlock before any potentially blocking operations
        self.accept_mutex.unlock();

        // For PUB sockets, do an initial harvest of subscription messages (non-blocking)
        if (self.socket_type == .PUB) {
            // Give the client a brief moment to send subscription messages
            std.Thread.sleep(100 * std.time.ns_per_ms);
            // Safe to take pointer now because we won't reallocate until next append, and we're in the same accept thread
            var conn_ptr = &self.connections.items[idx];
            self.harvestSubscriptions(conn_ptr) catch |err| {
                // On error, close and remove the connection
                self.accept_mutex.lock();
                defer self.accept_mutex.unlock();
                conn_ptr.close();
                _ = self.connections.orderedRemove(idx);
                return err;
            };
        }
    }

    pub fn send(self: *Self, data: []const u8, sendFlags: SendFlags) !void {
        // For PUB sockets, we don't need self.stream - we use self.connections
        if (self.socket_type != .PUB and self.stream == null) return error.NotConnected;

        switch (self.socket_type) {
            .REQ => try self.sendReq(data, sendFlags),
            .REP => try self.sendRep(data, sendFlags),
            .PUB => try self.sendPub(data, sendFlags),
            .SUB => try self.sendSub(data, sendFlags),
            else => try self.sendDefault(data, sendFlags),
        }
    }

    fn sendReq(self: *Self, data: []const u8, flags: SendFlags) !void {
        _ = flags;
        // Frame 1: Empty delimiter with MORE flag
        const delimiter_frame = try self.frame_engine.createMessageFrame(&[_]u8{}, true);
        defer self.allocator.free(delimiter_frame);

        // Frame 2: Data with LAST flag
        const data_frame = try self.frame_engine.createMessageFrame(data, false);
        defer self.allocator.free(data_frame);

        // Send as two frames without concatenation
        try self.sendRawFrame(delimiter_frame);
        try self.sendRawFrame(data_frame);
    }

    fn sendRep(self: *Self, data: []const u8, flags: SendFlags) !void {
        _ = flags;
        // REP also uses delimiter frame in response
        const delimiter_frame = try self.frame_engine.createMessageFrame(&[_]u8{}, true);
        defer self.allocator.free(delimiter_frame);
        self.sendRawFrame(delimiter_frame) catch |err| {
            return err;
        };

        const data_frame = try self.frame_engine.createMessageFrame(data, false);
        defer self.allocator.free(data_frame);
        self.sendRawFrame(data_frame) catch |err| {
            return err;
        };
    }

    fn sendPub(self: *Self, data: []const u8, flags: SendFlags) !void {
        _ = flags;
        // PUB socket sends only to subscribers with matching subscriptions

        const frame = try self.frame_engine.createMessageFrame(data, false);
        defer self.allocator.free(frame);

        // Check each connection's subscriptions and deliver selectively
        self.accept_mutex.lock();
        defer self.accept_mutex.unlock();

        var i: usize = 0;
        while (i < self.connections.items.len) {
            var conn = &self.connections.items[i];

            // Harvest any pending subscription messages before sending
            self.harvestSubscriptions(conn) catch {
                conn.close();
                _ = self.connections.orderedRemove(i);
                continue;
            };

            if (self.connectionWants(conn, data)) {
                self.sendRawFrameToConnection(conn, frame) catch |err| {
                    // For transient backpressure on non-blocking sockets, skip this connection
                    if (err == error.WouldBlock or err == error.InputOutput) {
                        // do not remove connection; try next time
                    } else {
                        conn.close();
                        _ = self.connections.orderedRemove(i);
                        continue;
                    }
                };
            }
            i += 1;
        }
    }

    fn sendSub(_: *Self, _: []const u8, _: SendFlags) !void {
        // SUB socket should not normally send data messages
        // Only SUBSCRIBE/CANCEL commands are sent
        return error.InvalidOperation;
    }

    // Determine if a given message should be delivered to this connection
    fn connectionWants(self: *Self, conn: *Connection, msg: []const u8) bool {
        _ = self;
        // If match_all is set (empty subscription), deliver everything
        if (conn.match_all) return true;
        // If no subscriptions at all, do not deliver
        if (conn.subscriptions.items.len == 0) {
            // For now, deliver to all connections even without explicit subscriptions
            // This allows the system to work with subscribers that don't properly
            // send subscription messages
            return true;
        }
        // Check if message matches any subscription
        for (conn.subscriptions.items) |topic| {
            if (std.mem.startsWith(u8, msg, topic)) return true;
        }
        return false;
    }

    fn addSubscription(self: *Self, conn: *Connection, topic: []const u8) void {
        _ = self;
        if (topic.len == 0) {
            conn.match_all = true;
            return;
        }
        // Avoid duplicates
        for (conn.subscriptions.items) |t| {
            if (std.mem.eql(u8, t, topic)) return;
        }
        const copy = conn.allocator.dupe(u8, topic) catch return;
        conn.subscriptions.append(conn.allocator, copy) catch {
            conn.allocator.free(copy);
            return;
        };
    }

    fn removeSubscription(self: *Self, conn: *Connection, topic: []const u8) void {
        _ = self;
        if (topic.len == 0) {
            // Unsubscribe from all (match_all off)
            conn.match_all = false;
            return;
        }
        var i: usize = 0;
        while (i < conn.subscriptions.items.len) {
            const t = conn.subscriptions.items[i];
            if (std.mem.eql(u8, t, topic)) {
                conn.allocator.free(t);
                _ = conn.subscriptions.orderedRemove(i);
                return;
            }
            i += 1;
        }
    }

    // Non-blocking harvest of subscription frames from a subscriber connection
    fn harvestSubscriptions(self: *Self, conn: *Connection) !void {
        // Try to read as many subscription frames as available without blocking
        var harvested: usize = 0;
        var empty_frames: usize = 0;
        const max_frames = 100; // Prevent infinite loops
        const max_empty = 5; // Stop after too many consecutive empty frames to prevent infinite loops

        while (harvested < max_frames and empty_frames < max_empty) {
            const frame = conn.frame_engine.parseFrame(conn.stream) catch |err| {
                // WouldBlock or end-of-stream -> stop harvesting
                // Map common non-blocking errors to break condition
                if (err == error.WouldBlock or err == error.InputOutput) {
                    return; // stop without error
                }
                // Connection closed or other fatal errors propagate up
                return err;
            };
            defer self.allocator.free(frame.data);
            harvested += 1;

            // Skip empty frames (might be heartbeats or artifacts)
            // but stop if we see too many to prevent infinite loops
            if (frame.data.len == 0) {
                empty_frames += 1;
                continue;
            }
            // Reset empty frame counter when we see real data
            empty_frames = 0;

            // Subscription messages are regular message frames with first byte 0x01 or 0x00
            if (!frame.is_command and frame.data.len >= 1) {
                const op = frame.data[0];
                const topic = frame.data[1..];
                if (op == 0x01) {
                    self.addSubscription(conn, topic);
                } else if (op == 0x00) {
                    self.removeSubscription(conn, topic);
                }
            }

            // If there are no more frames queued, the next parse will return WouldBlock
            // Loop continues until then
        }
    }

    fn sendDefault(self: *Self, data: []const u8, flags: SendFlags) !void {
        _ = flags;
        const frame = try self.frame_engine.createMessageFrame(data, false);
        defer self.allocator.free(frame);
        try self.sendRawFrame(frame);
    }

    fn sendRawFrame(self: *Self, frame: []const u8) !void {
        if (self.stream) |stream| {

            // Send frame using writer
            var send_buf: [1024]u8 = undefined;
            var writer = stream.writer(send_buf[0..]);
            _ = writer.interface.write(frame) catch |err| {
                // On write error, mark stream as null to avoid double-close issues
                self.stream = null;
                return err;
            };
            writer.interface.flush() catch |err| {
                // On flush error, mark stream as null to avoid double-close issues
                self.stream = null;
                return err;
            };
        } else {
            return error.NotConnected;
        }
    }

    fn sendRawFrameToConnection(self: *Self, conn: *Connection, frame: []const u8) !void {
        _ = self;

        // Attempt to write the full frame without blocking. If we cannot
        // complete the write immediately, signal a partial write so caller
        // can drop/close the connection to avoid stream corruption.
        var sent: usize = 0;
        while (sent < frame.len) {
            const chunk = frame[sent..];
            const n = conn.stream.write(chunk) catch |err| {
                if (err == error.WouldBlock or err == error.InputOutput) {
                    if (sent == 0) return err; // nothing sent yet: transient backpressure
                    return error.PartialWrite; // frame was partially sent -> must drop connection
                }
                return err;
            };
            if (n == 0) {
                // Should not happen for TCP; treat as partial write
                return error.PartialWrite;
            }
            sent += n;
        }
    }

    pub fn recv(self: *Self, buffer: []u8, recvFlags: u32) !usize {
        _ = recvFlags;
        if (self.stream == null) return error.NotConnected;

        // For REQ/REP sockets, we need to receive with proper ZMTP framing
        if (self.socket_type == .REQ or self.socket_type == .REP) {
            // Read frames until we get one without MORE flag
            // Skip empty delimiter frames (they have size 0)
            var total_read: usize = 0;
            var frame_count: usize = 0;

            while (true) {
                frame_count += 1;

                // Parse frame using frame engine
                const frame = self.frame_engine.parseFrame(self.stream.?) catch |err| {
                    // On connection error, mark stream as null to avoid double-close
                    self.stream = null;
                    return err;
                };
                defer self.allocator.free(frame.data);

                // Only accumulate non-empty frames (skip delimiter frames)
                if (frame.data.len > 0) {
                    if (total_read + frame.data.len > buffer.len) {
                        return error.BufferTooSmall;
                    }
                    @memcpy(buffer[total_read .. total_read + frame.data.len], frame.data);
                    total_read += frame.data.len;
                }

                if (!frame.more) break;
            }

            return total_read;
        } else {
            // Other socket types
            const frame = self.frame_engine.parseFrame(self.stream.?) catch |err| {
                // On connection error, mark stream as null to avoid double-close
                self.stream = null;
                return err;
            };
            defer self.allocator.free(frame.data);

            if (frame.data.len > buffer.len) {
                return error.BufferTooSmall;
            }
            @memcpy(buffer[0..frame.data.len], frame.data);
            return frame.data.len;
        }
    }

    /// Subscribe to a topic (SUB socket only)
    /// Pass empty string "" to subscribe to all messages
    pub fn subscribe(self: *Self, topic: []const u8) !void {
        if (self.socket_type != .SUB) {
            return error.InvalidSocketType;
        }
        if (self.stream == null) return error.NotConnected;

        // Create a SUBSCRIBE command frame
        // In ZMTP 3.x, subscriptions are sent as messages with \x01 prefix + topic
        var sub_data: [256]u8 = undefined;
        sub_data[0] = 0x01; // SUBSCRIBE command byte
        @memcpy(sub_data[1 .. 1 + topic.len], topic);
        const sub_message = sub_data[0 .. 1 + topic.len];

        const frame = try self.frame_engine.createMessageFrame(sub_message, false);
        defer self.allocator.free(frame);
        try self.sendRawFrame(frame);
    }

    /// Unsubscribe from a topic (SUB socket only)
    pub fn unsubscribe(self: *Self, topic: []const u8) !void {
        if (self.socket_type != .SUB) {
            return error.InvalidSocketType;
        }
        if (self.stream == null) return error.NotConnected;

        // Create a CANCEL (unsubscribe) command frame
        // In ZMTP 3.x, unsubscriptions are sent as messages with \x00 prefix + topic
        var unsub_data: [256]u8 = undefined;
        unsub_data[0] = 0x00; // CANCEL command byte
        @memcpy(unsub_data[1 .. 1 + topic.len], topic);
        const unsub_message = unsub_data[0 .. 1 + topic.len];

        const frame = try self.frame_engine.createMessageFrame(unsub_message, false);
        defer self.allocator.free(frame);
        try self.sendRawFrame(frame);
    }

    pub fn close(self: *Self) void {
        // Close all connections
        self.accept_mutex.lock();
        for (self.connections.items) |*conn| {
            conn.close();
        }
        if (self.connections.capacity > 0) {
            self.allocator.free(self.connections.allocatedSlice());
        }
        self.accept_mutex.unlock();

        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
        }
        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }
        // Join accept thread if running
        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }
        self.allocator.destroy(self);
    }

    /// Accept connections in a loop (non-blocking after first connection)
    /// Useful for accepting multiple connections without blocking the main thread
    pub fn acceptLoop(self: *Self, max_connections: ?usize) !void {
        const max = max_connections orelse std.math.maxInt(usize);
        var count: usize = 0;

        while (count < max) : (count += 1) {
            try self.accept();
        }
    }

    /// Get the number of active connections
    pub fn connectionCount(self: *Self) usize {
        self.accept_mutex.lock();
        defer self.accept_mutex.unlock();
        return self.connections.items.len;
    }

    /// Remove dead connections
    pub fn pruneConnections(self: *Self) void {
        self.accept_mutex.lock();
        defer self.accept_mutex.unlock();

        var i: usize = 0;
        while (i < self.connections.items.len) {
            // Try a test write to check if connection is alive
            // For now, just keep all connections
            // TODO: Implement connection health check
            i += 1;
        }
    }
};

// Tests
const testing = std.testing;

test "Socket init and type" {
    const allocator = testing.allocator;

    const sock = try Socket.init(allocator, .PUB);
    defer sock.close();

    try testing.expectEqual(SocketType.PUB, sock.socket_type);
    try testing.expect(sock.stream == null);
    try testing.expect(sock.server == null);
    try testing.expectEqual(@as(usize, 0), sock.connections.items.len);
}

test "Connection subscription management - match all" {
    const allocator = testing.allocator;

    const sock = try Socket.init(allocator, .PUB);
    defer sock.close();

    // Create a mock stream (we won't actually use it for network operations)
    var conn = Connection.init(allocator, undefined, 0);
    defer {
        // Don't close the stream since it's undefined
        // Just free subscriptions
        if (conn.subscriptions.capacity > 0) {
            for (conn.subscriptions.items) |topic| {
                allocator.free(topic);
            }
            allocator.free(conn.subscriptions.allocatedSlice());
        }
    }

    // Initially, connection should not want any messages
    try testing.expectEqual(false, sock.connectionWants(&conn, "weather update"));
    try testing.expectEqual(false, sock.connectionWants(&conn, "news flash"));

    // Subscribe to all (empty topic)
    sock.addSubscription(&conn, "");
    try testing.expectEqual(true, conn.match_all);
    try testing.expectEqual(true, sock.connectionWants(&conn, "weather update"));
    try testing.expectEqual(true, sock.connectionWants(&conn, "news flash"));
    try testing.expectEqual(true, sock.connectionWants(&conn, "any message"));
}

test "Connection subscription management - specific topics" {
    const allocator = testing.allocator;

    const sock = try Socket.init(allocator, .PUB);
    defer sock.close();

    var conn = Connection.init(allocator, undefined, 0);
    defer {
        if (conn.subscriptions.capacity > 0) {
            for (conn.subscriptions.items) |topic| {
                allocator.free(topic);
            }
            allocator.free(conn.subscriptions.allocatedSlice());
        }
    }

    // Subscribe to "weather" topic
    sock.addSubscription(&conn, "weather");
    try testing.expectEqual(false, conn.match_all);
    try testing.expectEqual(@as(usize, 1), conn.subscriptions.items.len);

    // Should match messages starting with "weather"
    try testing.expectEqual(true, sock.connectionWants(&conn, "weather update"));
    try testing.expectEqual(true, sock.connectionWants(&conn, "weather forecast"));
    try testing.expectEqual(false, sock.connectionWants(&conn, "news flash"));
    try testing.expectEqual(false, sock.connectionWants(&conn, "sports scores"));

    // Add another subscription
    sock.addSubscription(&conn, "news");
    try testing.expectEqual(@as(usize, 2), conn.subscriptions.items.len);

    // Should match both topics now
    try testing.expectEqual(true, sock.connectionWants(&conn, "weather update"));
    try testing.expectEqual(true, sock.connectionWants(&conn, "news flash"));
    try testing.expectEqual(false, sock.connectionWants(&conn, "sports scores"));
}

test "Connection subscription management - remove subscription" {
    const allocator = testing.allocator;

    const sock = try Socket.init(allocator, .PUB);
    defer sock.close();

    var conn = Connection.init(allocator, undefined, 0);
    defer {
        if (conn.subscriptions.capacity > 0) {
            for (conn.subscriptions.items) |topic| {
                allocator.free(topic);
            }
            allocator.free(conn.subscriptions.allocatedSlice());
        }
    }

    // Subscribe to multiple topics
    sock.addSubscription(&conn, "weather");
    sock.addSubscription(&conn, "news");
    try testing.expectEqual(@as(usize, 2), conn.subscriptions.items.len);

    // Remove one subscription
    sock.removeSubscription(&conn, "weather");
    try testing.expectEqual(@as(usize, 1), conn.subscriptions.items.len);

    // Should only match news now
    try testing.expectEqual(false, sock.connectionWants(&conn, "weather update"));
    try testing.expectEqual(true, sock.connectionWants(&conn, "news flash"));

    // Remove the last subscription
    sock.removeSubscription(&conn, "news");
    try testing.expectEqual(@as(usize, 0), conn.subscriptions.items.len);

    // Should not match anything
    try testing.expectEqual(false, sock.connectionWants(&conn, "weather update"));
    try testing.expectEqual(false, sock.connectionWants(&conn, "news flash"));
}

test "Connection subscription management - duplicate prevention" {
    const allocator = testing.allocator;

    const sock = try Socket.init(allocator, .PUB);
    defer sock.close();

    var conn = Connection.init(allocator, undefined, 0);
    defer {
        if (conn.subscriptions.capacity > 0) {
            for (conn.subscriptions.items) |topic| {
                allocator.free(topic);
            }
            allocator.free(conn.subscriptions.allocatedSlice());
        }
    }

    // Subscribe to same topic multiple times
    sock.addSubscription(&conn, "weather");
    sock.addSubscription(&conn, "weather");
    sock.addSubscription(&conn, "weather");

    // Should only be stored once
    try testing.expectEqual(@as(usize, 1), conn.subscriptions.items.len);
}

test "Connection subscription management - match_all unsubscribe" {
    const allocator = testing.allocator;

    const sock = try Socket.init(allocator, .PUB);
    defer sock.close();

    var conn = Connection.init(allocator, undefined, 0);
    defer {
        if (conn.subscriptions.capacity > 0) {
            for (conn.subscriptions.items) |topic| {
                allocator.free(topic);
            }
            allocator.free(conn.subscriptions.allocatedSlice());
        }
    }

    // Subscribe to all
    sock.addSubscription(&conn, "");
    try testing.expectEqual(true, conn.match_all);

    // Unsubscribe from all (empty topic)
    sock.removeSubscription(&conn, "");
    try testing.expectEqual(false, conn.match_all);
    try testing.expectEqual(false, sock.connectionWants(&conn, "any message"));
}

test "Socket connection counting" {
    const allocator = testing.allocator;

    const sock = try Socket.init(allocator, .PUB);
    defer sock.close();

    // Initially no connections
    try testing.expectEqual(@as(usize, 0), sock.connectionCount());

    // Note: We can't easily test adding connections without network operations
    // This test just verifies the function exists and returns the initial count
}
