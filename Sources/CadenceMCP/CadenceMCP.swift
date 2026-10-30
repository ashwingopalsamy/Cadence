// CadenceMCP: JSON-RPC 2.0 over stdio, the tool registry and both MCP protocol revisions
// (docs/SPEC.md section 9.2). Filled in during phase 2.
import CadenceCore
import CadenceIngest

public enum CadenceMCP {
    /// Protocol revisions this server speaks, newest first.
    public static let supportedRevisions = ["2026-07-28", "2025-11-25"]
}
