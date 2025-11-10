//! ZeroMQ implementation in Zig
//! Copyright (c) 2025 Janne Rosberg <janne.rosberg@offcode.fi>
//! License: MIT
//! See the LICENSE file for details.

const std = @import("std");
const zmq = @import("zmq");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== ZeroMQ PUB Server - Multiple Connections Example ===\n", .{});

    // Create context
    const ctx = try zmq.Context.init(allocator);
    defer ctx.deinit();

    // Create PUB socket
    const sock = try ctx.socket(.PUB);
    defer sock.close();

    // Bind to endpoint (server mode)
    std.debug.print("Binding to tcp://*:5555...\n", .{});
    try sock.bind("tcp://*:5555");

    // Accept multiple subscribers
    std.debug.print("\nWaiting for subscribers to connect...\n", .{});
    std.debug.print("(New subscribers can connect at any time)\n\n", .{});

    // Socket.bind() already starts an internal accept loop for PUB sockets.
    // Just wait a bit for initial subscribers.
    std.debug.print("Waiting 3 seconds for initial subscribers...\n", .{});
    std.Thread.sleep(3 * std.time.ns_per_s);

    std.debug.print("\n=== Starting to publish messages ===\n", .{});
    std.debug.print("(New subscribers can still connect in the background)\n\n", .{});

    // Publish messages in a loop
    var count: usize = 0;
    while (count < 100) : (count += 1) {
        const conn_count = sock.connectionCount();

        if (conn_count == 0) {
            std.debug.print("[{d}] No subscribers connected, waiting...\n", .{count});
            std.Thread.sleep(1 * std.time.ns_per_s);
            continue;
        }

        // Create messages with different topics
        var message_buf: [256]u8 = undefined;

        // Send weather update
        const weather_msg = try std.fmt.bufPrint(&message_buf, "weather Temperature: {d}°C, Humidity: {d}%", .{ 20 + @mod(count, 15), 50 + @mod(count, 30) });
        try sock.send(weather_msg, .{});
        std.debug.print("[{d}] Published to {d} subscriber(s): {s}\n", .{ count * 2, conn_count, weather_msg });

        // Small delay
        std.Thread.sleep(500 * std.time.ns_per_ms);

        // Send news update
        const news_msg = try std.fmt.bufPrint(&message_buf, "news Breaking: Event #{d} just happened!", .{count});
        try sock.send(news_msg, .{});
        std.debug.print("[{d}] Published to {d} subscriber(s): {s}\n", .{ count * 2 + 1, conn_count, news_msg });

        // Send sports update occasionally
        if (@mod(count, 5) == 0) {
            const sports_msg = try std.fmt.bufPrint(&message_buf, "sports Team A vs Team B: {d}-{d}", .{ @mod(count, 10), @mod(count + 3, 10) });
            try sock.send(sports_msg, .{});
            std.debug.print("[{d}] Published to {d} subscriber(s): {s}\n", .{ count * 2 + 2, conn_count, sports_msg });
        }

        // Sleep between messages
        std.Thread.sleep(500 * std.time.ns_per_ms);

        // Show connection status every 10 iterations
        if (@mod(count, 10) == 0) {
            std.debug.print("\n--- Status: {d} active subscriber(s) connected ---\n\n", .{conn_count});
        }
    }

    std.debug.print("\n=== Publishing complete! ===\n", .{});
    std.debug.print("Final subscriber count: {d}\n", .{sock.connectionCount()});
}
