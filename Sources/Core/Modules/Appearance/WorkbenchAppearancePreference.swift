import Foundation

public enum WorkbenchAppearancePreference: String, CaseIterable, Equatable, Sendable {
    case system
    case light
    case dark

    public static let defaultsKey = "workbenchAppearance"

    public static func persisted(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .system
    }

    public var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    public var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    public var appKitName: String? {
        switch self {
        case .system: nil
        case .light: "NSAppearanceNameAqua"
        case .dark: "NSAppearanceNameDarkAqua"
        }
    }
}
