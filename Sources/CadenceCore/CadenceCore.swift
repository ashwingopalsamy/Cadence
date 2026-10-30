// CadenceCore: the rulebook every Cadence process links.
//
// Module boundaries (docs/SPEC.md section 8.5):
//
//   CadenceCore    domain types, store and migrations, ledger and canonical JSON,
//                  projections, parsers, presence, insights, findings, proof.
//                  Builds on Linux and macOS. No AppKit, no networking, and it
//                  never reads the wall clock, the environment or the process
//                  table directly: Clock, FileRoots, RandomSource and
//                  ProcessRunner are injected.
//   CadenceIngest  envelopes, the collector runner, map/1, built-in collectors.
//                  Depends on CadenceCore only.
//   CadenceMCP     JSON-RPC over stdio and the MCP tool surface.
//                  Depends on CadenceCore and CadenceIngest.
//   cadence        the CLI. The only Linux-safe target allowed to create the
//                  system implementations (SystemClock, the real process runner).
//   CadenceUI, CadenceApp   macOS only.

/// Version strings written into the ledger and into proof files.
public enum CadenceVersion {
    public static let app = "0.0.0"
    public static let generator = "Cadence \(app)"
}
