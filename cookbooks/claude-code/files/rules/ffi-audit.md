# FFI Boundary Audit

Load when a plan touches an FFI boundary (UniFFI Rust↔Swift, JNI Rust↔Kotlin, WASM↔JS, any cross-language schema/value crossing).

The plan MUST include an explicit **encoding audit** subsection that enumerates type/encoding assumptions on BOTH sides before implementation. Structural correctness alone is insufficient — encoding divergence on one side is invisible to the other side's tests.

## Audit checklist

Include as a plan section, with concrete answer per item:

1. **String canonicalization**: any types serialized as strings have a single canonical form on both sides? (e.g., `CBUUID.uuidString` returns short form for Bluetooth-assigned UUIDs while `uuid::Uuid::parse_str` requires 128-bit — mismatch silently fails)
2. **Byte order**: little-endian vs big-endian for multi-byte integers crossing the boundary
3. **Encoding**: UTF-8 vs UTF-16 for strings, lossy vs lossless conversions
4. **Optionality**: how `Option<T>` / `nil` / `null` traverses the boundary (UniFFI nullable annotations, presence-vs-empty-string)
5. **Char limits / truncation**: filename / identifier length caps that differ between sides (e.g., HFS+ vs APFS, FAT32, registry hives)
6. **Numeric ranges**: signed/unsigned coercion at the boundary (e.g., u8 ↔ Int, i64 ↔ Number lossy past 2^53)

For each item, write down the **observed value on each side** and mark **DIVERGE** when they don't match (e.g., `CBUUID.uuidString` short-form vs `Uuid::parse_str` 128-bit form — see `~/.claude/rules/ios-build.md` "CoreBluetooth UUID encoding").

## Origin

2026-04-29 plan assumed existing parse path; iOS `CBUUID.uuidString` diverged, cost a second PR.
