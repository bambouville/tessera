// The dumper prints installer sources and never renders Markdown. The real
// AgentMarkdownDocument needs swift-markdown, which this single swiftc
// invocation cannot import, so the runtime's two cache hooks resolve here.
enum AgentMarkdownDocument {
    static func purgeCache() {}
    static func sizeCache(for budget: AgentContentBudget) {}
}
