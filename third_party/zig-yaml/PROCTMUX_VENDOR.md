# zig-yaml Vendor Manifest

Vendored YAML parser for proctmux configuration files.

## Upstream

- Repository: https://github.com/kubkon/zig-yaml
- Branch: `zig-0.15`
- Commit: `5d16badfb0fa7065b999d344ec9fcd1e94cf8530`

## Local Patches

- `src/Parser.zig`, `src/Tokenizer.zig`, `src/Yaml.zig`: literal block
  scalars (`|`) as map values, and unquoted single- and double-quoted map keys.
- `src/Parser/test.zig`: tests for both.

To see the patches, diff these files against the upstream commit. Reapply
them when re-vendoring, and update this manifest's commit.
