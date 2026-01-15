# Cot Language Syntax Reference

**Generated from bootstrap analysis on 2026-01-14**

This document defines the Cot language syntax as implemented in bootstrap-0.2.

---

## Comments

```cot
// Line comment - extends to end of line

/* Block comment - can span
   multiple lines */
```

---

## Literals

### Integer Literals
```cot
42          // Decimal
0xFF        // Hexadecimal prefix
0b1010      // Binary prefix
0o777       // Octal prefix
1_000_000   // With underscores for readability
```

### Floating-Point Literals
```cot
3.14        // Decimal with fractional part
1.0e10      // Scientific notation with exponent
2.5e-3      // Negative exponent
```

### String Literals
```cot
"hello"
"with \"escaped\" quotes"
"newline \n escape"
```

### Character Literals
```cot
'a'
'\n'
'\\'
```

### Boolean Literals
```cot
true
false
```

### Null Literal
```cot
null
```

---

## Variable Declarations

### Immutable Variables (Preferred)
```cot
let x = 42;                    // Type inferred from value
let x: i64 = 42;              // Explicit type annotation
let x: i64;                    // Uninitialized (requires assignment before use)
```

### Mutable Variables
```cot
var x = 42;                    // Mutable, type inferred
var x: i64 = 42;              // Mutable, explicit type
var x: i64;                    // Mutable uninitialized
```

### Constants (Global)
```cot
const MAX_SIZE = 1024;         // Top-level, immutable, evaluated at compile-time
const PI: f64 = 3.14159;       // With explicit type
const COMPUTED = MAX_SIZE * 2; // Constant expressions allowed
```

Constants are evaluated at compile-time and inlined at usage sites (no runtime storage).
Constant expressions can reference other constants and use arithmetic operators.

---

## Function Declarations

### Basic Functions
```cot
fn add(a: i64, b: i64) i64 {
    return a + b;
}

fn greet() {                   // No parameters, no return type (void)
    // statements
}

fn getValue() i64 {            // Return type but no parameters
    return 42;
}

fn process(x: i64) {           // Parameter but no return
    // statements
}
```

### Forward Declarations
```cot
fn recursive(n: i64) i64;      // No body - forward declaration

fn recursive(n: i64) i64 {     // Definition later
    if n <= 1 {
        return 1;
    }
    return n * recursive(n - 1);
}
```

### External Function Declarations
```cot
extern fn open(path: *u8, flags: i32, mode: i32) i32;
extern fn read(fd: i32, buf: *u8, count: i64) i64;
extern fn write(fd: i32, buf: *u8, count: i64) i64;
extern fn close(fd: i32) i32;
```

External functions are resolved by the linker from libc (libSystem on macOS).
The compiler automatically adds the `_` prefix required by Darwin C ABI.

---

## Primitive Types

### Basic Types
```cot
bool         // True/false
void         // No value (return type only)
```

### Explicitly Sized Integer Types
```cot
i8, i16, i32, i64          // Signed integers
u8, u16, u32, u64          // Unsigned integers
```

### Floating-Point Types
```cot
f32         // 32-bit float
f64         // 64-bit float
```

---

## Composite Types

### Pointer Types
```cot
*i64                  // Pointer to i64
*string              // Pointer to string

let ptr: *i64 = &x;
let deref: i64 = ptr.*;
```

### Optional Types (Nullable)
```cot
?i64                  // Optional i64 (can be value or null)
?string              // Optional string

let maybe: ?i64 = null;
let value: ?i64 = 42;
```

### Slice Types (Dynamic Arrays)
```cot
[]i64                 // Slice of i64
[]string             // Slice of strings

let items: []i64 = [1, 2, 3];
```

### Slice Field Access
```cot
let s: string = "hello";
let ptr: *u8 = s.ptr;     // Get underlying pointer
let n: i64 = s.len;       // Get length (same as len(s))
```

Slices are 16-byte structs: pointer at offset 0, length at offset 8.

### Array Types (Fixed Size)
```cot
[10]i64              // Array of 10 i64s
[256]u8              // Array of 256 bytes

let arr: [3]i64 = [1, 2, 3];
```

### Function Types
```cot
fn(i64, i64) i64         // Function: takes two i64s, returns i64
fn() void                // Function: no params, returns void
fn(string) ?i64          // Function: takes string, returns optional i64
```

---

## Structure Types

### Struct Declaration
```cot
struct Point {
    x: i64,
    y: i64,
}

struct Person {
    name: string,
    age: i64,
    email: ?string,      // Optional field
}
```

### Struct Initialization
```cot
let p = Point{ .x = 10, .y = 20 };
```

### Struct Field Access
```cot
let p = Point{ .x = 10, .y = 20 };
let x_val = p.x;
p.x = 15;              // If p is mutable
```

---

## Enum Types

### Basic Enums
```cot
enum Color {
    Red,
    Green,
    Blue,
}

enum Status {
    Pending,
    Active,
    Inactive,
}
```

### Enum Usage
```cot
let color: Color = Color.Red;
```

---

## Union Types (Tagged Unions)

### Union Declaration
```cot
union Result {
    ok,                    // Unit variant (no payload)
    error: string,         // Variant with payload
}

union Option {
    some: i64,
    none,
}
```

---

## Expressions

### Arithmetic Operators
```cot
a + b           // Addition
a - b           // Subtraction
a * b           // Multiplication
a / b           // Division
a % b           // Modulo/Remainder
```

### Bitwise Operators
```cot
a & b           // Bitwise AND
a | b           // Bitwise OR
a ^ b           // Bitwise XOR
~a              // Bitwise NOT
a << b          // Left shift
a >> b          // Right shift
```

### Comparison Operators
```cot
a == b          // Equal
a != b          // Not equal
a < b           // Less than
a <= b          // Less than or equal
a > b           // Greater than
a >= b          // Greater than or equal
```

### Logical Operators
```cot
a and b         // Logical AND (also: a && b)
a or b          // Logical OR (also: a || b)
not a           // Logical NOT (also: !a)
```

### Unary Operators
```cot
-x              // Negation
!x              // Logical NOT
~x              // Bitwise NOT
&x              // Address-of (get pointer)
&arr[i]         // Address of array element
ptr.*           // Dereference pointer
```

### Assignment Operators
```cot
x = 42;
x += 5;         // x = x + 5
x -= 3;         // x = x - 3
x *= 2;         // x = x * 2
x /= 4;         // x = x / 4
```

### Operator Precedence (Highest to Lowest)
1. Postfix: `.field`, `[index]`, `(args)`, `.*`
2. Unary: `-`, `!`, `~`, `&`
3. Multiplicative: `*`, `/`, `%`, `&`, `<<`, `>>`
4. Additive: `+`, `-`, `|`, `^`
5. Comparative: `==`, `!=`, `<`, `<=`, `>`, `>=`
6. Logical AND: `and`, `&&`
7. Logical OR: `or`, `||`
8. Assignment: `=`, `+=`, `-=`, `*=`, `/=`

### Function Calls
```cot
add(10, 20)
greet()
```

### Builtin Functions
```cot
len(s)              // Length of string, array, or slice
len("hello")        // Returns 5
len([1, 2, 3])      // Returns 3
```

### Builtin Operations
```cot
@sizeOf(T)          // Size of type T in bytes (compile-time constant)
@sizeOf(i64)        // Returns 8
@sizeOf(i32)        // Returns 4
@sizeOf(u8)         // Returns 1
@sizeOf(*i64)       // Returns 8 (pointer size)
@sizeOf([4]i64)     // Returns 32 (4 * 8)
@sizeOf(Point)      // Returns struct size

@alignOf(T)         // Alignment of type T in bytes (compile-time constant)
@alignOf(i64)       // Returns 8
@alignOf(u8)        // Returns 1
```

### Array Literals
```cot
[1, 2, 3, 4, 5]
["hello", "world"]
```

### Indexing
```cot
arr[0]                  // First element
arr[5]                  // Sixth element
```

### Field Access
```cot
point.x
person.name
obj.field.nested
```

---

## Statements

### Expression Statement
```cot
x + 5;                  // Expression evaluated for side effects
function_call();
```

### Variable Declaration Statement
```cot
let x = 10;
var y: i64 = 20;
```

### Assignment Statement
```cot
x = 42;
x += 10;
arr[0] = 100;
point.x = 50;
```

### Return Statement
```cot
return;                 // Return from void function
return 42;              // Return value
return a + b;
```

### If Statement
```cot
if condition {
    // statements
}

if condition {
    // then branch
} else {
    // else branch
}

if condition1 {
    // first case
} else if condition2 {
    // second case
} else {
    // default case
}
```

### While Loop
```cot
while x < 10 {
    x = x + 1;
}

while true {
    // infinite loop
    if break_condition {
        break;
    }
}
```

### For-In Loop
```cot
for item in items {
    process(item);
}

for i in [1, 2, 3] {
    print(i);
}
```

### Switch Expression
```cot
// Switch on value - returns result
let result: i64 = switch x {
    1 => 10,
    2 => 20,
    3 => 30,
    else => 99,
};

// Multiple patterns per case
let category: i64 = switch code {
    1, 2 => 100,      // Matches 1 or 2
    3, 4, 5 => 200,   // Matches 3, 4, or 5
    else => 0,
};
```

Switch is an expression that evaluates to the matched case's body. The `else` case handles unmatched values.

### Break Statement
```cot
while true {
    if done {
        break;          // Exit loop
    }
}
```

### Continue Statement
```cot
while x < 10 {
    x = x + 1;
    if skip_condition {
        continue;       // Skip to next iteration
    }
    process(x);
}
```

### Defer Statement
```cot
defer cleanup();        // Run at end of scope

fn process() {
    let resource = open("file");
    defer close(resource);   // Guaranteed to run
    // use resource
}
```

### Block Statement
```cot
{
    let x = 10;
    x = x + 5;
}
```

---

## Keywords

| Category | Keywords |
|----------|----------|
| Declarations | `fn`, `var`, `let`, `const`, `struct`, `enum`, `union`, `type`, `import`, `extern` |
| Control Flow | `if`, `else`, `switch`, `while`, `for`, `in`, `return`, `break`, `continue`, `defer` |
| Literals | `true`, `false`, `null` |
| Logical | `and`, `or`, `not` |
| Types | `bool`, `void`, `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `f32`, `f64` |

---

## Example Programs

### Return Literal
```cot
fn main() i64 {
    return 42;
}
```

### Arithmetic
```cot
fn main() i64 {
    return 20 + 22;
}
```

### Function Calls
```cot
fn add(a: i64, b: i64) i64 {
    return a + b;
}

fn main() i64 {
    return add(20, 22);
}
```

### Conditional
```cot
fn abs(x: i64) i64 {
    if x < 0 {
        return -x;
    }
    return x;
}

fn main() i64 {
    return abs(-42);
}
```

### Loop
```cot
fn sum_to(n: i64) i64 {
    var result: i64 = 0;
    var i: i64 = 0;
    while i <= n {
        result = result + i;
        i = i + 1;
    }
    return result;
}

fn main() i64 {
    return sum_to(9);  // Returns 45
}
```

### Fibonacci
```cot
fn fib(n: i64) i64 {
    if n <= 1 {
        return n;
    }
    return fib(n - 1) + fib(n - 2);
}

fn main() i64 {
    return fib(10);  // Returns 55
}
```

### Struct
```cot
struct Point {
    x: i64,
    y: i64,
}

fn distance_squared(p: Point) i64 {
    return p.x * p.x + p.y * p.y;
}

fn main() i64 {
    let p = Point{ .x = 3, .y = 4 };
    return distance_squared(p);  // Returns 25
}
```

### Dynamic Memory Allocation
```cot
// Declare external C functions
extern fn malloc(size: i64) *i64;
extern fn free(ptr: *i64);

fn main() i64 {
    // Allocate memory using @sizeOf
    let ptr: *i64 = malloc(@sizeOf(i64));

    // Store value through pointer
    ptr.* = 42;

    // Read back
    let result: i64 = ptr.*;

    // Free memory
    free(ptr);

    return result;  // Returns 42
}
```

---

## Implementation Status

| Feature | Parser | Type Check | Codegen | Status |
|---------|--------|------------|---------|--------|
| Integer literals | Yes | Yes | Yes | ✅ Working |
| Arithmetic (+, -, *, /) | Yes | Yes | Yes | ✅ Working |
| Return statement | Yes | Yes | Yes | ✅ Working |
| Function declarations | Yes | Yes | Yes | ✅ Working |
| Function calls | Yes | Yes | Yes | ✅ Working |
| Local variables | Yes | Yes | TODO | In Progress |
| Comparisons | Yes | Yes | TODO | In Progress |
| If/else | Yes | Yes | TODO | In Progress |
| While loops | Yes | Yes | TODO | In Progress |
| Structs | Yes | Yes | TODO | Phase 3 |
| Enums | Yes | Yes | TODO | Phase 3 |
| Pointers | Yes | Yes | TODO | Phase 3 |
| Arrays/Slices | Yes | Yes | TODO | Phase 3 |

### Test Progress

See `test/e2e/all_tests.cot` for the full test suite.

**Current:** 110 e2e tests passing

Core language complete: arithmetic, functions, control flow, structs, arrays, slices, pointers, enums, bitwise/logical operators, for-in loops, string operations, extern functions.
