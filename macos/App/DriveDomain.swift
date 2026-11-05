import AppKit
import FileProvider
import Foundation

/// Owns File Provider domains for every configured cloud provider.
///
/// One extension binary can serve many domains. The domain identifier is the
/// routing key: the extension maps it to a provider in `ProviderCatalog`, and
/// each provider gets an independent backend URL, item-id namespace and cache.
enum DriveDomain {
    private static let enabledProvidersKey = "enabledProviderIDs"
    private static let legacySchemaKey = "driveSchemaVersion"
    private static let namingDomainID = NSFileProviderDomainIdentifier("plinth-naming-anchor")
    @MainActor private static var didBootstrap = false

    private static func schemaKey(_ provider: DriveProvider) -> String {
        "driveSchemaVersion.\(provider.id)"
    }

    private static func displayNameKey(_ provider: DriveProvider) -> String {
        "driveDisplayName.\(provider.id)"
    }

    private static func storedDisplayName(_ provider: DriveProvider) -> String {
        UserDefaults(suiteName: Credentials.appGroup)?.string(forKey: displayNameKey(provider))
            ?? provider.displayName
    }

    private static func domain(_ provider: DriveProvider, displayName: String? = nil) -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: provider.domainID,
            displayName: displayName ?? storedDisplayName(provider)
        )
    }

    /// Finder collapses a single File Provider domain to the host app name
    /// ("Plinth"). Keep one hidden domain registered so visible domains retain
    /// Finder's "Plinth - {domain display name}" presentation even when only one
    /// cloud provider is configured.
    @MainActor
    private static func ensureNamingAnchor(existing: [NSFileProviderDomain]) async {
        if existing.contains(where: { $0.identifier == namingDomainID }) { return }
        let anchor = NSFileProviderDomain(identifier: namingDomainID, displayName: "Internal")
        anchor.isHidden = true
        try? await NSFileProviderManager.add(anchor)
    }

    private static func enabledProviderIDs() -> Set<String> {
        let defaults = UserDefaults(suiteName: Credentials.appGroup)
        return Set(defaults?.stringArray(forKey: enabledProvidersKey) ?? [])
    }

    private static func setEnabled(_ provider: DriveProvider, _ enabled: Bool) {
        guard let defaults = UserDefaults(suiteName: Credentials.appGroup) else { return }
        var ids = Set(defaults.stringArray(forKey: enabledProvidersKey) ?? [])
        if enabled { ids.insert(provider.id) } else { ids.remove(provider.id) }
        defaults.set(Array(ids).sorted(), forKey: enabledProvidersKey)
    }

    /// Registers only providers that the user has enabled. On upgrade from the
    /// old single-domain build, an existing `plinth-drive` is adopted as Quark so
    /// the user's current Finder drive keeps working without a destructive reset.
    @MainActor
    static func registerEnabled() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        var existing = (try? await NSFileProviderManager.domains()) ?? []
        await ensureNamingAnchor(existing: existing)
        existing = (try? await NSFileProviderManager.domains()) ?? existing
        var enabled = enabledProviderIDs()
        if enabled.isEmpty,
           let quark = ProviderCatalog.provider(id: "quark"),
           existing.contains(where: { $0.identifier == quark.domainID }) {
            enabled.insert(quark.id)
            setEnabled(quark, true)
        }

        // Old accidental domains are safe to remove regardless of whether their
        // replacement is currently enabled.
        let legacyIDs = Set(ProviderCatalog.all.flatMap(\.legacyDomainIdentifiers))
        for legacy in existing where legacyIDs.contains(legacy.identifier.rawValue) {
            try? await NSFileProviderManager.remove(legacy)
            NSLog("[plinth] removed legacy domain \(legacy.identifier.rawValue)")
        }

        // Healthy providers are registered by the host after reading their
        // current AList display names from the bridge.
    }

    /// Add or refresh one provider domain. Safe to call repeatedly.
    @MainActor
    @discardableResult
    static func register(_ provider: DriveProvider, displayName: String? = nil) async -> Bool {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedDisplayName = trimmed.isEmpty ? provider.displayName : trimmed
        let target = domain(provider, displayName: resolvedDisplayName)
        let defaults = UserDefaults(suiteName: Credentials.appGroup)
        let key = schemaKey(provider)
        let nameKey = displayNameKey(provider)
        var known = defaults?.integer(forKey: key) ?? 0
        let knownDisplayName = defaults?.string(forKey: nameKey)

        // Migrate the old single-domain schema version without forcing Quark to
        // throw away a healthy File Provider backing store.
        if provider.id == "quark", known == 0 {
            let legacyKnown = defaults?.integer(forKey: legacySchemaKey) ?? 0
            if legacyKnown > 0 {
                known = legacyKnown
                defaults?.set(legacyKnown, forKey: key)
            }
        }

        do {
            let existing = try await NSFileProviderManager.domains()
            let present = existing.contains { $0.identifier == provider.domainID }

            if present && (known != provider.schemaVersion || knownDisplayName != resolvedDisplayName) {
                // File Provider persists both the item database and the domain
                // display name. Re-add when either contract changes.
                NSLog("[plinth] rebuilding \(provider.id) domain as \(resolvedDisplayName)")
                try? await NSFileProviderManager.remove(target)
                try? await Task.sleep(for: .seconds(2))
                try await NSFileProviderManager.add(target)
                defaults?.set(provider.schemaVersion, forKey: key)
                defaults?.set(resolvedDisplayName, forKey: nameKey)
                setEnabled(provider, true)
                NSLog("[plinth] rebuilt \(provider.id) domain")
                return true
            }

            if present {
                if let manager = NSFileProviderManager(for: target) {
                    try? await manager.signalEnumerator(for: .rootContainer)
                    try? await manager.signalEnumerator(for: .workingSet)
                }
                defaults?.set(provider.schemaVersion, forKey: key)
                defaults?.set(resolvedDisplayName, forKey: nameKey)
                setEnabled(provider, true)
                NSLog("[plinth] refreshed \(provider.id) domain")
                return true
            }

            try await NSFileProviderManager.add(target)
            defaults?.set(provider.schemaVersion, forKey: key)
            defaults?.set(resolvedDisplayName, forKey: nameKey)
            setEnabled(provider, true)
            NSLog("[plinth] registered \(provider.id) domain")
            return true
        } catch {
            NSLog("[plinth] could not register \(provider.id): \(error.localizedDescription)")
            return false
        }
    }

    static func unregister(_ provider: DriveProvider) async {
        try? await NSFileProviderManager.remove(domain(provider))
        setEnabled(provider, false)
    }

    static func isRegistered(_ provider: DriveProvider) async -> Bool {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        return domains.contains { $0.identifier == provider.domainID }
    }

    static func registeredProviderIDs() async -> Set<String> {
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        let domainIDs = Set(domains.map { $0.identifier.rawValue })
        return Set(ProviderCatalog.all.compactMap {
            domainIDs.contains($0.domainIdentifier) ? $0.id : nil
        })
    }

    static func revealInFinder(_ provider: DriveProvider) async {
        let target = domain(provider)
        guard let manager = NSFileProviderManager(for: target),
              let url = try? await manager.getUserVisibleURL(for: .rootContainer)
        else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.open(url)
    }
}
