# Research Plan: Go -> CGo -> Zig Shared Library Integration

## Main Question
How to call libghostty-vt (a Zig library with C-ABI exports) from Go via CGo?

## Subtopics
1. CGo fundamentals for shared/static libraries - directives, linking, LDFLAGS/CFLAGS
2. Real-world Go+Zig projects on GitHub - examples and patterns
3. Build system, cross-compilation, and distribution
4. Memory management and concurrency across Go/C/Zig boundary
5. Ghostty-vt specific API and integration considerations
