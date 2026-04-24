import SwiftUI

extension Font {
    static let nkLabel = Font.system(size: DS.FontSize.xs, weight: .medium)
        .leading(.tight)
    static let nkMeta = Font.system(size: DS.FontSize.sm, weight: .regular)
        .leading(.tight)
    static let nkBody = Font.system(size: DS.FontSize.body, weight: .regular)
    static let nkTitle = Font.system(size: DS.FontSize.title, weight: .semibold)
    static let nkLarge = Font.system(size: DS.FontSize.large, weight: .semibold)
}
