// Reuse the exact host implementation and its tests without linking a second
// fully optimized production executable. This target is never included in release ZIPs.
#[allow(dead_code)]
#[path = "../src/main.rs"]
mod host;
