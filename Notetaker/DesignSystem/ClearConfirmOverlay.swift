import SwiftUI

/// In-panel confirmation overlay that replaces SwiftUI's native
/// `.alert()` for destructive "Clear all X?" actions.
///
/// **Why not `.alert`:** the native alert presents as a free-floating
/// system NSAlert anchored to the key window. The nox panel is a
/// `.nonactivatingPanel` (so clicking it doesn't activate the app),
/// which means the alert can't anchor to the panel and lands wherever
/// the OS thinks the key window is — typically center-screen, far
/// from where the user actually clicked the trash icon. The user
/// reported this as "weird glitch" because the dialog appears
/// disconnected from the panel.
///
/// This overlay sits INSIDE the panel's content area, anchored
/// exactly where the action originated. Same dark-glass language
/// as the rest of the panel; no foreign system chrome.
///
/// Usage:
/// ```swift
/// .overlay {
///     ClearConfirmOverlay(
///         isPresented: $showClearConfirm,
///         title: "Clear all images?",
///         message: "This removes all 12 images from the panel.",
///         destructiveLabel: "Clear",
///         onConfirm: { /* perform delete */ }
///     )
/// }
/// ```
struct ClearConfirmOverlay: View {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    var destructiveLabel: String = "Clear"
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            if isPresented {
                // Backdrop — dims the panel content so the dialog
                // reads as a foreground modal. Tap-outside dismisses
                // (cancel-by-default; matches NSAlert's escape key
                // behavior).
                Color.black.opacity(0.55)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) {
                            isPresented = false
                        }
                    }
                    .transition(.opacity)

                // Confirmation card. Sized to its content; not
                // stretched to the panel width.
                VStack(spacing: 14) {
                    VStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .multilineTextAlignment(.center)
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)

                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                isPresented = false
                            }
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.white.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)

                        Button {
                            onConfirm()
                            withAnimation(.easeOut(duration: 0.18)) {
                                isPresented = false
                            }
                        } label: {
                            Text(destructiveLabel)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(red: 0.85, green: 0.30, blue: 0.30))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(18)
                .frame(width: 280)
                .background(
                    ZStack {
                        VisualEffectBlur(material: .hudWindow,
                                         blendingMode: .withinWindow)
                        Color.black.opacity(0.55)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 10)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85),
                   value: isPresented)
    }
}
