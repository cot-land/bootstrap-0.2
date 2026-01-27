#!/usr/bin/env python3
"""
Convert parity tests from main() return pattern to inline test syntax.

Before:
    fn helper() i64 { ... }
    fn main() i64 {
        // setup
        if condition { return 0; }
        return 1;
    }

After:
    fn helper() i64 { ... }
    test "descriptive name" {
        // setup
        @assert(condition)
    }
"""

import os
import re
import sys

def extract_test_name(filename):
    """Convert filename to descriptive test name."""
    # expr_001_add.cot -> "expression: add"
    # cf_001_if.cot -> "control flow: if"
    # fn_020_nth_fib.cot -> "function: nth fib"

    base = os.path.basename(filename).replace('.cot', '')

    # Category prefixes
    prefixes = {
        'expr': 'expression',
        'cf': 'control flow',
        'fn': 'function',
        'ty': 'type',
        'arr': 'array',
        'mem': 'memory',
        'var': 'variable',
    }

    # Extract parts: prefix_NNN_name
    match = re.match(r'([a-z]+)_\d+_(.+)', base)
    if match:
        prefix, name = match.groups()
        category = prefixes.get(prefix, prefix)
        # Convert underscores to spaces
        name = name.replace('_', ' ')
        return f"{category}: {name}"

    # Fallback: just use the filename
    return base.replace('_', ' ')

def convert_main_to_test(content, test_name):
    """Convert main() function to test block."""

    # Pattern 1: Simple one-line main
    # fn main() i64 { if condition { return 0; } return 1; }
    simple_main = re.search(
        r'fn main\(\) i64 \{ if (.+?) \{ return 0; \} return 1; \}',
        content
    )

    if simple_main:
        condition = simple_main.group(1)
        # Replace the main function with test block
        new_content = content[:simple_main.start()]
        new_content += f'test "{test_name}" {{\n    @assert({condition})\n}}'
        new_content += content[simple_main.end():]
        return new_content

    # Pattern 2: Multi-line main with setup
    # Find main function boundaries
    main_match = re.search(r'fn main\(\) i64 \{', content)
    if not main_match:
        print(f"Warning: No main() found in file")
        return content

    # Find the matching closing brace
    start = main_match.end()
    brace_count = 1
    pos = start
    while pos < len(content) and brace_count > 0:
        if content[pos] == '{':
            brace_count += 1
        elif content[pos] == '}':
            brace_count -= 1
        pos += 1

    main_body = content[start:pos-1].strip()

    # Extract the final assertion pattern
    # if condition { return 0; } return 1;
    assertion_match = re.search(
        r'if (.+?) \{ return 0; \}\s*\n?\s*return 1;$',
        main_body,
        re.DOTALL
    )

    if assertion_match:
        condition = assertion_match.group(1).strip()
        setup = main_body[:assertion_match.start()].strip()

        # Build the test block
        new_content = content[:main_match.start()]
        new_content += f'test "{test_name}" {{\n'
        if setup:
            # Indent setup code, preserving block structure
            indent_level = 1
            for line in setup.split('\n'):
                stripped = line.strip()
                if not stripped:
                    continue
                # Adjust indent for closing braces before printing
                if stripped.startswith('}'):
                    indent_level -= stripped.count('}') - stripped.count('{')
                    if indent_level < 1:
                        indent_level = 1
                new_content += '    ' * indent_level + stripped + '\n'
                # Adjust indent for opening braces after printing
                if stripped.endswith('{') and not stripped.startswith('}'):
                    indent_level += 1
        new_content += f'    @assert({condition})\n'
        new_content += '}'
        new_content += content[pos:]
        return new_content

    # Fallback: couldn't parse main body
    print(f"Warning: Could not parse main() body")
    return content

def convert_file(filepath, dry_run=False):
    """Convert a single parity test file."""
    with open(filepath, 'r') as f:
        content = f.read()

    test_name = extract_test_name(filepath)
    new_content = convert_main_to_test(content, test_name)

    if dry_run:
        print(f"=== {filepath} ===")
        print(new_content)
        print()
        return True

    if new_content != content:
        with open(filepath, 'w') as f:
            f.write(new_content)
        return True
    return False

def main():
    import argparse
    parser = argparse.ArgumentParser(description='Convert parity tests to inline syntax')
    parser.add_argument('paths', nargs='+', help='Files or directories to convert')
    parser.add_argument('--dry-run', '-n', action='store_true',
                        help='Print converted output without modifying files')
    args = parser.parse_args()

    converted = 0
    failed = 0

    for path in args.paths:
        if os.path.isfile(path):
            files = [path]
        else:
            files = []
            for root, dirs, filenames in os.walk(path):
                for f in filenames:
                    if f.endswith('.cot'):
                        files.append(os.path.join(root, f))

        for filepath in sorted(files):
            try:
                if convert_file(filepath, args.dry_run):
                    converted += 1
                    if not args.dry_run:
                        print(f"Converted: {filepath}")
            except Exception as e:
                print(f"Error: {filepath}: {e}")
                failed += 1

    print(f"\nConverted: {converted}, Failed: {failed}")

if __name__ == '__main__':
    main()
