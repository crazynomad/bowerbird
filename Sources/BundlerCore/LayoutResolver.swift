public enum LayoutSource: Equatable, Sendable {
    case pinned
    case learned
    /// 首次进入该环境，由上一个环境的布局按默认规则推导
    case derived(from: String)

    public var label: String {
        switch self {
        case .pinned: "钉住"
        case .learned: "自动记录"
        case .derived(let name): "由「\(name)」推导"
        }
    }
}

/// 三级来源：钉住 → 自动记录 → 从上一个环境推导
public enum LayoutResolver {
    public static func resolve(for environment: DisplayEnvironment, previousEnvironmentKey: String?, store: LayoutStore) -> (Layout, LayoutSource)? {
        if let layout = store.load(environmentKey: environment.key, kind: .pinned) { return (layout, .pinned) }
        if let layout = store.load(environmentKey: environment.key, kind: .learned) { return (layout, .learned) }
        guard let previousEnvironmentKey, previousEnvironmentKey != environment.key,
              let previous = store.load(environmentKey: previousEnvironmentKey, kind: .pinned)
                ?? store.load(environmentKey: previousEnvironmentKey, kind: .learned)
        else { return nil }
        return (LayoutMapper.derive(from: previous, to: environment), .derived(from: previous.name))
    }
}
