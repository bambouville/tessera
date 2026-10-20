package com.bambouville.tessera.files

internal object RemoteFileQuickView {
    // Keep extension recognition aligned with iOS MarkdownPreviewSupport.
    private val markdownExtensions = setOf(
        "md", "markdown", "mdown", "mkdn", "mkd", "mdwn",
        "mdtext", "mdtxt", "rmd", "qmd",
    )

    fun isMarkdown(displayName: String): Boolean {
        val basename = displayName.substringAfterLast('/').substringAfterLast('\\')
        return basename.substringAfterLast('.', "").lowercase() in markdownExtensions
    }
}
