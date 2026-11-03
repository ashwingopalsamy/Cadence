// CadenceIngest: envelope/1 validation and ingest, the collector runner, map/1, and the
// built-in GitHub and Claude Code transcript collectors (docs/SPEC.md section 10).
// Depends on CadenceCore only. Filled in during phase 2.
import CadenceCore

public enum CadenceIngest {
    public static let envelopeFormat = "envelope/1"
    public static let mapFormat = "map/1"
}
