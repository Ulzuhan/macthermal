import Foundation

/// Per-category temperatures for one sample, stored inline instead of in a heap
/// dictionary.
///
/// Every `ThermalSample` carries two of these, and the app keeps up to 14 days
/// of samples in memory — 40,320 of them at the default 30-second cadence. Two
/// `[String: Double]` dictionaries per sample meant two heap allocations each,
/// which dominated the history footprint (measured at 42.8 MB resident for that
/// window). `Category` is a closed `CaseIterable` set of six, so the values fit
/// in six `Double`s plus a presence bitmask with no allocation at all.
///
/// `Codable` deliberately reproduces the previous `[String: Double]` shape —
/// object keys are `Category.rawValue`, absent categories are simply omitted —
/// so history and incidents written by older builds decode unchanged and no
/// storage migration is needed. A key that is not a known category is dropped on
/// decode; only `Category.allCases` values were ever written.
public struct CategoryTemperatures: Equatable, Sendable {
    private var cpu = 0.0
    private var gpu = 0.0
    private var memory = 0.0
    private var battery = 0.0
    private var ambient = 0.0
    private var other = 0.0
    private var present: UInt8 = 0

    public init() {}

    public init(_ values: [String: Double]) {
        for (key, value) in values { self[key] = value }
    }

    public subscript(category: Category) -> Double? {
        get {
            guard present & Self.mask(category) != 0 else { return nil }
            switch category {
            case .cpu: return cpu
            case .gpu: return gpu
            case .memory: return memory
            case .battery: return battery
            case .ambient: return ambient
            case .other: return other
            }
        }
        set {
            guard let newValue else {
                present &= ~Self.mask(category)
                return
            }
            present |= Self.mask(category)
            switch category {
            case .cpu: cpu = newValue
            case .gpu: gpu = newValue
            case .memory: memory = newValue
            case .battery: battery = newValue
            case .ambient: ambient = newValue
            case .other: other = newValue
            }
        }
    }

    /// String-keyed access, kept so callers can stay on `Category.rawValue`
    /// (chart scopes, the CSV column layout) without converting first. An
    /// unrecognized key reads as absent and writes are ignored.
    public subscript(key: String) -> Double? {
        get { Category(rawValue: key).flatMap { self[$0] } }
        set { if let category = Category(rawValue: key) { self[category] = newValue } }
    }

    /// The categories that carry a value, in `Category.allCases` order.
    public var categories: [Category] {
        Category.allCases.filter { present & Self.mask($0) != 0 }
    }

    public var isEmpty: Bool { present == 0 }

    private static func mask(_ category: Category) -> UInt8 {
        switch category {
        case .cpu: 1 << 0
        case .gpu: 1 << 1
        case .memory: 1 << 2
        case .battery: 1 << 3
        case .ambient: 1 << 4
        case .other: 1 << 5
        }
    }
}

extension CategoryTemperatures: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, Double)...) {
        self.init()
        for (key, value) in elements { self[key] = value }
    }
}

extension CategoryTemperatures: Codable {
    /// Dynamic keys so the encoded object is a plain `{"CPU": 70.1, …}` map,
    /// identical to what the previous dictionary produced.
    private struct CategoryCodingKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CategoryCodingKey.self)
        for category in Category.allCases {
            let key = CategoryCodingKey(stringValue: category.rawValue)
            if let value = try container.decodeIfPresent(Double.self, forKey: key) {
                self[category] = value
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CategoryCodingKey.self)
        for category in Category.allCases {
            guard let value = self[category] else { continue }
            try container.encode(value, forKey: CategoryCodingKey(stringValue: category.rawValue))
        }
    }
}
