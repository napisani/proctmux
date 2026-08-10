# Research Plan: libghostty-vt Deep Technical Analysis

## Main Question
What are the specific technical details, API surface, capabilities, build system, and ecosystem of libghostty-vt — sufficient to assess investment viability today?

## Subtopics

### 1. Source Code & C API (GitHub)
- Find lib_vt.zig, ghostty.h, C API headers
- Document exported function signatures
- Understand memory management model

### 2. Blog Posts & Official Documentation
- Mitchell Hashimoto's blog posts on library decomposition
- Timeline for API stability
- Platform/target support

### 3. Third-Party Bindings & Ecosystem
- Search for Go, Rust, Python, C bindings
- Any projects using libghostty-vt as a dependency
- Community adoption signals

### 4. Technical Capabilities & VT Features
- Sixel, kitty graphics, OSC, DCS support
- Alt screen buffer, mouse events, scroll regions
- SIMD parsing details

### 5. Build System & Cross-Compilation
- How to produce .a / .so files
- Dependencies (libc?)
- Cross-compilation targets

### 6. Comparison to libvterm
- Benchmarks
- Feature gap analysis
- Architecture differences
