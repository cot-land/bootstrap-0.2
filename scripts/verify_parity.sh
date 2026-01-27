#!/bin/bash
# Compiler Parity Verification Script
# Compares Zig compiler output vs cot1 compiler output

set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <test.cot> [--verbose]"
    exit 1
fi

TEST_FILE="$1"
VERBOSE="${2:-}"

# Paths
ZIG_COMPILER="./zig-out/bin/cot"
COT1_COMPILER="/tmp/cot1-stage1"

# Check compilers exist
if [ ! -f "$ZIG_COMPILER" ]; then
    echo "ERROR: Zig compiler not found. Run 'zig build' first."
    exit 1
fi

if [ ! -f "$COT1_COMPILER" ]; then
    echo "Building cot1-stage1..."
    $ZIG_COMPILER stages/cot1/main.cot -o $COT1_COMPILER
fi

# Compile with both
echo "=== Compiling: $TEST_FILE ==="

$ZIG_COMPILER "$TEST_FILE" -o /tmp/zig_parity 2>/dev/null
$COT1_COMPILER "$TEST_FILE" -o /tmp/cot1_parity.o 2>/dev/null

# Compare sizes
ZIG_SIZE=$(stat -f%z /tmp/zig_parity.o 2>/dev/null || stat -c%s /tmp/zig_parity.o)
COT1_SIZE=$(stat -f%z /tmp/cot1_parity.o 2>/dev/null || stat -c%s /tmp/cot1_parity.o)

echo "Object sizes: Zig=$ZIG_SIZE bytes, cot1=$COT1_SIZE bytes"

if [ "$ZIG_SIZE" -eq "$COT1_SIZE" ]; then
    echo "Size: MATCH"
else
    DIFF=$((COT1_SIZE - ZIG_SIZE))
    PCT=$((DIFF * 100 / ZIG_SIZE))
    echo "Size: DIFFER by $DIFF bytes ($PCT%)"
fi

# Compare disassembly
objdump -d /tmp/zig_parity.o > /tmp/zig_disasm.txt 2>/dev/null
objdump -d /tmp/cot1_parity.o > /tmp/cot1_disasm.txt 2>/dev/null

# Count differences
DIFF_LINES=$(diff /tmp/zig_disasm.txt /tmp/cot1_disasm.txt 2>/dev/null | grep "^[<>]" | wc -l)

if [ "$DIFF_LINES" -eq "0" ]; then
    echo "Disassembly: IDENTICAL"
    echo "=== PARITY: PASS ==="
    exit 0
else
    echo "Disassembly: $DIFF_LINES lines differ"
    echo "=== PARITY: FAIL ==="

    if [ "$VERBOSE" = "--verbose" ]; then
        echo ""
        echo "=== Differences ==="
        diff /tmp/zig_disasm.txt /tmp/cot1_disasm.txt | head -100
    fi
    exit 1
fi
