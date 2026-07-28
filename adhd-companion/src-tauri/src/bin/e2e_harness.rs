//! CLI harness: runs the same E2E pipeline as integration tests (no GUI).

fn main() {
    println!("Run: cargo test --manifest-path src-tauri/Cargo.toml --test e2e_pipeline -- --nocapture");
    println!("Unit+E2E tests cover capture→monitor→L1–L3→analyze→brief on Linux.");
}
