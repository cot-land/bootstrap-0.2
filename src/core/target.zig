//! Target Platform Configuration
//!
//! Defines compile targets (architecture + OS combinations).
//! Used throughout the compiler to select appropriate backends.

const std = @import("std");
const builtin = @import("builtin");

/// CPU architecture
pub const Arch = enum {
    arm64,
    amd64,

    pub fn name(self: Arch) []const u8 {
        return switch (self) {
            .arm64 => "arm64",
            .amd64 => "amd64",
        };
    }
};

/// Operating system
pub const Os = enum {
    macos,
    linux,

    pub fn name(self: Os) []const u8 {
        return switch (self) {
            .macos => "macos",
            .linux => "linux",
        };
    }
};

/// Compile target (architecture + OS)
pub const Target = struct {
    arch: Arch,
    os: Os,

    /// Default target: native platform
    pub fn native() Target {
        const arch: Arch = switch (builtin.cpu.arch) {
            .aarch64 => .arm64,
            .x86_64 => .amd64,
            else => .arm64, // Fallback
        };
        const os: Os = switch (builtin.os.tag) {
            .macos => .macos,
            .linux => .linux,
            else => .linux, // Fallback
        };
        return .{ .arch = arch, .os = os };
    }

    /// ARM64/macOS target
    pub const arm64_macos = Target{ .arch = .arm64, .os = .macos };

    /// AMD64/Linux target
    pub const amd64_linux = Target{ .arch = .amd64, .os = .linux };

    /// Format as "arch-os" string
    pub fn name(self: Target) []const u8 {
        if (self.arch == .arm64 and self.os == .macos) return "arm64-macos";
        if (self.arch == .amd64 and self.os == .linux) return "amd64-linux";
        if (self.arch == .arm64 and self.os == .linux) return "arm64-linux";
        if (self.arch == .amd64 and self.os == .macos) return "amd64-macos";
        return "unknown";
    }

    /// Parse target string (e.g., "amd64-linux")
    pub fn parse(s: []const u8) ?Target {
        if (std.mem.eql(u8, s, "arm64-macos")) return arm64_macos;
        if (std.mem.eql(u8, s, "amd64-linux")) return amd64_linux;
        if (std.mem.eql(u8, s, "arm64-linux")) return .{ .arch = .arm64, .os = .linux };
        if (std.mem.eql(u8, s, "amd64-macos")) return .{ .arch = .amd64, .os = .macos };
        // Also accept "x86_64-linux" as alias for "amd64-linux"
        if (std.mem.eql(u8, s, "x86_64-linux")) return amd64_linux;
        if (std.mem.eql(u8, s, "x86-64-linux")) return amd64_linux;
        return null;
    }

    /// Check if target uses Mach-O object format
    pub fn usesMachO(self: Target) bool {
        return self.os == .macos;
    }

    /// Check if target uses ELF object format
    pub fn usesELF(self: Target) bool {
        return self.os == .linux;
    }

    /// Get pointer size in bytes
    pub fn pointerSize(self: Target) u32 {
        _ = self;
        return 8; // Always 64-bit for now
    }

    /// Get stack alignment
    pub fn stackAlign(self: Target) u32 {
        return switch (self.arch) {
            .arm64 => 16,
            .amd64 => 16,
        };
    }
};

// =========================================
// Tests
// =========================================

test "Target.native" {
    const t = Target.native();
    // Just verify it returns something valid
    _ = t.arch;
    _ = t.os;
}

test "Target.parse" {
    try std.testing.expectEqual(Target.amd64_linux, Target.parse("amd64-linux").?);
    try std.testing.expectEqual(Target.arm64_macos, Target.parse("arm64-macos").?);
    try std.testing.expectEqual(@as(?Target, null), Target.parse("invalid"));
}

test "Target.usesMachO" {
    try std.testing.expect(Target.arm64_macos.usesMachO());
    try std.testing.expect(!Target.amd64_linux.usesMachO());
}

test "Target.usesELF" {
    try std.testing.expect(Target.amd64_linux.usesELF());
    try std.testing.expect(!Target.arm64_macos.usesELF());
}
