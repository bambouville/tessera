import Foundation

public enum ArtifactsKind: String, Codable, Equatable, Sendable, CaseIterable {
    case docs, pages, changes, files

    public static func `for`(path: String) -> ArtifactsKind {
        let ext = ArtifactsViewer.pathExtension(path)
        if ArtifactsViewer.markdownExtensions.contains(ext) || proseExtensions.contains(ext) { return .docs }
        if ["html", "htm"].contains(ext) { return .pages }
        return .files
    }

    private static let proseExtensions: Set<String> = ["txt", "rst", "adoc", "org"]
}

public enum ArtifactsViewer: String, Codable, Equatable, Sendable {
    case markdown, html, web, image, pdf, text, diff, other

    // Superset of MarkdownPreviewSupport and RemoteFileQuickView.
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkdn", "mkd", "mdwn", "mdtext", "mdtxt", "rmd", "qmd", "mdx",
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "svg", "ico",
    ]
    private static let textExtensions: Set<String> = [
        "txt", "rst", "adoc", "org", "log", "csv", "tsv", "json", "jsonl", "xml", "yaml", "yml",
        "toml", "ini", "conf", "config", "env", "sh", "bash", "zsh", "fish", "swift", "kt", "kts",
        "java", "js", "jsx", "ts", "tsx", "css", "scss", "less", "py", "rb", "rs", "go", "c", "h",
        "cc", "cpp", "hpp", "m", "mm", "cs", "sql", "graphql", "proto", "lua", "pl", "php",
        "r", "dart", "vue", "svelte", "ex", "exs", "erl", "hrl", "clj", "cljs", "edn", "lock",
    ]

    public static func `for`(path: String, mimeHint: String? = nil) -> ArtifactsViewer {
        let ext = pathExtension(path)
        if markdownExtensions.contains(ext) { return .markdown }
        if ["html", "htm"].contains(ext) { return .html }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if ["diff", "patch"].contains(ext) { return .diff }
        if textExtensions.contains(ext) { return .text }
        let name = path.split(separator: "/").last?.lowercased() ?? ""
        if ["readme", "license", "copying", "makefile", "dockerfile", ".gitignore", ".env"].contains(name) {
            return .text
        }
        let mime = mimeHint?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ["text/markdown", "text/x-markdown"].contains(mime) { return .markdown }
        if ["text/html", "application/xhtml+xml"].contains(mime) { return .html }
        if mime.hasPrefix("image/") { return .image }
        if mime == "application/pdf" { return .pdf }
        if ["text/x-diff", "text/x-patch"].contains(mime) { return .diff }
        if mime.hasPrefix("text/") || ["application/json", "application/xml", "application/javascript"].contains(mime) {
            return .text
        }
        return .other
    }

    static func pathExtension(_ path: String) -> String {
        let name = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last ?? ""
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}
