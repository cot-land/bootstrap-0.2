# Cot0 Runtime Error System - Complete Specification

**Document Version:** 1.0
**Created:** 2026-01-22
**Status:** Implementation Required

---

## Executive Summary

This document specifies a production-quality runtime error system for the cot0 self-hosting compiler. The system must automatically catch crashes, provide detailed diagnostics, and enable rapid debugging of issues like the current stage2 SIGSEGV.

**Current Problem:** When cot0-stage2 crashes, we see only `Exit: 139` - no crash location, no register state, no stack trace, no context. This is unacceptable for a compiler that needs to bootstrap itself.

**Goal:** Any crash in cot0-compiled code should produce comprehensive diagnostics automatically, without requiring manual instrumentation at every possible crash site.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Signal Handler Subsystem](#2-signal-handler-subsystem)
3. [Register Dump Subsystem](#3-register-dump-subsystem)
4. [Stack Trace Subsystem](#4-stack-trace-subsystem)
5. [Symbol Resolution Subsystem](#5-symbol-resolution-subsystem)
6. [Memory Diagnostics Subsystem](#6-memory-diagnostics-subsystem)
7. [Assertion and Panic Subsystem](#7-assertion-and-panic-subsystem)
8. [Compiler Validation Subsystem](#8-compiler-validation-subsystem)
9. [Execution Tracing Subsystem](#9-execution-tracing-subsystem)
10. [Integration with DWARF Debug Info](#10-integration-with-dwarf-debug-info)
11. [Implementation Phases](#11-implementation-phases)
12. [File Manifest](#12-file-manifest)
13. [Testing Strategy](#13-testing-strategy)
14. [Example Output](#14-example-output)

---

## 1. Architecture Overview

### 1.1 Design Principles

1. **Automatic Capture:** Crashes must be caught automatically via signal handlers - not by manually wrapping every operation
2. **Async-Signal-Safe:** All code in signal handlers must be async-signal-safe (no malloc, no printf, no locks)
3. **Zero Overhead When Not Crashing:** The system should have minimal impact on normal execution
4. **Self-Contained:** The error system must work even when the rest of the program is corrupted
5. **Comprehensive:** Capture ALL available information - registers, stack, memory state, symbols
6. **Actionable:** Output must directly help identify the bug, not just report that a crash occurred

### 1.2 Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           COT0 RUNTIME ERROR SYSTEM                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐         │
│  │  Signal Handler │───▶│  Register Dump  │───▶│  Stack Walker   │         │
│  │   (crash_handler)│    │  (ARM64/x86_64) │    │  (frame chain)  │         │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘         │
│           │                      │                      │                   │
│           ▼                      ▼                      ▼                   │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐         │
│  │ Memory Analysis │    │Symbol Resolution│    │  DWARF Parser   │         │
│  │ (fault address) │    │ (addr→function) │    │ (addr→file:line)│         │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘         │
│           │                      │                      │                   │
│           └──────────────────────┼──────────────────────┘                   │
│                                  ▼                                          │
│                         ┌─────────────────┐                                 │
│                         │  Crash Report   │                                 │
│                         │   Generator     │                                 │
│                         └─────────────────┘                                 │
│                                  │                                          │
│                                  ▼                                          │
│                         ┌─────────────────┐                                 │
│                         │ stderr (fd=2)   │                                 │
│                         │ + optional file │                                 │
│                         └─────────────────┘                                 │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  COMPILE-TIME INSTRUMENTATION (Optional, enabled via flag)                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐         │
│  │  Bounds Check   │    │   Null Check    │    │  Type Validate  │         │
│  │  Insertion      │    │   Insertion     │    │   Insertion     │         │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘         │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  RUNTIME SUPPORT                                                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐         │
│  │  Panic Handler  │    │ Assertion Macro │    │ Execution Trace │         │
│  │  (controlled)   │    │ (rich context)  │    │ (ring buffer)   │         │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 Data Flow on Crash

```
1. SIGSEGV/SIGBUS/etc occurs
         │
         ▼
2. Kernel delivers signal to crash_handler()
         │
         ▼
3. crash_handler() receives (signal, siginfo_t*, ucontext_t*)
         │
         ├──▶ Extract fault address from siginfo_t
         │
         ├──▶ Extract all registers from ucontext_t
         │
         ├──▶ Walk stack frames using frame pointer chain
         │
         ├──▶ For each return address, look up symbol name
         │
         ├──▶ For each return address, look up DWARF line info
         │
         ├──▶ Analyze fault address (null? unmapped? guard page?)
         │
         ▼
4. Write crash report to stderr using only write() syscall
         │
         ▼
5. Call _exit(128 + signum) to terminate
```

---

## 2. Signal Handler Subsystem

### 2.1 Signals to Handle

| Signal | Cause | Priority |
|--------|-------|----------|
| SIGSEGV | Invalid memory access (null ptr, bad ptr, stack overflow) | **Critical** |
| SIGBUS | Bus error (misaligned access, bad physical address) | **Critical** |
| SIGFPE | Floating point exception (div by zero, overflow) | High |
| SIGILL | Illegal instruction (corrupted code, bad jump) | High |
| SIGABRT | Abort (assertion failure, abort() call) | High |
| SIGTRAP | Breakpoint/trap (debugging) | Medium |

### 2.2 Signal Handler Implementation

**File: `runtime/crash_handler.c`**

```c
/*
 * Cot0 Crash Handler
 *
 * IMPORTANT: This code runs in a signal handler context.
 * Only async-signal-safe functions may be used:
 *   - write()
 *   - _exit()
 *   - Direct memory access
 *
 * FORBIDDEN in signal handlers:
 *   - malloc/free
 *   - printf/fprintf
 *   - Any function that takes locks
 *   - Any function not explicitly marked async-signal-safe
 */

#define _GNU_SOURCE
#include <signal.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>

#ifdef __APPLE__
#include <mach/mach.h>
#include <sys/ucontext.h>
#define GET_PC(uc)  ((uc)->uc_mcontext->__ss.__pc)
#define GET_SP(uc)  ((uc)->uc_mcontext->__ss.__sp)
#define GET_FP(uc)  ((uc)->uc_mcontext->__ss.__fp)
#define GET_LR(uc)  ((uc)->uc_mcontext->__ss.__lr)
#define GET_X(uc,n) ((uc)->uc_mcontext->__ss.__x[n])
#else
// Linux ARM64
#include <sys/ucontext.h>
#define GET_PC(uc)  ((uc)->uc_mcontext.pc)
#define GET_SP(uc)  ((uc)->uc_mcontext.sp)
#define GET_FP(uc)  ((uc)->uc_mcontext.regs[29])
#define GET_LR(uc)  ((uc)->uc_mcontext.regs[30])
#define GET_X(uc,n) ((uc)->uc_mcontext.regs[n])
#endif

// Pre-allocated buffer for crash report (can't malloc in signal handler)
static char crash_buffer[8192];
static int crash_buffer_pos = 0;

// Symbol table (populated at startup)
#define MAX_SYMBOLS 10000
static struct {
    uint64_t addr;
    const char *name;
} symbol_table[MAX_SYMBOLS];
static int symbol_count = 0;

// ============================================================================
// Async-signal-safe output functions
// ============================================================================

static void crash_write(const char *s, size_t len) {
    write(STDERR_FILENO, s, len);
}

static void crash_puts(const char *s) {
    crash_write(s, strlen(s));
}

static void crash_putchar(char c) {
    crash_write(&c, 1);
}

static void crash_put_hex(uint64_t val, int width) {
    char buf[17];
    for (int i = width - 1; i >= 0; i--) {
        int digit = (val >> (i * 4)) & 0xF;
        buf[width - 1 - i] = digit < 10 ? '0' + digit : 'a' + digit - 10;
    }
    crash_write(buf, width);
}

static void crash_put_dec(int64_t val) {
    char buf[21];
    int pos = 20;
    int neg = 0;

    if (val < 0) {
        neg = 1;
        val = -val;
    }

    if (val == 0) {
        buf[pos--] = '0';
    } else {
        while (val > 0) {
            buf[pos--] = '0' + (val % 10);
            val /= 10;
        }
    }

    if (neg) {
        buf[pos--] = '-';
    }

    crash_write(&buf[pos + 1], 20 - pos);
}

// ============================================================================
// Signal name lookup
// ============================================================================

static const char *signal_name(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGFPE:  return "SIGFPE";
        case SIGILL:  return "SIGILL";
        case SIGABRT: return "SIGABRT";
        case SIGTRAP: return "SIGTRAP";
        default:      return "UNKNOWN";
    }
}

static const char *signal_description(int sig, int code) {
    if (sig == SIGSEGV) {
        switch (code) {
            case SEGV_MAPERR: return "Address not mapped to object";
            case SEGV_ACCERR: return "Invalid permissions for mapped object";
            default:          return "Segmentation fault";
        }
    } else if (sig == SIGBUS) {
        switch (code) {
            case BUS_ADRALN: return "Invalid address alignment";
            case BUS_ADRERR: return "Nonexistent physical address";
            case BUS_OBJERR: return "Object-specific hardware error";
            default:         return "Bus error";
        }
    } else if (sig == SIGFPE) {
        switch (code) {
            case FPE_INTDIV: return "Integer divide by zero";
            case FPE_INTOVF: return "Integer overflow";
            case FPE_FLTDIV: return "Floating-point divide by zero";
            case FPE_FLTOVF: return "Floating-point overflow";
            case FPE_FLTUND: return "Floating-point underflow";
            case FPE_FLTRES: return "Floating-point inexact result";
            case FPE_FLTINV: return "Invalid floating-point operation";
            default:         return "Floating-point exception";
        }
    } else if (sig == SIGILL) {
        switch (code) {
            case ILL_ILLOPC: return "Illegal opcode";
            case ILL_ILLOPN: return "Illegal operand";
            case ILL_ILLADR: return "Illegal addressing mode";
            case ILL_ILLTRP: return "Illegal trap";
            case ILL_PRVOPC: return "Privileged opcode";
            default:         return "Illegal instruction";
        }
    }
    return "Unknown signal";
}

// ============================================================================
// Memory analysis
// ============================================================================

static void analyze_fault_address(void *addr) {
    uint64_t a = (uint64_t)addr;

    crash_puts("  Analysis: ");

    if (addr == NULL) {
        crash_puts("NULL pointer dereference\n");
    } else if (a < 4096) {
        crash_puts("Near-NULL pointer (offset ");
        crash_put_dec(a);
        crash_puts(" from NULL)\n");
    } else if (a >= 0x7F0000000000ULL) {
        crash_puts("Stack region access (possible stack overflow)\n");
    } else if ((a & 0x7) != 0) {
        crash_puts("Misaligned address (alignment: ");
        crash_put_dec(a & 0x7);
        crash_puts(")\n");
    } else {
        crash_puts("Invalid memory address\n");
    }
}

// ============================================================================
// Symbol lookup
// ============================================================================

static const char *lookup_symbol(uint64_t addr, uint64_t *offset) {
    // Binary search through sorted symbol table
    int lo = 0, hi = symbol_count - 1;
    int best = -1;

    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (symbol_table[mid].addr <= addr) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }

    if (best >= 0) {
        *offset = addr - symbol_table[best].addr;
        return symbol_table[best].name;
    }

    *offset = 0;
    return NULL;
}

// ============================================================================
// Stack walking
// ============================================================================

static void walk_stack(uint64_t fp, uint64_t pc) {
    crash_puts("\nStack Trace:\n");
    crash_puts("────────────────────────────────────────────────────────────────\n");

    // First frame: current PC
    uint64_t offset;
    const char *name = lookup_symbol(pc, &offset);

    crash_puts("  #0  0x");
    crash_put_hex(pc, 16);
    if (name) {
        crash_puts(" ");
        crash_puts(name);
        crash_puts("+0x");
        crash_put_hex(offset, 4);
    }
    crash_puts(" <-- CRASH HERE\n");

    // Walk frame pointer chain
    uint64_t *frame = (uint64_t *)fp;
    int depth = 1;

    while (frame && depth < 50) {
        // Validate frame pointer is reasonable
        uint64_t frame_addr = (uint64_t)frame;
        if (frame_addr < 0x1000 || frame_addr > 0x7FFFFFFFFFFFULL) {
            break;
        }

        // On ARM64: frame[0] = previous FP, frame[1] = return address (LR)
        uint64_t prev_fp = frame[0];
        uint64_t ret_addr = frame[1];

        // Validate return address
        if (ret_addr < 0x1000 || ret_addr > 0x7FFFFFFFFFFFULL) {
            break;
        }

        name = lookup_symbol(ret_addr, &offset);

        crash_puts("  #");
        crash_put_dec(depth);
        if (depth < 10) crash_puts(" ");
        crash_puts(" 0x");
        crash_put_hex(ret_addr, 16);
        if (name) {
            crash_puts(" ");
            crash_puts(name);
            crash_puts("+0x");
            crash_put_hex(offset, 4);
        }
        crash_puts("\n");

        // Check for end of stack
        if (prev_fp == 0 || prev_fp == frame_addr) {
            break;
        }

        frame = (uint64_t *)prev_fp;
        depth++;
    }

    crash_puts("────────────────────────────────────────────────────────────────\n");
}

// ============================================================================
// Register dump (ARM64)
// ============================================================================

static void dump_registers_arm64(ucontext_t *uc) {
    crash_puts("\nRegisters:\n");
    crash_puts("────────────────────────────────────────────────────────────────\n");

    // Program Counter
    crash_puts("  PC   0x");
    crash_put_hex(GET_PC(uc), 16);
    crash_puts("    (instruction pointer)\n");

    // Link Register
    crash_puts("  LR   0x");
    crash_put_hex(GET_LR(uc), 16);
    crash_puts("    (return address)\n");

    // Stack Pointer
    crash_puts("  SP   0x");
    crash_put_hex(GET_SP(uc), 16);
    crash_puts("    (stack pointer)\n");

    // Frame Pointer
    crash_puts("  FP   0x");
    crash_put_hex(GET_FP(uc), 16);
    crash_puts("    (frame pointer)\n");

    crash_puts("\n");

    // General purpose registers (x0-x28)
    for (int i = 0; i < 29; i++) {
        if (i % 4 == 0) crash_puts("  ");
        crash_puts("x");
        if (i < 10) crash_puts("0");
        crash_put_dec(i);
        crash_puts("=0x");
        crash_put_hex(GET_X(uc, i), 16);
        if (i % 4 == 3 || i == 28) {
            crash_puts("\n");
        } else {
            crash_puts("  ");
        }
    }

    crash_puts("────────────────────────────────────────────────────────────────\n");
}

// ============================================================================
// Main crash handler
// ============================================================================

static void crash_handler(int sig, siginfo_t *info, void *context) {
    ucontext_t *uc = (ucontext_t *)context;

    // Header
    crash_puts("\n");
    crash_puts("╔══════════════════════════════════════════════════════════════════╗\n");
    crash_puts("║                         CRASH DETECTED                           ║\n");
    crash_puts("╚══════════════════════════════════════════════════════════════════╝\n");
    crash_puts("\n");

    // Signal info
    crash_puts("Signal:  ");
    crash_puts(signal_name(sig));
    crash_puts(" (");
    crash_put_dec(sig);
    crash_puts(")\n");

    crash_puts("Reason:  ");
    crash_puts(signal_description(sig, info->si_code));
    crash_puts("\n");

    // Fault address (if applicable)
    if (sig == SIGSEGV || sig == SIGBUS) {
        crash_puts("Address: 0x");
        crash_put_hex((uint64_t)info->si_addr, 16);
        crash_puts("\n");
        analyze_fault_address(info->si_addr);
    }

    // Registers
    dump_registers_arm64(uc);

    // Stack trace
    walk_stack(GET_FP(uc), GET_PC(uc));

    // Instructions for debugging
    crash_puts("\nTo debug further:\n");
    crash_puts("  1. Run: lldb <executable>\n");
    crash_puts("  2. (lldb) image lookup -a 0x");
    crash_put_hex(GET_PC(uc), 16);
    crash_puts("\n");
    crash_puts("  3. (lldb) disassemble -a 0x");
    crash_put_hex(GET_PC(uc), 16);
    crash_puts("\n\n");

    // Exit
    _exit(128 + sig);
}

// ============================================================================
// Installation
// ============================================================================

void install_crash_handler(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);

    // Install for all crash signals
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);

    // Set up alternate signal stack (so we can handle stack overflow)
    static char alt_stack[SIGSTKSZ];
    stack_t ss;
    ss.ss_sp = alt_stack;
    ss.ss_size = SIGSTKSZ;
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);
}

// ============================================================================
// Symbol table registration (called at startup)
// ============================================================================

void register_symbol(uint64_t addr, const char *name) {
    if (symbol_count < MAX_SYMBOLS) {
        symbol_table[symbol_count].addr = addr;
        symbol_table[symbol_count].name = name;
        symbol_count++;
    }
}

// Sort symbols by address (call after all symbols registered)
static int compare_symbols(const void *a, const void *b) {
    uint64_t addr_a = ((struct { uint64_t addr; const char *name; } *)a)->addr;
    uint64_t addr_b = ((struct { uint64_t addr; const char *name; } *)b)->addr;
    return (addr_a > addr_b) - (addr_a < addr_b);
}

void finalize_symbol_table(void) {
    // Simple insertion sort (qsort not async-signal-safe, but this is at startup)
    for (int i = 1; i < symbol_count; i++) {
        uint64_t addr = symbol_table[i].addr;
        const char *name = symbol_table[i].name;
        int j = i - 1;
        while (j >= 0 && symbol_table[j].addr > addr) {
            symbol_table[j + 1] = symbol_table[j];
            j--;
        }
        symbol_table[j + 1].addr = addr;
        symbol_table[j + 1].name = name;
    }
}
```

### 2.3 Alternate Signal Stack

The crash handler uses `SA_ONSTACK` and `sigaltstack()` to handle stack overflow crashes. Without this, a stack overflow would crash the signal handler itself since there's no stack space left.

---

## 3. Register Dump Subsystem

### 3.1 ARM64 (Apple Silicon / Linux ARM64)

The register dump captures:

| Register | Purpose | Debugging Value |
|----------|---------|-----------------|
| PC | Program Counter | **Exact crash location** |
| LR (x30) | Link Register | Return address (caller) |
| SP | Stack Pointer | Stack state at crash |
| FP (x29) | Frame Pointer | Stack frame chain |
| x0-x7 | Arguments/Return | Function arguments at crash |
| x8 | Indirect result | Struct return pointer |
| x9-x15 | Temporaries | Intermediate values |
| x16-x17 | Intra-procedure | Platform reserved |
| x18 | Platform register | Thread pointer (macOS) |
| x19-x28 | Callee-saved | Preserved across calls |

### 3.2 x86_64 (Future)

For x86_64 support, add:

```c
#ifdef __x86_64__
#define GET_PC(uc)  ((uc)->uc_mcontext.gregs[REG_RIP])
#define GET_SP(uc)  ((uc)->uc_mcontext.gregs[REG_RSP])
#define GET_FP(uc)  ((uc)->uc_mcontext.gregs[REG_RBP])
// ... etc
#endif
```

---

## 4. Stack Trace Subsystem

### 4.1 Frame Pointer Chain Walking

On ARM64, the stack frame layout is:

```
High addresses
┌────────────────┐
│  Previous FP   │  ◄── FP points here
├────────────────┤
│  Return Addr   │  ◄── FP + 8
├────────────────┤
│  Local vars    │
│     ...        │
├────────────────┤
│  Previous FP   │  ◄── Next frame
├────────────────┤
│  Return Addr   │
│     ...        │
└────────────────┘
Low addresses
```

Walking algorithm:
```
1. Start with current FP from ucontext
2. Read [FP] → previous FP
3. Read [FP+8] → return address
4. Print return address with symbol name
5. Set FP = previous FP
6. Repeat until FP is NULL or invalid
```

### 4.2 Frame Pointer Validation

Before dereferencing a frame pointer, validate it:

```c
static int is_valid_frame_ptr(uint64_t fp) {
    // Not NULL
    if (fp == 0) return 0;

    // Must be 16-byte aligned on ARM64
    if (fp & 0xF) return 0;

    // Must be in reasonable memory range
    if (fp < 0x10000) return 0;  // Too low
    if (fp > 0x7FFFFFFFFFFFULL) return 0;  // Too high

    // Could add: check if mapped via mincore() but that's not signal-safe
    return 1;
}
```

### 4.3 Depth Limiting

Limit stack trace depth to prevent infinite loops from corrupted frame chains:

```c
#define MAX_STACK_DEPTH 50
```

---

## 5. Symbol Resolution Subsystem

### 5.1 Symbol Table Structure

The symbol table maps addresses to function names:

```c
struct Symbol {
    uint64_t addr;      // Start address of function
    uint64_t size;      // Size of function (optional)
    const char *name;   // Function name (null-terminated)
};
```

### 5.2 Symbol Table Population

**Option A: Compile-time generation**

During Mach-O generation, emit a symbol registration table:

```c
// Generated by compiler
void _cot_register_symbols(void) {
    register_symbol(0x100001000, "main");
    register_symbol(0x100001100, "Scanner_init");
    register_symbol(0x100001200, "Scanner_next");
    // ... all functions
    finalize_symbol_table();
}
```

**Option B: Runtime parsing of Mach-O**

Parse the binary's own symbol table at startup:

```c
void load_symbols_from_binary(void) {
    // 1. Find Mach-O header via _dyld_get_image_header(0)
    // 2. Find LC_SYMTAB load command
    // 3. Parse nlist64 entries
    // 4. Register each function symbol
    // 5. Sort by address
}
```

**Option C: External symbol file**

Generate `program.sym` alongside the binary:

```
0x100001000 main
0x100001100 Scanner_init
0x100001200 Scanner_next
```

Load at startup:
```c
void load_symbol_file(const char *path) {
    int fd = open(path, O_RDONLY);
    // Parse line by line: hex_addr space name
}
```

### 5.3 Symbol Lookup

Binary search for the largest address ≤ target:

```c
const char *lookup_symbol(uint64_t addr, uint64_t *offset) {
    int lo = 0, hi = symbol_count - 1;
    int best = -1;

    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (symbol_table[mid].addr <= addr) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }

    if (best >= 0 && symbol_table[best].addr <= addr) {
        *offset = addr - symbol_table[best].addr;
        return symbol_table[best].name;
    }
    return NULL;
}
```

---

## 6. Memory Diagnostics Subsystem

### 6.1 Fault Address Analysis

Categorize the fault address to help identify the bug:

| Address Range | Diagnosis |
|---------------|-----------|
| `0x0` | NULL pointer dereference |
| `0x1 - 0xFFF` | Near-NULL (likely struct field of NULL pointer) |
| `0x1000 - 0xFFFF` | Small invalid address (uninitialized pointer?) |
| Odd address | Misalignment (loading 64-bit from non-8-byte boundary) |
| Near stack | Stack overflow or stack buffer overflow |
| Very large | Wild pointer (memory corruption) |

### 6.2 Near-NULL Analysis

If the fault address is small (< 4096), calculate the offset:

```c
if (fault_addr < 4096 && fault_addr > 0) {
    crash_puts("Accessing offset ");
    crash_put_dec(fault_addr);
    crash_puts(" of NULL pointer\n");
    crash_puts("Likely: ptr->field where ptr is NULL\n");

    // Try to identify which field based on offset
    // offset 0 = first field
    // offset 8 = second i64 field
    // etc.
}
```

### 6.3 Guard Page Detection

Detect stack overflow by checking if fault address is near the stack limit:

```c
// Stack typically grows down from high addresses
// Guard page is usually at bottom of stack
if (fault_addr >= stack_base - 4096 && fault_addr < stack_base) {
    crash_puts("STACK OVERFLOW detected\n");
    crash_puts("Consider: reducing recursion depth, increasing stack size\n");
}
```

---

## 7. Assertion and Panic Subsystem

### 7.1 Panic Function

A controlled crash with context:

```c
// In cot0 code (main.cot):

fn cot_panic(msg: *u8, file: *u8, line: i64) {
    stderr_str("\n");
    stderr_str("╔══════════════════════════════════════════════════════════════════╗\n");
    stderr_str("║                          PANIC                                   ║\n");
    stderr_str("╚══════════════════════════════════════════════════════════════════╝\n");
    stderr_str("\n");
    stderr_str("Message: ");
    stderr_ptr(msg);
    stderr_str("\n");
    stderr_str("Location: ");
    stderr_ptr(file);
    stderr_str(":");
    stderr_int(line);
    stderr_str("\n\n");

    // Trigger SIGABRT to get full crash diagnostics
    abort();
}
```

### 7.2 Assert Macro

Rich assertions with context:

```cot
// Macro-like function (until we have real macros)
fn cot_assert(cond: bool, msg: *u8, file: *u8, line: i64) {
    if !cond {
        stderr_str("\n");
        stderr_str("╔══════════════════════════════════════════════════════════════════╗\n");
        stderr_str("║                     ASSERTION FAILED                             ║\n");
        stderr_str("╚══════════════════════════════════════════════════════════════════╝\n");
        stderr_str("\n");
        stderr_str("Condition: ");
        stderr_ptr(msg);
        stderr_str("\n");
        stderr_str("Location:  ");
        stderr_ptr(file);
        stderr_str(":");
        stderr_int(line);
        stderr_str("\n\n");
        abort();
    }
}

// Usage:
cot_assert(ptr != null, "ptr != null", "lower.cot", 1234);
```

### 7.3 Bounds Check Function

```cot
fn cot_bounds_check(index: i64, len: i64, array_name: *u8, file: *u8, line: i64) {
    if index < 0 or index >= len {
        stderr_str("\n");
        stderr_str("╔══════════════════════════════════════════════════════════════════╗\n");
        stderr_str("║                     BOUNDS CHECK FAILED                          ║\n");
        stderr_str("╚══════════════════════════════════════════════════════════════════╝\n");
        stderr_str("\n");
        stderr_str("Array:    ");
        stderr_ptr(array_name);
        stderr_str("\n");
        stderr_str("Index:    ");
        stderr_int(index);
        stderr_str("\n");
        stderr_str("Length:   ");
        stderr_int(len);
        stderr_str("\n");
        stderr_str("Location: ");
        stderr_ptr(file);
        stderr_str(":");
        stderr_int(line);
        stderr_str("\n\n");
        abort();
    }
}
```

### 7.4 Null Check Function

```cot
fn cot_null_check(ptr: *u8, ptr_name: *u8, file: *u8, line: i64) {
    if ptr == null {
        stderr_str("\n");
        stderr_str("╔══════════════════════════════════════════════════════════════════╗\n");
        stderr_str("║                      NULL POINTER                                ║\n");
        stderr_str("╚══════════════════════════════════════════════════════════════════╝\n");
        stderr_str("\n");
        stderr_str("Variable: ");
        stderr_ptr(ptr_name);
        stderr_str("\n");
        stderr_str("Location: ");
        stderr_ptr(file);
        stderr_str(":");
        stderr_int(line);
        stderr_str("\n\n");
        abort();
    }
}
```

---

## 8. Compiler Validation Subsystem

### 8.1 AST Node Validation

Before accessing any AST node:

```cot
fn validate_ast_node(node: *Node, context: *u8, file: *u8, line: i64) {
    if node == null {
        cot_panic_context("NULL AST node", context, file, line);
    }

    let kind: i64 = node.kind;
    if kind < 0 or kind > NODE_KIND_MAX {
        stderr_str("Invalid AST node kind: ");
        stderr_int(kind);
        stderr_str(" in ");
        stderr_ptr(context);
        stderr_str("\n");
        abort();
    }
}

// Usage in lowerer:
fn lowerExpr(self: *Lowerer, node: *Node) i64 {
    validate_ast_node(node, "lowerExpr", "lower.cot", 500);
    // ... rest of function
}
```

### 8.2 IR Node Validation

```cot
fn validate_ir_node(node: *IRNode, context: *u8) {
    if node == null {
        cot_panic("NULL IR node", context);
    }

    if node.kind < 0 or node.kind > IR_KIND_MAX {
        stderr_str("Invalid IR node kind: ");
        stderr_int(node.kind);
        abort();
    }

    if node.type_idx < 0 or node.type_idx >= g_type_count {
        stderr_str("Invalid type index: ");
        stderr_int(node.type_idx);
        abort();
    }
}
```

### 8.3 SSA Value Validation

```cot
fn validate_ssa_value(v: *Value, context: *u8) {
    if v == null {
        cot_panic("NULL SSA value", context);
    }

    if v.op < 0 or v.op > OP_MAX {
        stderr_str("Invalid SSA op: ");
        stderr_int(v.op);
        abort();
    }

    if v.block < 0 or v.block >= g_block_count {
        stderr_str("Invalid block index: ");
        stderr_int(v.block);
        abort();
    }
}
```

### 8.4 Type Index Validation

```cot
fn validate_type_idx(type_idx: i64, context: *u8) {
    if type_idx < 0 {
        stderr_str("Negative type index: ");
        stderr_int(type_idx);
        stderr_str(" in ");
        stderr_ptr(context);
        abort();
    }

    if type_idx >= g_type_count {
        stderr_str("Type index out of bounds: ");
        stderr_int(type_idx);
        stderr_str(" >= ");
        stderr_int(g_type_count);
        stderr_str(" in ");
        stderr_ptr(context);
        abort();
    }
}
```

---

## 9. Execution Tracing Subsystem

### 9.1 Ring Buffer Trace

A fixed-size ring buffer that records recent function calls:

```c
#define TRACE_SIZE 256

static struct {
    const char *func_name;
    const char *file;
    int line;
    uint64_t timestamp;
} trace_buffer[TRACE_SIZE];

static int trace_pos = 0;

void trace_enter(const char *func, const char *file, int line) {
    trace_buffer[trace_pos].func_name = func;
    trace_buffer[trace_pos].file = file;
    trace_buffer[trace_pos].line = line;
    trace_buffer[trace_pos].timestamp = __builtin_readcyclecounter();
    trace_pos = (trace_pos + 1) % TRACE_SIZE;
}

void dump_trace(void) {
    crash_puts("\nExecution Trace (most recent last):\n");
    crash_puts("────────────────────────────────────────────────────────────────\n");

    for (int i = 0; i < TRACE_SIZE; i++) {
        int idx = (trace_pos + i) % TRACE_SIZE;
        if (trace_buffer[idx].func_name) {
            crash_puts("  ");
            crash_puts(trace_buffer[idx].file);
            crash_puts(":");
            crash_put_dec(trace_buffer[idx].line);
            crash_puts(" ");
            crash_puts(trace_buffer[idx].func_name);
            crash_puts("\n");
        }
    }
}
```

### 9.2 Cot Integration

```cot
extern fn trace_enter(func: *u8, file: *u8, line: i64);

fn lowerExpr(self: *Lowerer, node: *Node) i64 {
    trace_enter("lowerExpr", "lower.cot", 500);
    // ... function body
}
```

### 9.3 Conditional Tracing

Only enable tracing when `COT_TRACE=1`:

```c
static int trace_enabled = 0;

void trace_init(void) {
    const char *env = getenv("COT_TRACE");
    if (env && env[0] == '1') {
        trace_enabled = 1;
    }
}

void trace_enter(const char *func, const char *file, int line) {
    if (!trace_enabled) return;
    // ... actual tracing
}
```

---

## 10. Integration with DWARF Debug Info

### 10.1 Line Table Lookup

If the binary includes DWARF `__debug_line` section, we can map PC → file:line:

```c
// This requires parsing DWARF at startup, which is complex.
// Simplified approach: generate a line table as a simple array

struct LineEntry {
    uint64_t addr;
    const char *file;
    int line;
};

static struct LineEntry line_table[MAX_LINE_ENTRIES];
static int line_count = 0;

const char *lookup_line(uint64_t addr, int *line_out) {
    // Binary search for largest addr <= target
    // Return file and line
}
```

### 10.2 Source Context Display

When crash location is known, show surrounding source:

```
Crash at lower.cot:1234

  1232 │     let node_kind: i64 = node.kind;
  1233 │     if node_kind == NODE_BINARY {
→ 1234 │         let left: *Node = node.left;  // CRASHED HERE
  1235 │         let right: *Node = node.right;
  1236 │     }
```

This requires either:
- Embedding source in the binary
- Reading source file at crash time (risky in signal handler)
- Pre-generating source snippets at compile time

---

## 11. Implementation Phases

### Phase 1: Basic Signal Handler (Priority: CRITICAL)

**Goal:** Any crash shows PC, registers, and basic stack trace

**Tasks:**
1. Create `runtime/crash_handler.c`
2. Implement `install_crash_handler()`
3. Implement async-signal-safe output functions
4. Implement register dump for ARM64
5. Implement basic stack walking
6. Add `extern fn install_crash_handler()` to main.cot
7. Call `install_crash_handler()` at start of main
8. Modify build to compile and link crash_handler.c

**Deliverable:** Crashes show PC, LR, SP, FP + raw stack addresses

**Validation:**
```
# Should show crash diagnostics instead of just "Exit: 139"
/tmp/cot0-stage2 /tmp/test.cot -o /tmp/test.o
```

### Phase 2: Symbol Resolution (Priority: HIGH)

**Goal:** Stack traces show function names, not just addresses

**Tasks:**
1. Add symbol registration API to crash_handler.c
2. Generate symbol registration code in Mach-O writer
3. Binary search symbol lookup
4. Integrate into stack trace output

**Deliverable:** Stack traces show `main+0x24` instead of `0x100001024`

### Phase 3: Panic and Assert (Priority: HIGH)

**Goal:** Controlled crashes with rich context

**Tasks:**
1. Implement `cot_panic()` in main.cot
2. Implement `cot_assert()` in main.cot
3. Implement `cot_bounds_check()` in main.cot
4. Implement `cot_null_check()` in main.cot
5. Add validation calls to critical code paths

**Deliverable:** Assertions show condition, file, line before crash

### Phase 4: Compiler Validation (Priority: MEDIUM)

**Goal:** Validate all AST/IR/SSA access to catch corruption early

**Tasks:**
1. Add `validate_ast_node()` at entry to all AST processing functions
2. Add `validate_ir_node()` at entry to all IR processing functions
3. Add `validate_ssa_value()` at entry to all SSA processing functions
4. Add bounds checks on all array accesses
5. Add null checks on all pointer dereferences in critical paths

**Deliverable:** Corrupted data structures detected immediately with context

### Phase 5: Execution Tracing (Priority: MEDIUM)

**Goal:** See what code path led to the crash

**Tasks:**
1. Implement ring buffer trace in C
2. Add trace entry calls to key functions
3. Dump trace on crash
4. Add `COT_TRACE=1` environment variable control

**Deliverable:** Crash shows last ~256 function entries

### Phase 6: Source Location (Priority: LOW)

**Goal:** Show file:line for crash and stack frames

**Tasks:**
1. Thread source positions through IR and SSA
2. Generate line table during codegen
3. Emit DWARF __debug_line section
4. Parse line table in crash handler
5. Display source context around crash

**Deliverable:** Crash shows `lower.cot:1234` instead of just address

---

## 12. File Manifest

### New Files to Create

| File | Purpose | Phase |
|------|---------|-------|
| `runtime/crash_handler.c` | Signal handler, register dump, stack trace | 1 |
| `runtime/crash_handler.h` | Header for crash handler API | 1 |
| `cot0/lib/validate.cot` | Compiler validation functions | 4 |
| `cot0/lib/trace.cot` | Execution tracing functions | 5 |

### Files to Modify

| File | Changes | Phase |
|------|---------|-------|
| `runtime/cot_runtime.zig` | Link crash_handler, export install_crash_handler | 1 |
| `cot0/main.cot` | Call install_crash_handler(), add panic/assert | 1, 3 |
| `cot0/obj/macho.cot` | Generate symbol registration | 2 |
| `cot0/frontend/lower.cot` | Add validation calls | 4 |
| `cot0/ssa/builder.cot` | Add validation calls | 4 |
| `cot0/codegen/genssa.cot` | Add validation calls | 4 |
| `build.zig` | Compile crash_handler.c | 1 |

---

## 13. Testing Strategy

### 13.1 Unit Tests for Crash Handler

Create test programs that deliberately crash:

```c
// test_null_deref.c
int main() {
    install_crash_handler();
    int *p = NULL;
    *p = 42;  // Should show NULL dereference diagnostics
    return 0;
}

// test_stack_overflow.c
void recurse(int depth) {
    char buf[4096];
    buf[0] = depth;
    recurse(depth + 1);
}
int main() {
    install_crash_handler();
    recurse(0);  // Should show stack overflow
    return 0;
}

// test_bad_ptr.c
int main() {
    install_crash_handler();
    int *p = (int *)0xDEADBEEF;
    *p = 42;  // Should show invalid address
    return 0;
}
```

### 13.2 Integration Tests

```bash
# Test 1: NULL pointer in AST
echo 'fn test() i64 { /* trigger null node access */ }' > /tmp/test.cot
/tmp/cot0-stage1 /tmp/test.cot -o /tmp/test.o
# Should show: "NULL AST node in lowerExpr at lower.cot:500"

# Test 2: Bounds error
# Create code that triggers array bounds violation
# Should show: "BOUNDS CHECK FAILED: array[100] >= length 50"

# Test 3: Self-hosting crash
/tmp/cot0-stage2 /tmp/test42.cot -o /tmp/x.o
# Should show: Full crash diagnostics instead of just "Exit: 139"
```

### 13.3 Validation Criteria

| Test | Expected Output | Pass Criteria |
|------|-----------------|---------------|
| NULL deref | "NULL pointer dereference" + PC + stack | Shows NULL analysis |
| Stack overflow | "Stack overflow" + truncated stack | Detects guard page |
| Bad pointer | "Invalid memory address" + address | Shows address |
| Assertion fail | Condition + file:line | Shows context |
| Bounds error | Array name + index + length | Shows bounds |
| Stage2 crash | Full diagnostics | Identifies crash location |

---

## 14. Example Output

### 14.1 Current Output (Unacceptable)

```
/tmp/test42.cot
Exit: 139
```

### 14.2 Target Output (After Phase 1)

```
/tmp/test42.cot

╔══════════════════════════════════════════════════════════════════╗
║                         CRASH DETECTED                           ║
╚══════════════════════════════════════════════════════════════════╝

Signal:  SIGSEGV (11)
Reason:  Address not mapped to object
Address: 0x0000000000000008
  Analysis: Near-NULL pointer (offset 8 from NULL)

Registers:
────────────────────────────────────────────────────────────────
  PC   0x0000000100003a4c    (instruction pointer)
  LR   0x0000000100003b20    (return address)
  SP   0x000000016fdff2a0    (stack pointer)
  FP   0x000000016fdff2b0    (frame pointer)

  x00=0x0000000000000000  x01=0x0000000000000008  x02=0x000000016fdff3c0  x03=0x0000000000000001
  x04=0x0000000000000000  x05=0x0000000000000000  x06=0x0000000000000000  x07=0x0000000000000000
  ...
────────────────────────────────────────────────────────────────

Stack Trace:
────────────────────────────────────────────────────────────────
  #0  0x0000000100003a4c <-- CRASH HERE
  #1  0x0000000100003b20
  #2  0x0000000100003f44
  #3  0x0000000100004128
  #4  0x0000000100001a00
────────────────────────────────────────────────────────────────

To debug further:
  1. Run: lldb /tmp/cot0-stage2
  2. (lldb) image lookup -a 0x0000000100003a4c
  3. (lldb) disassemble -a 0x0000000100003a4c
```

### 14.3 Target Output (After Phase 2 - Symbols)

```
Stack Trace:
────────────────────────────────────────────────────────────────
  #0  0x0000000100003a4c Lowerer_lowerExpr+0x012c <-- CRASH HERE
  #1  0x0000000100003b20 Lowerer_lowerBinary+0x0040
  #2  0x0000000100003f44 Lowerer_lowerStmt+0x0124
  #3  0x0000000100004128 Lowerer_lowerBlock+0x0088
  #4  0x0000000100001a00 main+0x0400
────────────────────────────────────────────────────────────────
```

### 14.4 Target Output (After Phase 6 - Source)

```
Crash Location:
────────────────────────────────────────────────────────────────
  File: cot0/frontend/lower.cot
  Line: 1234
  Function: Lowerer_lowerExpr

  1232 │     let node_kind: i64 = node.kind;
  1233 │     if node_kind == NODE_BINARY {
→ 1234 │         let left: *Node = node.left;  // CRASHED HERE
  1235 │         let right: *Node = node.right;
  1236 │     }

  Likely cause: 'node' is NULL, accessing field at offset 8
────────────────────────────────────────────────────────────────
```

---

## Appendix A: Async-Signal-Safe Functions

Functions that are safe to call from a signal handler (POSIX):

- `_exit()`
- `write()`
- `read()`
- `open()`
- `close()`
- `getpid()`
- `signal()`
- `sigaction()`
- `sigprocmask()`
- `raise()`
- `abort()`

Functions that are **NOT** safe:

- `printf()`, `fprintf()`, `puts()` - use locks
- `malloc()`, `free()` - use locks
- `exit()` - runs atexit handlers
- Anything in C++ standard library
- Most pthread functions

---

## Appendix B: ARM64 Calling Convention Reference

| Register | Role | Preserved |
|----------|------|-----------|
| x0-x7 | Arguments/return | No |
| x8 | Indirect result | No |
| x9-x15 | Temporaries | No |
| x16-x17 | Intra-procedure call | No |
| x18 | Platform register | No |
| x19-x28 | Callee-saved | **Yes** |
| x29 (FP) | Frame pointer | **Yes** |
| x30 (LR) | Link register | No |
| SP | Stack pointer | **Yes** |
| PC | Program counter | N/A |

---

## Appendix C: Signal Numbers Reference

| Signal | Number | Default Action |
|--------|--------|----------------|
| SIGSEGV | 11 | Core dump |
| SIGBUS | 10 | Core dump |
| SIGFPE | 8 | Core dump |
| SIGILL | 4 | Core dump |
| SIGABRT | 6 | Core dump |
| SIGTRAP | 5 | Core dump |

Exit code on signal: `128 + signal_number`
- SIGSEGV: Exit 139
- SIGBUS: Exit 138
- SIGFPE: Exit 136

---

## Document History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-22 | Initial comprehensive specification |
