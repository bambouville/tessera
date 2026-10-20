/// Optional privacy-safe diagnostics hook shared by the parser and the
/// platform observation adapter. Portable consumers may leave it unset.
public enum TmuxDiagnostics {
    public static var sink: ((String) -> Void)?
}
