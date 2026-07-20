// Tests for the wire protocol encoding/decoding.
// The actual tests live in src/protocol.zig — this file exists to
// register them as a separate test suite in build.zig.
const nb = @import("neighborhood");

test {
    _ = nb;
    // protocol.zig tests are compiled through the neighborhood module
}
