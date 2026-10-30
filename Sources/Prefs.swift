import Foundation
import Combine

enum PillItem: String, CaseIterable, Identifiable {
    case cpu, gpu, ram, swap, disk, net

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ram: "RAM"
        case .swap: "SWAP"
        case .disk: "DISK"
        case .net: "NET"
        }
    }

    /// Fixed chip widths keep the pill from jittering as numbers change.
    var width: CGFloat {
        switch self {
        case .cpu, .gpu: 72
        case .ram: 74
        case .disk: 80
        case .swap: 86
        case .net: 118
        }
    }
}

/// User preferences, persisted in UserDefaults.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let defaults = UserDefaults.standard

    @Published var pillItems: [PillItem] { didSet { defaults.set(pillItems.map(\.rawValue), forKey: "pillItems") } }
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: "opacity") } }
    @Published var clickThrough: Bool { didSet { defaults.set(clickThrough, forKey: "clickThrough") } }
    @Published var hideFromSharing: Bool { didSet { defaults.set(hideFromSharing, forKey: "hideFromSharing") } }
    @Published var hideInFullScreen: Bool { didSet { defaults.set(hideInFullScreen, forKey: "hideInFullScreen") } }
    @Published var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: "alertsEnabled") } }
    @Published var longHistory: Bool { didSet { defaults.set(longHistory, forKey: "longHistory") } }
    @Published var groupByApp: Bool { didSet { defaults.set(groupByApp, forKey: "groupByApp") } }

    private init() {
        pillItems = (defaults.stringArray(forKey: "pillItems") ?? ["cpu", "gpu", "ram", "swap", "disk"])
            .compactMap(PillItem.init(rawValue:))
        opacity = defaults.object(forKey: "opacity") as? Double ?? 1
        clickThrough = defaults.bool(forKey: "clickThrough")
        hideFromSharing = defaults.object(forKey: "hideFromSharing") as? Bool ?? true
        hideInFullScreen = defaults.object(forKey: "hideInFullScreen") as? Bool ?? true
        alertsEnabled = defaults.object(forKey: "alertsEnabled") as? Bool ?? true
        longHistory = defaults.bool(forKey: "longHistory")
        groupByApp = defaults.object(forKey: "groupByApp") as? Bool ?? true
    }

    /// Adds or removes a pill item, keeping the canonical order and at least one item.
    func toggle(_ item: PillItem) {
        if pillItems.contains(item) {
            if pillItems.count > 1 { pillItems.removeAll { $0 == item } }
        } else {
            pillItems = PillItem.allCases.filter { pillItems.contains($0) || $0 == item }
        }
    }
}
