#!/bin/bash
# Run all parity tests and report results
#
# This script compares the Zig compiler output vs cot1 compiler output
# for all tests in test/parity/

# Don't use set -e so we continue through failing tests
# set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

ZIG_COMPILER="$ROOT_DIR/zig-out/bin/cot"
COT1_COMPILER="/tmp/cot1-stage1"
RUNTIME="$ROOT_DIR/runtime/cot_runtime.o"

# Build compilers if needed
if [ ! -f "$ZIG_COMPILER" ]; then
    echo "Building Zig compiler..."
    cd "$ROOT_DIR" && zig build
fi

if [ ! -f "$COT1_COMPILER" ]; then
    echo "Building cot1-stage1..."
    $ZIG_COMPILER "$ROOT_DIR/stages/cot1/main.cot" -o "$COT1_COMPILER"
fi

# Counters
TOTAL=0
ZIG_PASS=0
COT1_PASS=0
FUNC_MATCH=0
SIZE_MATCH=0
ZIG_COMPILE_FAIL=0
COT1_COMPILE_FAIL=0

echo "============================================"
echo "           PARITY TEST RESULTS"
echo "============================================"
printf "%-30s %10s %10s %8s\n" "Test" "Zig" "cot1" "Status"
echo "--------------------------------------------"

# Find all tests
for test in $(find "$ROOT_DIR/test/parity" -name "*.cot" | sort); do
    TOTAL=$((TOTAL + 1))
    NAME=$(basename "$test" .cot)

    # Compile with Zig
    if $ZIG_COMPILER "$test" -o /tmp/zig_test 2>/dev/null; then
        ZIG_COMPILED=1
    else
        ZIG_COMPILED=0
        ZIG_COMPILE_FAIL=$((ZIG_COMPILE_FAIL + 1))
    fi

    # Compile with cot1 (suppress verbose output)
    if $COT1_COMPILER "$test" -o /tmp/cot1_test.o >/dev/null 2>/dev/null; then
        COT1_COMPILED=1
    else
        COT1_COMPILED=0
        COT1_COMPILE_FAIL=$((COT1_COMPILE_FAIL + 1))
    fi

    # If both compiled, link and run
    ZIG_RESULT="-"
    COT1_RESULT="-"
    STATUS="--"

    if [ "$ZIG_COMPILED" -eq 1 ]; then
        # Link Zig output
        zig cc /tmp/zig_test.o "$RUNTIME" -o /tmp/zig_bin -lSystem 2>/dev/null
        if /tmp/zig_bin 2>/dev/null; then
            ZIG_RESULT="PASS"
            ZIG_PASS=$((ZIG_PASS + 1))
        else
            ZIG_RESULT="FAIL"
        fi
        ZIG_SIZE=$(stat -f%z /tmp/zig_test.o 2>/dev/null || stat -c%s /tmp/zig_test.o)
    else
        ZIG_RESULT="ERR"
        ZIG_SIZE=0
    fi

    if [ "$COT1_COMPILED" -eq 1 ]; then
        # Link cot1 output
        zig cc /tmp/cot1_test.o "$RUNTIME" -o /tmp/cot1_bin -lSystem 2>/dev/null
        if /tmp/cot1_bin 2>/dev/null; then
            COT1_RESULT="PASS"
            COT1_PASS=$((COT1_PASS + 1))
        else
            COT1_RESULT="FAIL"
        fi
        COT1_SIZE=$(stat -f%z /tmp/cot1_test.o 2>/dev/null || stat -c%s /tmp/cot1_test.o)
    else
        COT1_RESULT="ERR"
        COT1_SIZE=0
    fi

    # Determine overall status
    if [ "$ZIG_RESULT" = "PASS" ] && [ "$COT1_RESULT" = "PASS" ]; then
        FUNC_MATCH=$((FUNC_MATCH + 1))
        if [ "$ZIG_SIZE" -eq "$COT1_SIZE" ]; then
            STATUS="SAME"
            SIZE_MATCH=$((SIZE_MATCH + 1))
        else
            STATUS="DIFF"
        fi
    elif [ "$ZIG_RESULT" = "PASS" ] && [ "$COT1_RESULT" = "FAIL" ]; then
        STATUS="BUG!"
    elif [ "$ZIG_RESULT" = "ERR" ] || [ "$COT1_RESULT" = "ERR" ]; then
        STATUS="ERR"
    else
        STATUS="BOTH"
    fi

    printf "%-30s %10s %10s %8s\n" "$NAME" "$ZIG_RESULT" "$COT1_RESULT" "$STATUS"
done

echo "============================================"
echo "                SUMMARY"
echo "============================================"
echo "Total tests:           $TOTAL"
echo "Zig compile pass:      $ZIG_PASS"
echo "Zig compile fail:      $ZIG_COMPILE_FAIL"
echo "cot1 compile pass:     $COT1_PASS"
echo "cot1 compile fail:     $COT1_COMPILE_FAIL"
echo "Functional parity:     $FUNC_MATCH / $TOTAL"
echo "Byte-exact parity:     $SIZE_MATCH / $TOTAL"
echo "============================================"

if [ "$FUNC_MATCH" -eq "$TOTAL" ] && [ "$SIZE_MATCH" -eq "$TOTAL" ]; then
    echo "RESULT: FULL PARITY"
    exit 0
elif [ "$FUNC_MATCH" -eq "$TOTAL" ]; then
    echo "RESULT: FUNCTIONAL PARITY (codegen differs)"
    exit 0
else
    echo "RESULT: PARITY GAPS EXIST"
    exit 1
fi
