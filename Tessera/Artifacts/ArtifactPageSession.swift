import Observation
import SwiftUI
import TesseraArtifactsCore

struct BrowserPageIdentity: Equatable {
    let tabID: String
    let url: URL
    let handlerID: ObjectIdentifier?
    /// The tab's address submissions: a new one loads `url` again.
    var navigation = 0
}

@MainActor
struct BrowserPageSession {
    let identity: BrowserPageIdentity
    let model: ArtifactWebViewModel
}

/// Each browser surface owns one session; a workspace shares its session
/// between the retained slot and its sheet. Metadata does not replace a page.
@MainActor @Observable
final class ArtifactPageSession {
    private(set) var session: BrowserPageSession?

    func pageIdentity(for tab: ArtifactTab?, store: any ArtifactsBrowserStore) -> BrowserPageIdentity? {
        guard let tab else { return nil }
        switch store.content(for: tab.id) {
        case let .servedPage(url, registration):
            return .init(tabID: tab.id, url: url, handlerID: ObjectIdentifier(registration.handler),
                         navigation: store.pageNavigation(for: tab.id))
        case let .forwardedPage(url, _, _):
            return .init(tabID: tab.id, url: url,
                         handlerID: previewRegistration(tab.id, store: store).map { ObjectIdentifier($0.handler) },
                         navigation: store.pageNavigation(for: tab.id))
        default: return nil
        }
    }

    func webModel(for tab: ArtifactTab?, store: any ArtifactsBrowserStore) -> ArtifactWebViewModel? {
        session?.identity == pageIdentity(for: tab, store: store) ? session?.model : nil
    }

    func updatePageSession(for tab: ArtifactTab?, store: any ArtifactsBrowserStore) {
        guard let identity = pageIdentity(for: tab, store: store) else {
            end()
            return
        }
        guard session?.identity != identity else { return }
        // A tab's edited address on the same origin loads in its web view,
        // as a browser's does, keeping its history for back.
        if let current = session, current.identity.tabID == identity.tabID,
           current.identity.handlerID == identity.handlerID,
           Self.sameOrigin(current.identity.url, identity.url), current.model.containsInOrigin(identity.url) {
            current.model.load(identity.url)
            session = .init(identity: identity, model: current.model)
            return
        }
        end()
        let registration: ArtifactWebSchemeRegistration?
        if case let .servedPage(_, value) = store.content(for: identity.tabID) { registration = value }
        else { registration = previewRegistration(identity.tabID, store: store) }
        session = .init(identity: identity,
                        model: ArtifactWebViewModel(url: identity.url, schemeRegistration: registration))
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }

    func stop() { session?.model.stop() }

    func end() {
        session?.model.discard()
        session = nil
    }

    func refresh(_ tab: ArtifactTab?, store: any ArtifactsBrowserStore) {
        guard let tab else { return }
        if store.filesReconnect(for: tab.id) != nil {
            store.connectFiles(tab.id)
            return
        }
        guard store.presentation(for: tab.id).canRefresh || store.canRetry(tab.id), store.isLive(hostID: tab.hostID) else { return }
        let isServedPage: Bool
        if case .servedPage = store.content(for: tab.id) { isServedPage = true }
        else { isServedPage = false }
        store.refresh(tab.id)
        // Served HTML reloads when its replacement snapshot is accepted.
        if !isServedPage { webModel(for: tab, store: store)?.reload() }
    }

    private func previewRegistration(_ tabID: String, store: any ArtifactsBrowserStore) -> ArtifactWebSchemeRegistration? {
        #if DEBUG
        return (store as? ArtifactsBrowserPreviewStore)?.registration(for: tabID)
        #else
        return nil
        #endif
    }
}

extension EnvironmentValues {
    @Entry var artifactSurfaceVisible = true
    @Entry var artifactPresentationObscured = false
    /// The regular shell's sidebar is hidden: the address bar leads with its
    /// show control, so the page needs no strip above it for the floating one.
    @Entry var artifactsRevealSidebar: DuoSwitcherAction? = nil
}

struct ArtifactCoveringSheetPreferenceKey: PreferenceKey {
    static var defaultValue: Bool { false }

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// The store follows one visible tab. A disappearing or opacity-hidden
/// surface releases only its own claim, so it cannot clear another browser.
@MainActor
final class ArtifactVisibilitySession {
    private struct Claim {
        let tabID: String
        let priority: Int
    }

    @MainActor
    private final class Entry {
        weak var store: (any ArtifactsBrowserStore)?
        var claims: [UUID: Claim] = [:]
        var publishedID: String?

        init(store: any ArtifactsBrowserStore) { self.store = store }

        func publish(force: Bool) {
            let next = claims.sorted {
                $0.value.priority == $1.value.priority
                    ? $0.key.uuidString < $1.key.uuidString : $0.value.priority > $1.value.priority
            }.first?.value.tabID
            if next != publishedID || (force && next != nil) {
                publishedID = next
                store?.noteVisible(next)
            }
        }
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]
    private let id = UUID()
    private var storeID: ObjectIdentifier?

    func update(_ tabID: String?, store: any ArtifactsBrowserStore, priority: Int = 0, force: Bool = false) {
        let key = ObjectIdentifier(store)
        if storeID != key { release() }
        guard let tabID else { release(); return }
        Self.entries = Self.entries.filter { $0.value.store != nil }
        let entry = Self.entries[key] ?? Entry(store: store)
        Self.entries[key] = entry
        storeID = key
        entry.claims[id] = Claim(tabID: tabID, priority: priority)
        entry.publish(force: force)
    }

    func release() {
        guard let key = storeID, let entry = Self.entries[key] else { storeID = nil; return }
        storeID = nil
        entry.claims[id] = nil
        entry.publish(force: false)
        if entry.claims.isEmpty { Self.entries[key] = nil }
    }
}
