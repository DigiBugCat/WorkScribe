# Native text-processing dependency notices

`Cargo.lock` is from FluidInference/text-processing-rs v0.3.1. `crates.json`
records its complete registry dependency set (a conservative superset including
dev/build/other-platform dependencies), each archive checksum, declared license,
and the retained license/notice files. Each archive was verified against the
lockfile before its notices were extracted. Identical texts are stored once in
`texts/`, named by SHA-256. The crate names and notice-file mappings preserve
attribution. These sources are not fetched by bootstrap: SwiftPM downloads the
precompiled native framework pinned in FluidAudio's manifest.
