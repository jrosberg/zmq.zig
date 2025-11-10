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

    std.debug.print("=== ZeroMQ PUB Server Example ===\n", .{});

    // Create context
    const ctx = try zmq.Context.init(allocator);
    defer ctx.deinit();

    // Create PUB socket
    const sock = try ctx.socket(.PUB);
    defer sock.close();

    // Bind to endpoint (server mode)
    std.debug.print("Binding to tcp://*:5555...\n", .{});
    try sock.bind("tcp://*:5555");

    // Give subscribers time to connect and send subscriptions
    std.debug.print("Waiting for subscribers to connect...\n", .{});
    std.Thread.sleep(1000 * std.time.ns_per_ms);

    std.debug.print("\nPublishing messages...\n\n", .{});

    // Publish messages in a loop
    var count: usize = 0;
    while (count < 100) : (count += 1) {
        // Create messages with different topics
        var message_buf: [256]u8 = undefined;

        // Send weather update
        const weather_msg = try std.fmt.bufPrint(&message_buf, "weather Temperature: {d}°C", .{20 + @mod(count, 10)});
        sock.send(weather_msg, .{}) catch |err| {
            std.debug.print("Error sending: {}\n", .{err});
            continue;
        };
        std.debug.print("[{d}] Published: {s}\n", .{ count * 2, weather_msg });

        // Small delay
        std.Thread.sleep(500 * std.time.ns_per_ms);

        // Send news update
        const news_msg = try std.fmt.bufPrint(&message_buf, "news Breaking news #{d}", .{count});
        try sock.send(news_msg, .{});
        std.debug.print("[{d}] Published: {s}\n", .{ count * 2 + 1, news_msg });

        // Sleep between messages
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }

    std.debug.print("\nPublishing complete!\n", .{});
}
