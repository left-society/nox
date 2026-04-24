import SwiftUI

extension Animation {
    static let panelOpen = Animation.spring(response: 0.35, dampingFraction: 0.82)
    static let rowHover = Animation.spring(response: 0.22, dampingFraction: 0.9)
    static let selection = Animation.spring(response: 0.18, dampingFraction: 0.95)
    static let recordingPulse = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)
}
