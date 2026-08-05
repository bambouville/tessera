// Tessera/Settings/AboutSettingsView.swift
import SwiftUI

/// A license document bundled with the app. GPLv3 §6 requires conveying the
/// license TEXT with the object code (and mosh's COPYING.iOS exception is
/// conditional on providing it), so these render in-app from bundled files —
/// a hyperlink to gnu.org alone would not satisfy the license.
private enum BundledDocument: String, Identifiable, CaseIterable {
    case gpl
    case appStoreException
    case thirdPartyNotices

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gpl: return "GNU GPL v3"
        case .appStoreException: return "app store exception (COPYING.iOS)"
        case .thirdPartyNotices: return "third-party licenses & notices"
        }
    }

    private var resource: (name: String, ext: String?) {
        switch self {
        case .gpl: return ("LICENSE", nil)
        case .appStoreException: return ("COPYING", "iOS")
        case .thirdPartyNotices: return ("ThirdPartyNotices", "txt")
        }
    }

    func loadText() -> String {
        guard let url = Bundle.main.url(forResource: resource.name, withExtension: resource.ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "this document failed to load from the app bundle — please report this build issue at https://github.com/bambouville/tessera/issues"
        }
        return text
    }
}

struct AboutSettingsView: View {
    @Environment(\.designTokens) private var T
    @Environment(\.openURL) private var openURL
    @Environment(OnboardingController.self) private var onboarding

    @State private var presentedDocument: BundledDocument?

    private let sourceURL = URL(string: "https://github.com/bambouville/tessera")!
    private let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsH("about")

            VStack(spacing: 0) {
                TesseraLogo(size: 64)

                Spacer()
                    .frame(height: 16)

                Text("tessera · v" + versionString)
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgMuted)

                Text("build " + buildString)
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgMuted)
                    .padding(.top, 4)

                Btn(style: .default, compact: true, action: { onboarding.startTour() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                        Text("replay walkthrough")
                            .lineLimit(1)
                    }
                }
                .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            license

            acknowledgments
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $presentedDocument) { document in
            BundledDocumentSheet(document: document)
        }
    }

    private var license: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("license")
                .font(Typography.kicker)
                .tracking(0.6)
                .foregroundStyle(T.fgDim)
                .textCase(.uppercase)

            Text("tessera is free software, distributed under the GNU General Public License v3. you may use, study, share, and modify it under the terms of that license.")
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

            Text("© 2026 Bambouville Inc.")
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)

            VStack(alignment: .leading, spacing: 4) {
                linkRow("view source code", systemImage: "chevron.left.forwardslash.chevron.right", url: sourceURL)
                documentRow("view license (GPL-3.0)", systemImage: "doc.text", document: .gpl)
                documentRow("app store exception & trademark notice", systemImage: "doc.text", document: .appStoreException)
                linkRow("gpl-3.0 at gnu.org", systemImage: "safari", url: licenseURL)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 4)
    }

    private func linkRow(_ title: String, systemImage: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(Typography.tesseraMono(size: 12))
            }
            .foregroundStyle(T.accent)
        }
        .buttonStyle(.plain)
    }

    private func documentRow(_ title: String, systemImage: String, document: BundledDocument) -> some View {
        Button {
            presentedDocument = document
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(Typography.tesseraMono(size: 12))
            }
            .foregroundStyle(T.accent)
        }
        .buttonStyle(.plain)
    }

    private var acknowledgments: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("acknowledgments")
                .font(Typography.kicker)
                .tracking(0.6)
                .foregroundStyle(T.fgDim)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 12) {
                creditLine("SwiftTerm", "MIT License")
                creditLine("Citadel", "MIT License")
                creditLine("BigInt", "MIT License")
                creditLine("SwiftNIO SSH", "Apache License 2.0")
                creditLine("SwiftNIO, Swift Crypto & other Swift server libraries", "Apache License 2.0")
                creditLine("Mosh (mobile shell)", "GNU GPL v3")
                creditLine("Protocol Buffers", "BSD 3-Clause License")
                creditLine("JetBrains Mono (bundled terminal font)", "SIL Open Font License 1.1")
                creditLine("Ubuntu, Debian, Linux (Tux) icons", "Font Awesome Free 6.x — CC BY 4.0")
                creditLine("Alpine Linux logo", "Wikimedia Commons — CC0 1.0")
            }

            documentRow("view third-party licenses & notices", systemImage: "doc.on.doc", document: .thirdPartyNotices)
                .padding(.top, 6)
        }
        .padding(.horizontal, 4)
    }

    private func creditLine(_ what: String, _ source: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(what)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fgMuted)
            Text(source)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
        }
    }

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var buildString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}

/// Full-text viewer for a bundled license document. Plain monospaced text in
/// a scroll view — these documents are required reading material, not UI, so
/// fidelity to the file content matters more than styling.
private struct BundledDocumentSheet: View {
    let document: BundledDocument

    @Environment(\.designTokens) private var T
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(document.title)
                    .font(Typography.tesseraMono(size: 13, weight: .medium))
                    .foregroundStyle(T.fg)

                Spacer(minLength: 12)

                Button {
                    dismiss()
                } label: {
                    Text("done")
                        .font(Typography.tesseraMono(size: 12, weight: .medium))
                        .foregroundStyle(T.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(T.border)

            ScrollView {
                Text(document.loadText())
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .background(T.presentationBg)
    }
}
