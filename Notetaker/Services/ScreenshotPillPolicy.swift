import Foundation

/// Decision policy for whether a newly-saved screenshot should
/// trigger the resting-pill "screenshot saved" notification.
///
/// Extracted to its own struct so the call-site in
/// `AppDelegate.handleNewScreenshot` stays one line — and so the
/// rule can be exercised by `ScreenshotPillPolicyTests` without
/// touching AppKit, FSEvents, or the rest of the screenshot save
/// pipeline.
///
/// **Rule:** suppress the pill notification whenever the slab is
/// already showing OR in the middle of a morph (open / close /
/// banner). The Images-tab grid mounts the new screenshot through
/// `ImageStore`'s inflight pipeline regardless, so the user still
/// sees the capture; what we're avoiding is the pill's
/// `triggerPunch()` flash overlay animating in parallel with the
/// open spring — which on a partially-grown silhouette bled the
/// 55%-opacity white tile into the panel's halo (user report:
/// "glow at background when opening the thing in time of taking
/// screenshots").
///
/// Background work-in-progress also suppresses because the
/// `setPendingSystemEvent(.screenshotSaved)` write into
/// `PanelPresenter` invalidates every `@ObservedObject` consumer
/// — adding a body re-eval during a morph we're trying to keep
/// smooth.
enum ScreenshotPillPolicy {
    /// Inputs the policy looks at. Kept as a struct so a future
    /// rule (e.g. "always show during onboarding so we can demo
    /// the pill") slots in without changing the call signature.
    struct Inputs {
        /// `presenter.isShown` at the moment the screenshot lands.
        let slabShown: Bool
        /// `presenter.isMorphing` at the same instant.
        let slabMorphing: Bool
    }

    static func shouldFirePill(_ inputs: Inputs) -> Bool {
        if inputs.slabShown { return false }
        if inputs.slabMorphing { return false }
        return true
    }
}
