//! Transport abstraction for neighborhood.
//!
//! Provides a built-in UDP transport and the interface for custom transports.
//! The built-in transport uses std.posix for socket operations.

const std = @import("std");
const types = @import("types.zig");

const Address = types.Address;

/// Maximum UDP packet size.
pub const max_packet_size = 65535;

/// A received packet with metadata.
///
/// **Buffer lifetime:** `buf` is a slice into `UdpTransport.recv_buf`.
/// The next call to `recvFrom` **will overwrite** the buffer contents.
/// Callers must copy data before the next receive.
pub const Packet = struct {
    buf: []u8,
    from: Address,
    timestamp_ms: i64,
};

/// Built-in UDP transport — binds a socket and provides send/receive.
pub const UdpTransport = struct {
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    bind_addr: Address,
    recv_buf: []u8,

    pub fn init(allocator: std.mem.Allocator, bind_addr_str: []const u8, bind_port: u16) !UdpTransport {
        const bind_addr = try Address.parseIp4(bind_addr_str, bind_port);

        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
        errdefer std.posix.close(sock);

        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        // Build sockaddr.in
        const in_addr = std.posix.sockaddr.in{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, bind_port),
            .addr = bind_addr.ip[0..4].*,
            .zero = [_]u8{0} ** 8,
        };
        const addr_len: std.posix.socklen_t = @sizeOf(@TypeOf(in_addr));
        try std.posix.bind(sock, @ptrCast(&in_addr), addr_len);

        const recv_buf = try allocator.alloc(u8, max_packet_size);
        errdefer allocator.free(recv_buf);

        return UdpTransport{
            .allocator = allocator,
            .socket = sock,
            .bind_addr = bind_addr,
            .recv_buf = recv_buf,
        };
    }

    pub fn deinit(self: *UdpTransport) void {
        std.posix.close(self.socket);
        self.allocator.free(self.recv_buf);
        self.* = undefined;
    }

    /// Receive a single packet (blocking).  Returns null on WouldBlock.
    ///
    /// **The returned Packet.buf is a slice into the transport's internal
    /// buffer and will be overwritten by the next call to recvFrom.**
    /// Copy the data before the next receive.
    pub fn recvFrom(self: *UdpTransport, now_ms: i64) !?Packet {
        var client_addr: std.posix.sockaddr.in = undefined;
        var client_addr_len: std.posix.socklen_t = @sizeOf(@TypeOf(client_addr));
        const n = std.posix.recvfrom(
            self.socket,
            self.recv_buf,
            0,
            @ptrCast(&client_addr),
            &client_addr_len,
        ) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };

        var ip: [4]u8 = undefined;
        @memcpy(&ip, &client_addr.addr);
        const port = std.mem.bigToNative(u16, client_addr.port);

        return Packet{
            .buf = self.recv_buf[0..n],
            .from = Address.initIp4(ip, port),
            .timestamp_ms = now_ms,
        };
    }

    /// Send a packet to a target address.
    pub fn sendTo(self: *UdpTransport, data: []const u8, target: Address) !void {
        const in_addr = std.posix.sockaddr.in{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, target.port),
            .addr = target.ip[0..4].*,
            .zero = [_]u8{0} ** 8,
        };
        _ = try std.posix.sendto(
            self.socket,
            data,
            0,
            @ptrCast(&in_addr),
            @sizeOf(@TypeOf(in_addr)),
        );
    }

    pub fn getBindAddr(self: *const UdpTransport) Address {
        return self.bind_addr;
    }
};

/// Dial a TCP connection for push/pull.
pub fn dialTcp(allocator: std.mem.Allocator, addr: Address, timeout_ms: u32) !TcpConn {
    _ = timeout_ms;
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
    errdefer std.posix.close(sock);

    const in_addr = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, addr.port),
        .addr = addr.ip[0..4].*,
        .zero = [_]u8{0} ** 8,
    };
    try std.posix.connect(sock, @ptrCast(&in_addr), @sizeOf(@TypeOf(in_addr)));

    _ = allocator;
    return TcpConn{ .fd = sock };
}

pub const TcpConn = struct {
    fd: std.posix.socket_t,

    pub fn close(self: *TcpConn) void {
        std.posix.close(self.fd);
    }

    pub fn read(self: *TcpConn, buf: []u8) !usize {
        return std.posix.read(self.fd, buf);
    }

    pub fn write(self: *TcpConn, buf: []const u8) !usize {
        return std.posix.write(self.fd, buf);
    }
};
