//! Cot Runtime Library
//!
//! This file provides runtime functions required by Cot programs.
//! It must be compiled and linked with any Cot program that uses
//! the features below.
//!
//! Build:
//!   zig build-obj -OReleaseFast runtime/cot_runtime.zig -femit-bin=runtime/cot_runtime.o
//!
//! Link with Cot program:
//!   zig cc program.o runtime/cot_runtime.o -o program -lSystem
//!
//! Functions provided:
//!   __cot_str_concat - String concatenation (s1 + s2)

const std = @import("std");

/// Cot string representation:
///   - ptr: pointer to character data (NOT null-terminated)
///   - len: length in bytes
///
/// On ARM64, this struct is returned in (x0, x1) registers.
const CotString = extern struct {
    ptr: [*]u8,
    len: i64,
};

/// String concatenation: allocates new string, copies both inputs.
///
/// Called by compiler-generated code as:
///   __cot_str_concat(ptr1, len1, ptr2, len2)
///
/// Returns:
///   CotString with (ptr, len) in (x0, x1) per ARM64 ABI
///
/// Note: Memory is allocated with malloc. In the future, this will
/// integrate with a garbage collector.
export fn __cot_str_concat(ptr1: [*]const u8, len1: i64, ptr2: [*]const u8, len2: i64) CotString {
    const total: usize = @intCast(len1 + len2);

    // Use libc allocator for malloc compatibility
    const allocator = std.heap.c_allocator;
    const result = allocator.alloc(u8, total) catch {
        return CotString{ .ptr = undefined, .len = 0 };
    };

    // Copy first string
    const ulen1: usize = @intCast(len1);
    const ulen2: usize = @intCast(len2);
    @memcpy(result[0..ulen1], ptr1[0..ulen1]);
    @memcpy(result[ulen1..total], ptr2[0..ulen2]);

    return CotString{ .ptr = result.ptr, .len = len1 + len2 };
}
