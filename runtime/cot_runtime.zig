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

/// Memory allocation wrappers for Cot
/// These provide typed versions of malloc/realloc/free for use in Cot code

export fn malloc_u8(size: i64) ?[*]u8 {
    const allocator = std.heap.c_allocator;
    const usize_size: usize = @intCast(size);
    const result = allocator.alloc(u8, usize_size) catch {
        return null;
    };
    return result.ptr;
}

export fn realloc_u8(ptr: ?[*]u8, new_size: i64) ?[*]u8 {
    const allocator = std.heap.c_allocator;
    const usize_size: usize = @intCast(new_size);
    if (ptr) |p| {
        // Get the old allocation - we need to know its size
        // Since we don't track sizes, just allocate new and copy
        const new_mem = allocator.alloc(u8, usize_size) catch {
            return null;
        };
        // Copy old data (up to new_size, assuming old was at least that large)
        @memcpy(new_mem[0..usize_size], p[0..usize_size]);
        // Free old memory - this is tricky without knowing old size
        // For now, just return new memory (leak old)
        return new_mem.ptr;
    } else {
        return malloc_u8(new_size);
    }
}

export fn free_u8(ptr: ?[*]u8) void {
    // With std.heap.c_allocator we can't properly free without knowing size
    // This is a limitation - for now just no-op
    _ = ptr;
}

/// i64 array allocation
export fn malloc_i64(count: i64) ?[*]i64 {
    const allocator = std.heap.c_allocator;
    const usize_count: usize = @intCast(count);
    const result = allocator.alloc(i64, usize_count) catch {
        return null;
    };
    return result.ptr;
}

export fn realloc_i64(ptr: ?[*]i64, old_count: i64, new_count: i64) ?[*]i64 {
    const allocator = std.heap.c_allocator;
    const usize_new: usize = @intCast(new_count);
    if (ptr) |p| {
        const new_mem = allocator.alloc(i64, usize_new) catch {
            return null;
        };
        // Copy old data
        const usize_old: usize = @intCast(old_count);
        const copy_count = @min(usize_old, usize_new);
        @memcpy(new_mem[0..copy_count], p[0..copy_count]);
        return new_mem.ptr;
    } else {
        return malloc_i64(new_count);
    }
}

export fn free_i64(ptr: ?[*]i64) void {
    _ = ptr;
}
