import Foundation

/// Which models stay in memory (Engines-PRD ENG-3): one heavy model at a time, nothing loaded that won't fit, and
/// idle models released. Without it, models from earlier jobs pile up until a big load fails in Metal and takes the
/// engine down (seen in R1b: Qwen-Image-Edit still resident, then Qwen-Image Flash).
///
/// - **One heavy slot.** Loading a heavy model (≥ `heavyBytes`) first evicts every other heavy one.
/// - **Machine fit.** If the runtime says a model won't fit, everything idle is evicted before it loads.
/// - **Keep-warm.** A model unused for `keepWarm` is released; one of `bigBytes` or more after `bigKeepWarm`.
/// - **Helpers.** A model a job uses before its own (the prompt enhancer's backbone) is released as soon as it's done,
///   unless it's under `warmHelperBytes`: small enough to stay for the next job beside the image model.
/// Models a running job is using are never evicted.
public actor Residency {
    public struct Policy: Sendable {
        public var heavyBytes: UInt64 = 12 << 30
        public var bigBytes: UInt64 = 20 << 30
        public var keepWarm: Duration = .seconds(600)
        public var bigKeepWarm: Duration = .seconds(180)
        public var sweepInterval: Duration = .seconds(30)
        /// A helper this small stays warm after use (Qwen3.5-4B int4 is about 2 GB); a larger one is released at once.
        public var warmHelperBytes: UInt64 = 4 << 30
        public init() {}
    }

    let host: any ModelHost
    let policy: Policy
    private var footprints: [String: UInt64] = [:]
    private var lastUse: [String: ContinuousClock.Instant] = [:]
    private var inUse: [String: Int] = [:]
    private var sweeper: Task<Void, Never>?
    /// What was evicted and why, newest last (for logs and tests).
    public private(set) var evictions: [(package: String, reason: String)] = []

    public init(host: any ModelHost, policy: Policy = Policy()) {
        self.host = host; self.policy = policy
    }

    deinit { sweeper?.cancel() }

    /// Makes room for `route` and marks it in use. Call before preparing it; balance with `release`.
    public func admit(_ route: ModelRoute) async {
        await loadFootprints()
        let mine = route.packageID
        inUse[mine, default: 0] += 1
        lastUse[mine] = .now
        startSweeping()
        let size = route.footprintBytes ?? footprints[mine] ?? 0
        if size >= policy.heavyBytes {
            for package in await host.residentPackages() where package != mine && idle(package) && footprint(package) >= policy.heavyBytes {
                await evict(package, reason: "one heavy model at a time (loading \(route.id))")
            }
        }
        if let fit = await host.fit(route), !fit.fits {
            for package in await host.residentPackages() where package != mine && idle(package) {
                await evict(package, reason: "making room: \(fit.message)")
            }
        }
    }

    /// Marks `route` no longer in use by the job that admitted it.
    public func release(_ route: ModelRoute) {
        let package = route.packageID
        inUse[package] = max(0, (inUse[package] ?? 1) - 1)
        lastUse[package] = .now
    }

    /// Marks a helper `route` no longer in use, and releases it now unless it's small enough to stay warm.
    public func releaseHelper(_ route: ModelRoute) async {
        release(route)
        let package = route.packageID
        let size = route.footprintBytes ?? footprint(package)
        guard size >= policy.warmHelperBytes, idle(package), await host.residentPackages().contains(package) else { return }
        await evict(package, reason: "a helper of \(size >> 20) MB isn't kept warm")
    }

    /// Releases `route`'s package now if no job is using it (the operator's "release from memory"). Returns whether it was
    /// resident and released.
    public func unload(_ route: ModelRoute) async -> Bool {
        let package = route.packageID
        guard idle(package), await host.residentPackages().contains(package) else { return false }
        await evict(package, reason: "released by the operator")
        return true
    }

    /// Releases models idle past their keep-warm time.
    public func sweep() async {
        let now = ContinuousClock.Instant.now
        for package in await host.residentPackages() where idle(package) {
            guard let used = lastUse[package] else { lastUse[package] = now; continue }
            let limit = footprint(package) >= policy.bigBytes ? policy.bigKeepWarm : policy.keepWarm
            if now - used >= limit { await evict(package, reason: "idle for \(limit)") }
        }
    }

    private func idle(_ package: String) -> Bool { (inUse[package] ?? 0) == 0 }
    private func footprint(_ package: String) -> UInt64 { footprints[package] ?? 0 }

    private func evict(_ package: String, reason: String) async {
        await host.evict(packageID: package)
        lastUse[package] = nil
        evictions.append((package, reason))
        print("residency: released \(package) — \(reason)")
    }

    private func loadFootprints() async {
        guard footprints.isEmpty else { return }
        footprints = await host.footprints()
    }

    private func startSweeping() {
        guard sweeper == nil else { return }
        let interval = policy.sweepInterval
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.sweep()
            }
        }
    }
}
