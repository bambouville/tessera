import Crypto
import NIOSSH
import PortForwarding
import SwiftData
import XCTest
@testable import Tessera

@MainActor
final class BootstrapManifestAdapterTests: XCTestCase {
    private enum InjectedFailure: Error, Equatable {
        case save
    }

    private func makeTempKnownHostsStore() -> KnownHostsStore {
        KnownHostsStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "tessera-bootstrap-known-hosts-\(UUID().uuidString).json"
            ),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func makeHostKey() throws -> NIOSSHPublicKey {
        let key = Curve25519.Signing.PrivateKey()
        let line = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: key.publicKey,
            comment: "bootstrap-test"
        )
        return try NIOSSHPublicKey(
            openSSHPublicKey: line.split(separator: " ").prefix(2)
                .joined(separator: " ")
        )
    }

    func test_exportCarriesPortableConfigurationButNoCredentialMaterial() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let identityID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let bastionID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let targetID = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        let forwardID = UUID(uuidString: "20000000-0000-0000-0000-000000000004")!
        let identity = Identity(
            id: identityID,
            name: "operations",
            user: "legacy-user",
            credentialMode: .password
        )
        let bastion = PersistedHost(
            id: bastionID,
            name: "atlas",
            address: "atlas.example.invalid",
            port: 2_222,
            transport: .ssh,
            launchMode: .autoTmux,
            sortOrder: 1
        )
        bastion.user = "jump-user"
        let target = PersistedHost(
            id: targetID,
            name: "zeus",
            address: "zeus.example.invalid",
            port: 22,
            transport: .mosh,
            launchMode: .pinnedTmux,
            tmuxSessionName: "dev",
            sortOrder: 2,
            identity: identity
        )
        target.user = "deploy"
        target.tags = ["production", "gpu"]
        target.osHint = "ubuntu"
        target.notes = "primary deployment host"
        target.envVars = "LANG=en_US.UTF-8\nFEATURE_FLAG=enabled"
        target.startupSnippet = "cd ~/deploy"
        target.launchCommand = "exec fish -l"
        target.setPortForwardRules([
            PortForwardRule(
                id: forwardID,
                enabled: true,
                autoStart: false,
                localPort: 8_080,
                remoteHost: "localhost",
                remotePort: 80,
                label: "web"
            )
        ])
        context.insert(identity)
        context.insert(bastion)
        context.insert(target)
        context.insert(HostJumpLink(hostID: targetID, jumpHostID: bastionID))
        try context.save()
        let knownHosts = makeTempKnownHostsStore()
        let bastionKey = try makeHostKey()
        let targetKey = try makeHostKey()
        await knownHosts.trust(
            bastionKey,
            for: "atlas.example.invalid:2222"
        )
        await knownHosts.trust(
            targetKey,
            for: "atlas.example.invalid:2222→zeus.example.invalid:22"
        )

        let appearance = AppearancePreferences()
        let restoreAppearance = PortableAppearanceSnapshot(appearance)
        defer { restoreAppearance.restore(to: appearance) }
        setDistinctPortableAppearance(appearance)

        let manifest = try await BootstrapManifestAdapter.export(
            from: context,
            appearance: appearance,
            knownHosts: knownHosts
        )

        XCTAssertEqual(Set(manifest.identities.map(\.id)), [identityID])
        XCTAssertEqual(Set(manifest.hosts.map(\.id)), [bastionID, targetID])
        XCTAssertEqual(
            manifest.jumpChains,
            [BootstrapJumpLink(hostID: targetID, jumpHostID: bastionID)]
        )
        let exportedTarget = try XCTUnwrap(manifest.hosts.first { $0.id == targetID })
        XCTAssertEqual(exportedTarget.user, "deploy")
        XCTAssertEqual(exportedTarget.transport, .mosh)
        XCTAssertEqual(exportedTarget.launchMode, .pinnedTmux)
        XCTAssertEqual(exportedTarget.tmuxSessionName, "dev")
        XCTAssertEqual(exportedTarget.authenticationHint, .password)
        XCTAssertEqual(exportedTarget.identityID, identityID)
        XCTAssertEqual(exportedTarget.tags, ["production", "gpu"])
        XCTAssertEqual(exportedTarget.notes, "primary deployment host")
        XCTAssertEqual(
            exportedTarget.envVars,
            "LANG=en_US.UTF-8\nFEATURE_FLAG=enabled"
        )
        XCTAssertEqual(exportedTarget.startupSnippet, "cd ~/deploy")
        XCTAssertEqual(exportedTarget.launchCommand, "exec fish -l")
        XCTAssertEqual(exportedTarget.portForwards.count, 1)
        XCTAssertEqual(exportedTarget.portForwards[0].id, forwardID)
        XCTAssertEqual(manifest.appearance.colorScheme, "light")
        XCTAssertEqual(manifest.settings.modifierBehavior, "sticky")
        XCTAssertEqual(
            Set((manifest.knownHosts ?? []).map(\.hostID)),
            [bastionID, targetID]
        )
        XCTAssertEqual(
            (manifest.knownHosts ?? []).first { $0.hostID == targetID }?.fingerprint,
            KnownHostsStore.fingerprint(of: targetKey)
        )

        let wire = String(decoding: try manifest.encoded(), as: UTF8.self)
        XCTAssertTrue(wire.contains("primary deployment host"))
        XCTAssertTrue(wire.contains("FEATURE_FLAG"))
        XCTAssertTrue(wire.contains("cd ~/deploy"))
        XCTAssertTrue(wire.contains("exec fish -l"))
        XCTAssertFalse(wire.localizedCaseInsensitiveContains("password\":"))

        let defaultWireManifest = try manifest.selectingOptionalTransfers([])
        let defaultTarget = try XCTUnwrap(
            defaultWireManifest.hosts.first { $0.id == targetID }
        )
        XCTAssertNil(defaultTarget.launchCommand)
        XCTAssertNil(defaultTarget.notes)
        XCTAssertNil(defaultTarget.envVars)
        XCTAssertNil(defaultTarget.startupSnippet)
        XCTAssertNil(defaultTarget.hostKeyFingerprint)
        XCTAssertTrue((defaultWireManifest.knownHosts ?? []).isEmpty)
        let defaultWire = String(
            decoding: try defaultWireManifest.encoded(),
            as: UTF8.self
        )
        XCTAssertFalse(defaultWire.contains("primary deployment host"))
        XCTAssertFalse(defaultWire.contains("FEATURE_FLAG"))
        XCTAssertFalse(defaultWire.contains("cd ~/deploy"))
        XCTAssertFalse(defaultWire.contains("exec fish -l"))

        let selectedWireManifest = try manifest.selectingOptionalTransfers([
            .environmentVariables,
            .trustedHostKeys,
        ])
        let selectedTarget = try XCTUnwrap(
            selectedWireManifest.hosts.first { $0.id == targetID }
        )
        XCTAssertNil(selectedTarget.launchCommand)
        XCTAssertNil(selectedTarget.notes)
        XCTAssertEqual(
            selectedTarget.envVars,
            "LANG=en_US.UTF-8\nFEATURE_FLAG=enabled"
        )
        XCTAssertNil(selectedTarget.startupSnippet)
        XCTAssertEqual(
            selectedTarget.hostKeyFingerprint,
            KnownHostsStore.fingerprint(of: targetKey)
        )
        XCTAssertEqual(
            Set((selectedWireManifest.knownHosts ?? []).map(\.hostID)),
            [bastionID, targetID]
        )
    }

    func test_defaultApprovedWireCannotPersistAnExportedTrustedHost() async throws {
        let sourceContainer = try TesseraModelContainer.make(inMemory: true)
        let sourceContext = ModelContext(sourceContainer)
        let host = PersistedHost(
            name: "Pinned source",
            address: "pinned-source.example.invalid",
            port: 22,
            transport: .ssh,
            launchMode: .autoTmux
        )
        host.user = "ops"
        sourceContext.insert(host)
        try sourceContext.save()

        let sourceKnownHosts = makeTempKnownHostsStore()
        let hostKey = try makeHostKey()
        await sourceKnownHosts.trust(hostKey, for: "pinned-source.example.invalid:22")
        let exported = try await BootstrapManifestAdapter.export(
            from: sourceContext,
            appearance: AppearancePreferences(),
            knownHosts: sourceKnownHosts
        )
        XCTAssertEqual(exported.knownHosts?.count, 1)
        XCTAssertNotNil(exported.hosts.first?.hostKeyFingerprint)

        let approved = try ApprovedBootstrapManifest(
            exportedManifest: exported,
            selectedOptionalTransfers: []
        )
        let received = try BootstrapManifest.decode(approved.manifest.encoded())
        XCTAssertTrue((received.knownHosts ?? []).isEmpty)
        XCTAssertNil(received.hosts.first?.hostKeyFingerprint)

        let destinationContainer = try TesseraModelContainer.make(inMemory: true)
        let destinationContext = ModelContext(destinationContainer)
        let destinationKnownHosts = makeTempKnownHostsStore()
        let suiteName = "BootstrapManifestAdapterTests.defaultWire.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let destinationAppearance = AppearancePreferences()
        let restoreAppearance = PortableAppearanceSnapshot(destinationAppearance)
        defer { restoreAppearance.restore(to: destinationAppearance) }

        let receipt = try await BootstrapManifestAdapter.apply(
            received,
            fromPeer: "Nearby iPad",
            to: destinationContext,
            appearance: destinationAppearance,
            trustHints: BootstrapTrustHintStore(defaults: defaults),
            provenance: BootstrapImportProvenanceStore(defaults: defaults),
            knownHosts: destinationKnownHosts
        )

        XCTAssertEqual(receipt.insertedHosts, 1)
        XCTAssertEqual(receipt.insertedKnownHosts, 0)
        let importedTrust = await destinationKnownHosts.trustedRecord(
            for: "pinned-source.example.invalid:22"
        )
        XCTAssertNil(importedTrust)
        XCTAssertNil(BootstrapTrustHintStore(defaults: defaults).hint(for: host.id))
    }

    func test_applyIsCredentialFreeIdempotentAndPersistsTrustHintAndJumpLink() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let appearance = AppearancePreferences()
        let restoreAppearance = PortableAppearanceSnapshot(appearance)
        defer { restoreAppearance.restore(to: appearance) }
        let suiteName = "BootstrapManifestAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let trustStore = BootstrapTrustHintStore(defaults: defaults)
        let provenanceStore = BootstrapImportProvenanceStore(defaults: defaults)
        let manifest = makeManifest()

        let first = try await BootstrapManifestAdapter.apply(
            manifest,
            fromPeer: "Nearby iPad",
            to: context,
            appearance: appearance,
            trustHints: trustStore,
            provenance: provenanceStore
        )

        XCTAssertEqual(first.insertedHosts, 2)
        XCTAssertEqual(first.skippedExistingHosts, 0)
        XCTAssertEqual(first.insertedIdentities, 1)
        XCTAssertEqual(first.insertedJumpLinks, 1)
        XCTAssertEqual(first.insertedHostIDs, Set(manifest.hosts.map(\.id)))
        XCTAssertTrue(provenanceStore.hasInterruptedImport)

        let hosts = try context.fetch(FetchDescriptor<PersistedHost>())
        let targetID = manifest.hosts[0].id
        let target = try XCTUnwrap(hosts.first { $0.id == targetID })
        XCTAssertEqual(target.name, "zeus")
        XCTAssertEqual(target.transport, .mosh)
        XCTAssertEqual(target.launchMode, .pinnedTmux)
        XCTAssertEqual(target.tmuxSessionName, "dev")
        XCTAssertEqual(target.tags, ["production"])
        XCTAssertEqual(target.notes, "deployment notes")
        XCTAssertEqual(target.envVars, "LANG=C")
        XCTAssertEqual(target.startupSnippet, "cd /srv/app")
        XCTAssertEqual(target.launchCommand, "exec fish -l")
        XCTAssertEqual(target.identity?.id, manifest.identities[0].id)
        XCTAssertEqual(target.identity?.credentialMode, CredentialMode.none)
        XCTAssertEqual(RuleCodec.decode(target.portForwardRulesData).count, 1)
        XCTAssertEqual(
            HostJumpChainResolver.resolve(for: target, in: context).hops.map(\.id),
            [manifest.hosts[1].id]
        )
        XCTAssertEqual(
            trustStore.hint(for: targetID),
            BootstrapTrustHint(
                fingerprint: "SHA256:public-fingerprint",
                peerDeviceName: "Nearby iPad"
            )
        )
        XCTAssertEqual(appearance.mode, .dark)
        XCTAssertEqual(appearance.accent, .green)
        XCTAssertEqual(appearance.modifierBehavior, "sticky")
        XCTAssertEqual(appearance.filesDefaultDestination, "cwd")

        let second = try await BootstrapManifestAdapter.apply(
            manifest,
            fromPeer: "Nearby iPad",
            to: context,
            appearance: appearance,
            trustHints: trustStore,
            provenance: provenanceStore
        )
        XCTAssertEqual(second.insertedHosts, 0)
        XCTAssertEqual(second.skippedExistingHosts, 2)
        XCTAssertEqual(second.insertedIdentities, 0)
        XCTAssertEqual(second.insertedJumpLinks, 0)
        XCTAssertTrue(second.insertedHostIDs.isEmpty)
        XCTAssertEqual(second.acceptedHostIDs, Set(manifest.hosts.map(\.id)))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersistedHost>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Identity>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HostJumpLink>()), 1)

        target.identity?.credentialMode = .key(UUID())
        try context.save()
        try BootstrapManifestAdapter.refreshImportProvenance(
            for: manifest,
            in: context,
            provenance: provenanceStore
        )
        let afterProtocolPromotion = try await BootstrapManifestAdapter.apply(
            manifest,
            fromPeer: "Nearby iPad",
            to: context,
            appearance: appearance,
            trustHints: trustStore,
            provenance: provenanceStore
        )
        XCTAssertTrue(afterProtocolPromotion.acceptedHostIDs.contains(targetID))

        target.identity?.credentialMode = .password
        try context.save()
        let afterLocalCredentialChoice = try await BootstrapManifestAdapter.apply(
            manifest,
            fromPeer: "Nearby iPad",
            to: context,
            appearance: appearance,
            trustHints: trustStore,
            provenance: provenanceStore
        )
        XCTAssertFalse(afterLocalCredentialChoice.acceptedHostIDs.contains(targetID))
        XCTAssertTrue(
            afterLocalCredentialChoice.acceptedHostIDs.contains(manifest.hosts[1].id)
        )
        XCTAssertEqual(target.identity?.credentialMode, .password)
        try provenanceStore.markComplete(manifest)
        XCTAssertFalse(provenanceStore.hasInterruptedImport)
    }

    func test_exportUsesAddressWhenHostDisplayNameIsEmpty() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let host = PersistedHost(
            name: "   ",
            address: "address-only.example.invalid",
            port: 22,
            transport: .ssh,
            launchMode: .autoTmux
        )
        host.user = "ops"
        context.insert(host)
        try context.save()

        let manifest = try await BootstrapManifestAdapter.export(
            from: context,
            appearance: AppearancePreferences()
        )

        XCTAssertEqual(manifest.hosts.count, 1)
        XCTAssertEqual(manifest.hosts[0].name, "address-only.example.invalid")
        XCTAssertNoThrow(try manifest.validate())
    }

    func test_exportDoesNotOfferHostWhoseConfiguredKeyMaterialIsMissing() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let missingKeyID = UUID()
        let identity = Identity(
            name: "missing key",
            user: "ops",
            credentialMode: .key(missingKeyID)
        )
        let host = PersistedHost(
            name: "unreachable",
            address: "unreachable.example.invalid",
            identity: identity
        )
        host.user = "ops"
        context.insert(identity)
        context.insert(host)
        try context.save()

        let manifest = try await BootstrapManifestAdapter.export(
            from: context,
            appearance: AppearancePreferences()
        )

        XCTAssertEqual(
            manifest.hosts.first?.authenticationHint,
            BootstrapAuthenticationHint.none
        )
    }

    func test_exportSkipsMalformedHostsAndTheirDependentRoutes() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let good = PersistedHost(name: "good", address: "good.example", port: 22)
        good.user = "ops"
        let malformed = PersistedHost(name: "bad", address: "", port: 0)
        let brokenBastion = PersistedHost(name: "bad jump", address: "", port: 22)
        let dependent = PersistedHost(name: "dependent", address: "private.example", port: 22)
        let unusedIdentity = Identity(name: "unused", user: "ops")
        for value in [good, malformed, brokenBastion, dependent] {
            context.insert(value)
        }
        context.insert(unusedIdentity)
        context.insert(HostJumpLink(hostID: dependent.id, jumpHostID: brokenBastion.id))
        try context.save()

        let manifest = try await BootstrapManifestAdapter.export(
            from: context,
            appearance: AppearancePreferences()
        )

        XCTAssertEqual(manifest.hosts.map(\.id), [good.id])
        XCTAssertTrue(manifest.jumpChains.isEmpty)
        XCTAssertTrue(manifest.identities.isEmpty)
        XCTAssertNoThrow(try manifest.encoded())
    }

    func test_failedImportSaveLeavesNoImportSideEffectsOrOrphans() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let unrelated = PersistedHost(name: "unsaved local edit", address: "local.example")
        context.insert(unrelated)
        let appearance = AppearancePreferences()
        let restoreAppearance = PortableAppearanceSnapshot(appearance)
        defer { restoreAppearance.restore(to: appearance) }
        appearance.mode = .light
        appearance.accent = .amber
        let suiteName = "BootstrapManifestAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let trustStore = BootstrapTrustHintStore(defaults: defaults)
        let manifest = makeManifest()

        do {
            _ = try await BootstrapManifestAdapter.apply(
                manifest,
                fromPeer: "Nearby iPad",
                to: context,
                appearance: appearance,
                trustHints: trustStore,
                provenance: BootstrapImportProvenanceStore(defaults: defaults),
                save: { _ in throw InjectedFailure.save }
            )
            XCTFail("Expected the injected save failure")
        } catch {
            XCTAssertEqual(error as? InjectedFailure, .save)
        }

        let hosts = try context.fetch(FetchDescriptor<PersistedHost>())
        XCTAssertEqual(hosts.map(\.id), [unrelated.id])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Identity>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HostJumpLink>()), 0)
        XCTAssertEqual(appearance.mode, .light)
        XCTAssertEqual(appearance.accent, .amber)
        for host in manifest.hosts {
            XCTAssertNil(trustStore.hint(for: host.id))
        }
    }

    func test_importClonesCollidingIdentityWithoutReusingLocalCredential() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let appearance = AppearancePreferences()
        let manifest = makeManifest()
        let identityID = manifest.identities[0].id
        let localIdentity = Identity(
            id: identityID,
            name: "local password",
            user: "local",
            credentialMode: .password
        )
        context.insert(localIdentity)
        try context.save()

        let receipt = try await BootstrapManifestAdapter.apply(
            manifest,
            fromPeer: "Nearby iPad",
            to: context,
            appearance: appearance
        )

        let hosts = try context.fetch(FetchDescriptor<PersistedHost>())
        let imported = try XCTUnwrap(hosts.first { $0.id == manifest.hosts[0].id })
        XCTAssertEqual(receipt.insertedHostIDs, Set(manifest.hosts.map(\.id)))
        XCTAssertNotEqual(imported.identity?.id, localIdentity.id)
        XCTAssertEqual(imported.identity?.credentialMode, CredentialMode.none)
        XCTAssertEqual(localIdentity.credentialMode, .password)
    }

    func test_importSkipsDependentRouteWhenPeerHostIDCollidesLocally() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let appearance = AppearancePreferences()
        let manifest = makeManifest()
        let collidingBastionID = manifest.hosts[1].id
        let localBastion = PersistedHost(
            id: collidingBastionID,
            name: "local bastion",
            address: "local-only.example.invalid"
        )
        context.insert(localBastion)
        try context.save()

        let receipt = try await BootstrapManifestAdapter.apply(
            manifest,
            fromPeer: "Nearby iPad",
            to: context,
            appearance: appearance
        )

        XCTAssertEqual(receipt.insertedHosts, 0)
        XCTAssertEqual(receipt.skippedExistingHosts, manifest.hosts.count)
        XCTAssertTrue(receipt.insertedHostIDs.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersistedHost>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HostJumpLink>()), 0)
        XCTAssertEqual(localBastion.address, "local-only.example.invalid")
    }

    func test_importsKnownHostPinsAndSkipsIdenticalPinsOnRetry() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let appearance = AppearancePreferences()
        let suiteName = "BootstrapManifestAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let knownHosts = makeTempKnownHostsStore()
        let bastionKey = try makeHostKey()
        let targetKey = try makeHostKey()
        let manifest = manifest(
            makeManifest(),
            knownHostKeys: [
                makeManifest().hosts[1].id: bastionKey,
                makeManifest().hosts[0].id: targetKey
            ]
        )

        let first = try await BootstrapManifestAdapter.apply(
            manifest,
            fromPeer: "Nearby iPad",
            to: context,
            appearance: appearance,
            trustHints: BootstrapTrustHintStore(defaults: defaults),
            provenance: BootstrapImportProvenanceStore(defaults: defaults),
            knownHosts: knownHosts
        )

        XCTAssertEqual(first.insertedKnownHosts, 2)
        XCTAssertEqual(first.skippedKnownHosts, 0)
        XCTAssertEqual(first.conflictingKnownHosts, 0)
        if case .trusted = await knownHosts.check(
            bastionKey,
            for: "atlas.example.invalid:2222"
        ) {} else {
            XCTFail("bastion pin was not imported")
        }
        if case .trusted = await knownHosts.check(
            targetKey,
            for: "atlas.example.invalid:2222→zeus.example.invalid:22"
        ) {} else {
            XCTFail("routed target pin was not imported")
        }

        let second = try await BootstrapManifestAdapter.apply(
            manifest,
            fromPeer: "Nearby iPad",
            to: context,
            appearance: appearance,
            trustHints: BootstrapTrustHintStore(defaults: defaults),
            provenance: BootstrapImportProvenanceStore(defaults: defaults),
            knownHosts: knownHosts
        )
        XCTAssertEqual(second.insertedKnownHosts, 0)
        XCTAssertEqual(second.skippedKnownHosts, 2)
        XCTAssertEqual(second.conflictingKnownHosts, 0)
    }

    func test_importPreservesConflictingLocalKnownHostPin() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let appearance = AppearancePreferences()
        let suiteName = "BootstrapManifestAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let knownHosts = makeTempKnownHostsStore()
        let incomingKey = try makeHostKey()
        let localKey = try makeHostKey()
        let base = makeManifest()
        let targetID = base.hosts[0].id
        let manifest = manifest(base, knownHostKeys: [targetID: incomingKey])
        await knownHosts.trust(
            localKey,
            for: "atlas.example.invalid:2222→zeus.example.invalid:22"
        )

        let receipt = try await BootstrapManifestAdapter.apply(
            manifest,
            fromPeer: "Nearby iPad",
            to: context,
            appearance: appearance,
            trustHints: BootstrapTrustHintStore(defaults: defaults),
            provenance: BootstrapImportProvenanceStore(defaults: defaults),
            knownHosts: knownHosts
        )

        XCTAssertEqual(receipt.insertedKnownHosts, 0)
        XCTAssertEqual(receipt.skippedKnownHosts, 0)
        XCTAssertEqual(receipt.conflictingKnownHosts, 1)
        let rows = await knownHosts.list()
        let targetRow = try XCTUnwrap(rows.first {
            $0.id == "atlas.example.invalid:2222→zeus.example.invalid:22"
        })
        XCTAssertEqual(
            targetRow.fingerprint,
            KnownHostsStore.fingerprint(of: localKey)
        )
        XCTAssertEqual(
            targetRow.pendingFingerprint,
            KnownHostsStore.fingerprint(of: incomingKey)
        )
        XCTAssertEqual(
            targetRow.pendingKeyString,
            String(openSSHPublicKey: incomingKey)
        )
    }

    func test_plannedInsertionsReportsNewHostsAndWholeRouteClosures() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let suiteName = "BootstrapManifestAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provenanceStore = BootstrapImportProvenanceStore(defaults: defaults)
        let manifest = makeManifest()
        let targetID = manifest.hosts[0].id
        let bastionID = manifest.hosts[1].id

        let plan = try BootstrapManifestAdapter.plannedInsertions(
            manifest,
            to: context,
            provenance: provenanceStore
        )

        XCTAssertEqual(plan.newHostIDs, [targetID, bastionID])
        XCTAssertEqual(plan.routes.count, 2)
        let targetRoute = try XCTUnwrap(plan.routes.first { $0.id == targetID })
        XCTAssertEqual(targetRoute.name, "zeus")
        XCTAssertEqual(targetRoute.address, "zeus.example.invalid")
        XCTAssertEqual(targetRoute.closureHostIDs, [targetID, bastionID])
        let bastionRoute = try XCTUnwrap(plan.routes.first { $0.id == bastionID })
        XCTAssertEqual(bastionRoute.name, "atlas")
        XCTAssertEqual(bastionRoute.address, "atlas.example.invalid")
        XCTAssertEqual(bastionRoute.closureHostIDs, [bastionID])
        // Planning is read-only: no rows and no retry provenance.
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersistedHost>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Identity>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HostJumpLink>()), 0)
        XCTAssertFalse(provenanceStore.hasInterruptedImport)
    }

    func test_plannedInsertionsExcludesExistingAndRouteIneligibleHosts() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let suiteName = "BootstrapManifestAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provenanceStore = BootstrapImportProvenanceStore(defaults: defaults)
        let base = makeManifest()
        let standaloneID = UUID(uuidString: "30000000-0000-0000-0000-000000000004")!
        let manifest = BootstrapManifest(
            identities: base.identities,
            hosts: base.hosts + [
                BootstrapHostDescriptor(
                    id: standaloneID,
                    name: "hera",
                    address: "hera.example.invalid",
                    user: "ops",
                    transport: .ssh,
                    launchMode: .autoTmux
                )
            ],
            jumpChains: base.jumpChains,
            appearance: base.appearance,
            settings: base.settings
        )
        let collidingBastion = PersistedHost(
            id: base.hosts[1].id,
            name: "local bastion",
            address: "local-only.example.invalid"
        )
        context.insert(collidingBastion)
        try context.save()

        let plan = try BootstrapManifestAdapter.plannedInsertions(
            manifest,
            to: context,
            provenance: provenanceStore
        )

        // The colliding bastion is unavailable, which also makes the routed
        // target ineligible; only the standalone host remains insertable.
        XCTAssertEqual(plan.newHostIDs, [standaloneID])
        XCTAssertEqual(plan.routes, [
            BootstrapImportPlan.Route(
                id: standaloneID,
                name: "hera",
                address: "hera.example.invalid",
                closureHostIDs: [standaloneID]
            )
        ])
    }

    func test_finalAdmissionValidator_blocksMutationWhenQuotaChanged() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let appearance = AppearancePreferences()
        let restoreAppearance = PortableAppearanceSnapshot(appearance)
        defer { restoreAppearance.restore(to: appearance) }

        do {
            _ = try await BootstrapManifestAdapter.apply(
                makeManifest(),
                fromPeer: "Nearby iPad",
                to: context,
                appearance: appearance,
                finalAdmissionValidator: { _ in false }
            )
            XCTFail("expected the stale admission to abort")
        } catch let error as BootstrapImportAdmissionError {
            XCTAssertEqual(error, .stateChanged)
        }

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersistedHost>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Identity>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HostJumpLink>()), 0)
    }

    func test_restrictedImportPersistsTheChosenClosureWithItsIdentityAndJumpLink() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let appearance = AppearancePreferences()
        let restoreAppearance = PortableAppearanceSnapshot(appearance)
        defer { restoreAppearance.restore(to: appearance) }
        let suiteName = "BootstrapManifestAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let trustStore = BootstrapTrustHintStore(defaults: defaults)
        let provenanceStore = BootstrapImportProvenanceStore(defaults: defaults)
        let manifest = makeManifest()
        let targetID = manifest.hosts[0].id
        let bastionID = manifest.hosts[1].id

        // The intended caller flow: plan, then restrict to a route's closure.
        let plan = try BootstrapManifestAdapter.plannedInsertions(
            manifest,
            to: context,
            provenance: provenanceStore
        )
        let targetRoute = try XCTUnwrap(plan.routes.first { $0.id == targetID })
        let receipt = try await BootstrapManifestAdapter.apply(
            manifest,
            fromPeer: "Nearby iPad",
            to: context,
            appearance: appearance,
            trustHints: trustStore,
            provenance: provenanceStore,
            restrictTo: targetRoute.closureHostIDs
        )

        XCTAssertEqual(receipt.insertedHosts, 2)
        XCTAssertEqual(receipt.skippedExistingHosts, 0)
        XCTAssertEqual(receipt.insertedIdentities, 1)
        XCTAssertEqual(receipt.insertedJumpLinks, 1)
        XCTAssertEqual(receipt.insertedHostIDs, [targetID, bastionID])
        XCTAssertEqual(receipt.acceptedHostIDs, [targetID, bastionID])
        let hosts = try context.fetch(FetchDescriptor<PersistedHost>())
        XCTAssertEqual(Set(hosts.map(\.id)), [targetID, bastionID])
        let target = try XCTUnwrap(hosts.first { $0.id == targetID })
        XCTAssertEqual(target.identity?.id, manifest.identities[0].id)
        XCTAssertEqual(
            HostJumpChainResolver.resolve(for: target, in: context).hops.map(\.id),
            [bastionID]
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Identity>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HostJumpLink>()), 1)
        XCTAssertEqual(
            trustStore.hint(for: targetID),
            BootstrapTrustHint(
                fingerprint: "SHA256:public-fingerprint",
                peerDeviceName: "Nearby iPad"
            )
        )
        XCTAssertEqual(appearance.mode, .dark)
    }

    func test_restrictedImportSkipsUnchosenHostsWithoutTheirDependencies() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let appearance = AppearancePreferences()
        let restoreAppearance = PortableAppearanceSnapshot(appearance)
        defer { restoreAppearance.restore(to: appearance) }
        let suiteName = "BootstrapManifestAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let trustStore = BootstrapTrustHintStore(defaults: defaults)
        let provenanceStore = BootstrapImportProvenanceStore(defaults: defaults)
        let manifest = makeManifest()
        let targetID = manifest.hosts[0].id
        let bastionID = manifest.hosts[1].id

        // The bastion is a pure destination of its own route: its closure is
        // itself alone, so the identity and jump link of the excluded target
        // must not be inserted either.
        let receipt = try await BootstrapManifestAdapter.apply(
            manifest,
            fromPeer: "Nearby iPad",
            to: context,
            appearance: appearance,
            trustHints: trustStore,
            provenance: provenanceStore,
            restrictTo: [bastionID]
        )

        XCTAssertEqual(receipt.insertedHosts, 1)
        XCTAssertEqual(receipt.skippedExistingHosts, 1)
        XCTAssertEqual(receipt.insertedIdentities, 0)
        XCTAssertEqual(receipt.insertedJumpLinks, 0)
        XCTAssertEqual(receipt.insertedHostIDs, [bastionID])
        XCTAssertEqual(receipt.acceptedHostIDs, [bastionID])
        let hosts = try context.fetch(FetchDescriptor<PersistedHost>())
        XCTAssertEqual(hosts.map(\.id), [bastionID])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Identity>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HostJumpLink>()), 0)
        XCTAssertNil(trustStore.hint(for: targetID))
    }

    func test_restrictedImportWithIncompleteClosureThrowsBeforeMutation() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let appearance = AppearancePreferences()
        let restoreAppearance = PortableAppearanceSnapshot(appearance)
        defer { restoreAppearance.restore(to: appearance) }
        appearance.mode = .light
        let suiteName = "BootstrapManifestAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let trustStore = BootstrapTrustHintStore(defaults: defaults)
        let provenanceStore = BootstrapImportProvenanceStore(defaults: defaults)
        let manifest = makeManifest()
        let targetID = manifest.hosts[0].id
        let bastionID = manifest.hosts[1].id

        // The destination without its jump host is not a whole route.
        do {
            _ = try await BootstrapManifestAdapter.apply(
                manifest,
                fromPeer: "Nearby iPad",
                to: context,
                appearance: appearance,
                trustHints: trustStore,
                provenance: provenanceStore,
                restrictTo: [targetID]
            )
            XCTFail("Expected an incomplete-route restriction error")
        } catch {
            XCTAssertEqual(
                error as? BootstrapImportRestrictionError,
                .incompleteRoute(hostID: targetID, missingAncestorID: bastionID)
            )
        }

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersistedHost>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Identity>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HostJumpLink>()), 0)
        XCTAssertFalse(provenanceStore.hasInterruptedImport)
        XCTAssertNil(trustStore.hint(for: targetID))
        XCTAssertEqual(appearance.mode, .light)
    }

    func test_plannedInsertionsDoesNotDoubleChargeDurableRetryRows() async throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let appearance = AppearancePreferences()
        let restoreAppearance = PortableAppearanceSnapshot(appearance)
        defer { restoreAppearance.restore(to: appearance) }
        let suiteName = "BootstrapManifestAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let trustStore = BootstrapTrustHintStore(defaults: defaults)
        let provenanceStore = BootstrapImportProvenanceStore(defaults: defaults)
        let manifest = makeManifest()

        // The rows landed but the attempt was interrupted before completion,
        // so retry provenance still describes them. A retry plan must not
        // charge those durable rows as new insertions again.
        let receipt = try await BootstrapManifestAdapter.apply(
            manifest,
            fromPeer: "Nearby iPad",
            to: context,
            appearance: appearance,
            trustHints: trustStore,
            provenance: provenanceStore
        )
        XCTAssertEqual(receipt.insertedHosts, 2)
        XCTAssertTrue(provenanceStore.hasInterruptedImport)

        let interruptedPlan = try BootstrapManifestAdapter.plannedInsertions(
            manifest,
            to: context,
            provenance: provenanceStore
        )
        XCTAssertTrue(interruptedPlan.newHostIDs.isEmpty)
        XCTAssertTrue(interruptedPlan.routes.isEmpty)

        try provenanceStore.markComplete(manifest)
        let completedPlan = try BootstrapManifestAdapter.plannedInsertions(
            manifest,
            to: context,
            provenance: provenanceStore
        )
        XCTAssertTrue(completedPlan.newHostIDs.isEmpty)
        XCTAssertTrue(completedPlan.routes.isEmpty)
    }

    private func manifest(
        _ base: BootstrapManifest,
        knownHostKeys: [UUID: NIOSSHPublicKey]
    ) -> BootstrapManifest {
        let seen = Date(timeIntervalSince1970: 1_690_000_000)
        return BootstrapManifest(
            identities: base.identities,
            hosts: base.hosts,
            jumpChains: base.jumpChains,
            knownHosts: knownHostKeys.map { hostID, key in
                BootstrapKnownHostDescriptor(
                    hostID: hostID,
                    fingerprint: KnownHostsStore.fingerprint(of: key),
                    keyString: String(openSSHPublicKey: key),
                    firstSeen: seen,
                    lastSeen: seen.addingTimeInterval(3_600)
                )
            },
            appearance: base.appearance,
            settings: base.settings
        )
    }

    private func makeManifest() -> BootstrapManifest {
        let identityID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let targetID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let bastionID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        return BootstrapManifest(
            identities: [
                BootstrapIdentityDescriptor(
                    id: identityID,
                    name: "operations",
                    user: "deploy"
                )
            ],
            hosts: [
                BootstrapHostDescriptor(
                    id: targetID,
                    name: "zeus",
                    address: "zeus.example.invalid",
                    user: "deploy",
                    transport: .mosh,
                    launchMode: .pinnedTmux,
                    tmuxSessionName: "dev",
                    tags: ["production"],
                    osHint: "ubuntu",
                    sortOrder: 1,
                    authenticationHint: .publicKey,
                    identityID: identityID,
                    hostKeyFingerprint: "SHA256:public-fingerprint",
                    launchCommand: "exec fish -l",
                    notes: "deployment notes",
                    envVars: "LANG=C",
                    startupSnippet: "cd /srv/app",
                    portForwards: [
                        BootstrapPortForwardRule(
                            id: UUID(),
                            enabled: true,
                            autoStart: false,
                            localPort: 8_080,
                            remoteHost: "localhost",
                            remotePort: 80,
                            label: "web"
                        )
                    ]
                ),
                BootstrapHostDescriptor(
                    id: bastionID,
                    name: "atlas",
                    address: "atlas.example.invalid",
                    port: 2_222,
                    user: "jump-user",
                    transport: .ssh,
                    launchMode: .autoTmux
                )
            ],
            jumpChains: [
                BootstrapJumpLink(hostID: targetID, jumpHostID: bastionID)
            ],
            appearance: BootstrapAppearanceSettings(
                colorScheme: "dark",
                accent: "green",
                customAccentRGB: 0x12_34_56,
                monospacedFontName: "JetBrainsMono-Regular",
                terminalFontSize: 15,
                chromeMaterial: "solid",
                cursorStyle: "underline",
                cursorBlink: false,
                terminalThemeID: "nord"
            ),
            settings: BootstrapGeneralSettings(
                scrollbackLines: 20_000,
                modifierBehavior: "sticky",
                bellSoundEnabled: true,
                bellVisualEnabled: false,
                bellNotificationEnabled: false,
                accessoryBarKeys: ["esc", "ctrl"],
                filesReaperDays: 30,
                filesDefaultDestination: "cwd"
            )
        )
    }

    private func setDistinctPortableAppearance(_ appearance: AppearancePreferences) {
        appearance.mode = .light
        appearance.accent = .amber
        appearance.customAccentRGB = 0x65_43_21
        appearance.monoFontName = "Menlo-Regular"
        appearance.fontSize = 16
        appearance.chromeMaterial = .solid
        appearance.cursorStyle = .bar
        appearance.cursorBlink = false
        appearance.terminalThemeID = "paper"
        appearance.scrollbackLines = 22_000
        appearance.modifierBehavior = "sticky"
        appearance.bellSoundEnabled = true
        appearance.bellVisualEnabled = false
        appearance.bellNotificationEnabled = false
        appearance.accessoryBarKeys = ["esc", "tab"]
        appearance.filesReaperDays = 14
        appearance.filesDefaultDestination = "cwd"
    }
}

@MainActor
private struct PortableAppearanceSnapshot {
    let mode: AppearanceModeOption
    let accent: AccentName
    let customAccentRGB: Int
    let monoFontName: String
    let fontSize: Double
    let chromeMaterial: ChromeMaterial
    let cursorStyle: CursorStyleOption
    let cursorBlink: Bool
    let terminalThemeID: String
    let scrollbackLines: Int
    let modifierBehavior: String
    let bellSoundEnabled: Bool
    let bellVisualEnabled: Bool
    let bellNotificationEnabled: Bool
    let accessoryBarKeys: [String]
    let filesReaperDays: Int
    let filesDefaultDestination: String

    init(_ appearance: AppearancePreferences) {
        mode = appearance.mode
        accent = appearance.accent
        customAccentRGB = appearance.customAccentRGB
        monoFontName = appearance.monoFontName
        fontSize = appearance.fontSize
        chromeMaterial = appearance.chromeMaterial
        cursorStyle = appearance.cursorStyle
        cursorBlink = appearance.cursorBlink
        terminalThemeID = appearance.terminalThemeID
        scrollbackLines = appearance.scrollbackLines
        modifierBehavior = appearance.modifierBehavior
        bellSoundEnabled = appearance.bellSoundEnabled
        bellVisualEnabled = appearance.bellVisualEnabled
        bellNotificationEnabled = appearance.bellNotificationEnabled
        accessoryBarKeys = appearance.accessoryBarKeys
        filesReaperDays = appearance.filesReaperDays
        filesDefaultDestination = appearance.filesDefaultDestination
    }

    func restore(to appearance: AppearancePreferences) {
        appearance.mode = mode
        appearance.accent = accent
        appearance.customAccentRGB = customAccentRGB
        appearance.monoFontName = monoFontName
        appearance.fontSize = fontSize
        appearance.chromeMaterial = chromeMaterial
        appearance.cursorStyle = cursorStyle
        appearance.cursorBlink = cursorBlink
        appearance.terminalThemeID = terminalThemeID
        appearance.scrollbackLines = scrollbackLines
        appearance.modifierBehavior = modifierBehavior
        appearance.bellSoundEnabled = bellSoundEnabled
        appearance.bellVisualEnabled = bellVisualEnabled
        appearance.bellNotificationEnabled = bellNotificationEnabled
        appearance.accessoryBarKeys = accessoryBarKeys
        appearance.filesReaperDays = filesReaperDays
        appearance.filesDefaultDestination = filesDefaultDestination
    }
}
