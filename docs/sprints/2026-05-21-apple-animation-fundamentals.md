# Apple Animation Fundamentals — State-Morph Mechanics for nox

Date: 2026-05-21
Scope: The *fundamentals* and exact API mechanics for morphing a notch HUD between container states (compact pill ↔ transient banner ↔ expanded slab) so the transitions feel premium — the graceful squeeze/morph, not an abrupt swap.
Targets: macOS 26.5, Apple Silicon, nox notch HUD at `/Users/apple/Note taker app`.

This builds on two prior reports — read those first, this does not repeat them:
- `2026-05-21-macos-tahoe-research.md` — NSGlassEffectView, GlassEffectContainer, GlassEffectTransition, Spring presets.
- `2026-05-21-iphone-di-deep-research.md` — DI clone spring values, layered content transition (blur+scale+opacity+offset), compositingGroup, two-spring content stagger.

It also assumes the existing nox motion vocabulary in `Notetaker/DesignSystem/NoxAnimations.swift` (presets `pillMorph`, `trackArrival`, `panelOpen`, `panelClose`, `liveActivity`, `hoverExpand`, `swipeReset`, `gentleSettle`, `quickAnticipation`, `slowDrift`). The recipe at the end maps onto those names rather than inventing parallel ones.

---

## 0. Sources

Primary — local SDK headers read on this machine (macOS 26.5 SDK, `Copyright (c) 2025, Apple Inc.`):
- `…/SwiftUICore.framework/…/arm64e-apple-macos.swiftinterface` — `matchedGeometryEffect`, `MatchedGeometryProperties`, `ContentTransition`, `contentTransitionAddsDrawingGroup`, `PhaseAnimator`, `KeyframeAnimator`, `CubicKeyframe`/`SpringKeyframe`/`LinearKeyframe`/`MoveKeyframe`, `KeyframeTimeline`. Line numbers cited inline.
- (Prior report already cited the `Spring`/`Animation`/`Glass`/`GlassEffectTransition` parts of the same file, and `CAAnimation.h`'s `CASpringAnimation initWithPerceptualDuration:bounce:`.)

Primary — Apple, verbatim transcripts:
- WWDC18 Session 803 — "Designing Fluid Interfaces" (Chan Karunamuni + Nathan de Vries). Transcript via [Apple](https://developer.apple.com/videos/play/wwdc2018/803/) and [ASCIIwwdc](https://asciiwwdc.com/2018/sessions/803). This is the foundational text behind every Apple spring.
- WWDC25 Session 219 — "Meet Liquid Glass" ([Apple](https://developer.apple.com/videos/play/wwdc2025/219/)).
- WWDC23 Session 10194 — "Design dynamic Live Activities" ([Apple](https://developer.apple.com/videos/play/wwdc2023/10194/)) — quoted in prior DI report.

Secondary (reputable):
- Swift with Majid — "Content transition in SwiftUI" ([link](https://swiftwithmajid.com/2022/08/02/content-transition-in-swiftui/)).
- The SwiftUI Lab — "matchedGeometryEffect Part 1 / Part 2" ([part 1](https://swiftui-lab.com/matchedgeometryeffect-part1/), [part 2](https://swiftui-lab.com/matchedgeometryeffect-part2/)).
- Hacking with Swift — matchedGeometryEffect & drawingGroup tutorials ([mge](https://www.hackingwithswift.com/quick-start/swiftui/how-to-synchronize-animations-from-one-view-to-another-with-matchedgeometryeffect), [drawingGroup](https://www.hackingwithswift.com/books/ios-swiftui/enabling-high-performance-metal-rendering-with-drawinggroup)).
- objc.io Swift Talk S01E257/258 — "Matched Geometry Effect" ([link](https://talk.objc.io/episodes/S01E257-matched-geometry-effect-part-1)).
- createwithswift — "Understanding Spring Animations in SwiftUI" ([link](https://www.createwithswift.com/understanding-spring-animations-in-swiftui/)), "GlassEffectContainer in iOS 26" (dev.to/arshtechpro).
- newly.app, canopas — Live Activities/Dynamic Island timing guides.

A note on Apple doc pages: `developer.apple.com/documentation/...` pages are JS-rendered and return title-only to a fetcher (confirmed again this session for `interpolate`, `contentTransitionAddsDrawingGroup`, and the HIG Live Activities page). The SDK `.swiftinterface` headers are therefore the authoritative source for signatures and defaults, and the secondary blogs fill in described behavior.

---

## 1. matchedGeometryEffect — mechanics

### 1.1 Verbatim signature (SDK header)

From `SwiftUICore…arm64e-apple-macos.swiftinterface` line 2974:

```swift
@inlinable nonisolated public func matchedGeometryEffect<ID>(
    id: ID,
    in namespace: Namespace.ID,
    properties: MatchedGeometryProperties = .frame,
    anchor: UnitPoint = .center,
    isSource: Bool = true
) -> some View where ID : Hashable
```

`MatchedGeometryProperties` is an `OptionSet` (line 2955) with exactly three members:

```swift
public static let position: MatchedGeometryProperties   // center point only
public static let size:     MatchedGeometryProperties   // width/height only
public static let frame:    MatchedGeometryProperties   // both (default)
```

### 1.2 How it works

It defines a **group of views with synchronized geometry**, keyed by `(id, namespace)`. When two or more views in the same view tree carry the same `id` in the same `@Namespace`, SwiftUI picks the one marked `isSource: true` as the geometric source of truth and forces every other member of the group to adopt that source's geometry: *"For a view to take on the geometry of another view, it is proposed the size of the source view and positioned at the same location as the source view."* ([Hacking with Swift](https://www.hackingwithswift.com/quick-start/swiftui/how-to-synchronize-animations-from-one-view-to-another-with-matchedgeometryeffect))

The `properties` argument controls *which* geometry is copied — frame (default), or just position, or just size. `anchor` sets which point of the view the position aligns to (`.center` default, `.top`, `.topLeading`, etc.). `anchor` is the lever for the "grow from the camera/notch" feel: anchoring at `.top` makes the morph emanate downward from the notch instead of from the centroid (the DI report measured the same — expanded DI content uses `anchor: .top`).

Crucially, **matchedGeometryEffect itself does not animate.** It only declares the geometric relationship. The morph happens because the source view's frame *changes* (one view leaves the tree, another enters with the shared id, or `isSource` flips), and that frame change is animated by whatever `withAnimation { … }` / `.animation(_, value:)` is in scope. This is the single most common point of confusion and the root of "it just snaps" bugs. Pair it with a spring or it teleports.

### 1.3 The one hard rule (the undefined-behavior trap)

From the API contract (surfaced via [Hacking with Swift](https://www.hackingwithswift.com/quick-start/swiftui/how-to-synchronize-animations-from-one-view-to-another-with-matchedgeometryeffect) and Apple's docs):

> "If the number of currently-inserted views in the group with isSource = true is not exactly one, results are undefined."

So a group must have **exactly one** `isSource: true` at any moment. Two common ways to satisfy this:

- **Insert/remove pattern** (cleanest for nox): the pill and the slab are in mutually exclusive branches of an `if/else`, both `isSource: true`, both carrying the same id. Only one is ever inserted, so the count is always 1. SwiftUI matches the outgoing view's frame to the incoming view's frame.
- **Persistent-source pattern**: keep one hidden "anchor" view permanently `isSource: true`, and have the visible pill/slab be `isSource: false` consumers that snap onto it. Used when you need both potential targets mounted at once.

### 1.4 What you can animate alongside it

`isSource` and `namespace` are themselves animatable inside the same `withAnimation` block, and — this is the premium detail — *you stack the rest of the morph in the same closure*: corner radius, shadow radius, background opacity, font size. Geometry from `matchedGeometryEffect`, everything else hand-driven, all riding one spring. ([SwiftUI Lab Part 1](https://swiftui-lab.com/matchedgeometryeffect-part1/))

### 1.5 Pill → slab where content rearranges

matchedGeometryEffect on the *container* gives you the silhouette morph (capsule grows into rounded rect). But the *contents* rearrange — the resting pill shows a 16×16 artwork + tiny text; the slab shows a full music card or grid. Two strategies, often combined:

1. **One matched id for the surface, layered transition for the content.** The glass/background carries the matched id and morphs frame + corner radius. The content swaps via `.transition(...)` (blur + scale + opacity, per the DI report) on a *separate, slightly slower* spring. This is the cross-clone pattern and what the DI report already documented (surface spring leads, content spring follows ~50ms).
2. **Per-element matched ids for elements that persist.** If the same artwork thumbnail exists in both pill and slab, give *it* its own matched id (e.g. `"nox-artwork"`) so it flies from the pill's 16×16 slot to the slab's larger position rather than cross-fading. Apple's own guidance for lists: *"avoid overlapping elements by animating only a single row that is moving to a new location and fading in and out the others"* (WWDC23, quoted in DI report). Translation: give the *one* element that persists a matched id; cross-fade the rest.

For nox specifically, the artwork is the obvious persistent element — it exists at every state. A `matchedGeometryEffect(id: "nox-artwork", in: ns)` on the album art makes it glide from pill → banner → slab, which reads far more "alive" than a fade. Text and controls that don't persist should ride the content transition instead.

### 1.6 Liquid Glass equivalent

On macOS 26, `glassEffectID(_:in:)` + `GlassEffectContainer` is the *glass-aware* version of matchedGeometryEffect — it morphs the glass silhouette itself (lensing region included), not just the frame. The prior Tahoe report covers it; the relationship is: **`matchedGeometryEffect` morphs the frame of an ordinary view; `glassEffectID` morphs the sampled glass shape.** Use `glassEffectID` for the surface when the surface is `NSGlassEffectView`/`.glassEffect()`, and reserve `matchedGeometryEffect` for non-glass content elements (like the artwork) that need to fly between layouts.

---

## 2. PhaseAnimator / KeyframeAnimator (iOS 17 / macOS 14+)

Both confirmed present in the **native** `arm64e-apple-macos.swiftinterface` (not Catalyst-only), gated `@available(iOS 17.0, macOS 14.0, …)`.

### 2.1 PhaseAnimator — discrete stages, auto-sequenced

Signature (line 14178 / 14196):

```swift
public struct PhaseAnimator<Phase, Content> : View where Phase : Equatable {
    public init(_ phases: some Sequence<Phase>,
                trigger: some Equatable,
                @ViewBuilder content: @escaping (Phase) -> Content,
                animation: @escaping (Phase) -> Animation? = { _ in .default })
    public init(_ phases: some Sequence<Phase>,        // no-trigger = loops forever
                @ViewBuilder content: @escaping (Phase) -> Content,
                animation: @escaping (Phase) -> Animation? = { _ in .default })
}

// Modifier form:
func phaseAnimator<Phase>(_ phases: some Sequence<Phase>,
                          trigger: some Equatable,
                          content: (PlaceholderContentView<Self>, Phase) -> some View,
                          animation: (Phase) -> Animation? = { _ in .default }) -> some View
```

**What it is:** you give it an *ordered list of discrete phases* (an enum is idiomatic). On each `trigger` change it walks the list one phase at a time — `phase[0] → phase[1] → phase[2] → …` — and for each leg it asks your `animation:` closure which spring/curve to use. The key superpower vs. a single spring: **each leg can have a different animation.** You can make the expand leg snappy and the settle leg smooth, automatically, without chaining `withAnimation` + `DispatchQueue.asyncAfter`.

**This is exactly the "compact → overshoot → settle" sequence the prompt asks about.** Define three phases — `.compact`, `.overshoot`, `.settled` — and PhaseAnimator drives them in order with a per-leg animation:

```swift
enum BannerPhase: CaseIterable { case hidden, overshoot, settled }

content
  .phaseAnimator(BannerPhase.allCases, trigger: mediaChangeID) { view, phase in
      view
        .scaleEffect(phase == .overshoot ? 1.04 : 1.0)
        .offset(y: phase == .hidden ? -notchDrop : 0)
        .opacity(phase == .hidden ? 0 : 1)
  } animation: { phase in
      switch phase {
      case .hidden:    return nil                         // jump cut, no anim into hidden
      case .overshoot: return .spring(response: 0.34, dampingFraction: 0.62) // fast, bouncy in
      case .settled:   return .spring(response: 0.5,  dampingFraction: 1.0)  // smooth settle
      }
  }
```

Caveats:
- The two-init forms matter: **with `trigger:`** it advances once per trigger change and stops; **without `trigger:`** it loops the phase list forever (good for an idle "breathing" pulse, which nox already wants via `slowDrift`).
- Phases are *discrete*. PhaseAnimator does not interpolate intermediate values; it springs between the values your content produces at each named phase. For a single physical quantity that needs a custom mid-flight trajectory, use KeyframeAnimator instead.

### 2.2 KeyframeAnimator — continuous, time-scripted trajectories

Signature (line 2379 / 2369):

```swift
public struct KeyframeAnimator<Value, KeyframePath, Content> : View
    where Value == KeyframePath.Value, KeyframePath : Keyframes {
    public init(initialValue: Value, trigger: some Equatable,
                @ViewBuilder content: @escaping (Value) -> Content,
                @KeyframesBuilder<Value> keyframes: @escaping (Value) -> KeyframePath)
    public init(initialValue: Value, repeating: Bool = true, …)   // loops
}
```

Track-content keyframe types (lines 14109–14156), with exact inits:

```swift
CubicKeyframe(_ to: Value, duration: TimeInterval, startVelocity: Value? = nil, endVelocity: Value? = nil)
SpringKeyframe(_ to: Value, duration: TimeInterval? = nil, spring: Spring = Spring(), startVelocity: Value? = nil)
LinearKeyframe(_ to: Value, duration: TimeInterval, timingCurve: UnitCurve = .linear)
MoveKeyframe(_ to: Value)        // instantaneous jump, no interpolation
```

**What it is:** KeyframeAnimator drives **multiple independent tracks of a single animatable `Value`** along a scripted timeline. Unlike PhaseAnimator (discrete states, spring between them), KeyframeAnimator gives you per-segment control of the *trajectory* — you can say "scale goes to 1.08 over 0.15s with a cubic curve, then back to 1.0 over 0.30s with a spring," and run a *separate* track for vertical offset simultaneously. The tracks are independent and overlap in time, which is how you get squash-and-stretch (width and height following different curves at the same moment).

**When to use which:**
- **Single spring** — 90% of state changes. A pill→slab open is one spring on the shared geometry. Reach for this first (WWDC18: springs are "seamless… baked in," see §4).
- **PhaseAnimator** — when the motion is a *sequence of states* where each leg wants a different feel (anticipation dip → overshoot → settle), and you're happy letting springs interpolate between named values. Lower code cost than keyframes.
- **KeyframeAnimator** — when you need a *bespoke trajectory* of one quantity (e.g. a non-uniform squash where width and height diverge then reconverge), or a multi-track choreography that a spring can't express. Highest control, highest authoring cost. Apple's own demo is the "jiggle/bounce" on a heart symbol.

For nox's pill↔slab, a **single spring on shared geometry is correct and cheapest.** Use PhaseAnimator only for the *banner* (it genuinely has a 3-stage life: arrive-with-overshoot → dwell → retract — see §6), and reserve KeyframeAnimator for one-off flourishes (e.g. a recording-dot pulse) where the trajectory must be hand-shaped. Do not keyframe the surface morph — it fights interruptibility (§4.3).

---

## 3. .contentTransition — deep dive and the cost model

### 3.1 The four cases (verbatim from SDK header, lines 15825–15832)

```swift
public struct ContentTransition : Equatable, Sendable {
    public static let identity: ContentTransition
    public static let opacity: ContentTransition
    public static let interpolate: ContentTransition
    public static func numericText(countsDown: Bool = false) -> ContentTransition
    public static func numericText(value: Double) -> ContentTransition   // macOS 14+
}
```

`.symbolEffect` is **not** a `ContentTransition` — it's a separate symbol-animation API (`.symbolEffect(...)` / `.contentTransition(.symbolEffect)` exists as a bridge for SF Symbols only). The four `ContentTransition` cases above are the real menu.

Behavior + cost of each:

| Transition | What it does | Cost | When to use in nox |
|---|---|---|---|
| `.identity` | No transition; new content just replaces old, no animation of the change itself. | Free. | When you explicitly *don't* want the content morph to animate (Apple WWDC23: "consider disabling animations for less important changes"). |
| `.opacity` | Cross-fades old content out / new content in. | Cheap — one opacity ramp per layer, no offscreen pass. | Default for view churn (one control replaced by another). The DI report's "views fade in and out" maps here. |
| `.numericText(countsDown:)` | Understands a number changed and animates *only the digits that changed*, rolling them up or down (odometer feel). `countsDown` / `value:` set the direction. | Cheap — it's a targeted glyph slide, not a full re-render. | Timers, track elapsed time, any counter in the pill or slab. This is the iOS-native "ticker." |
| `.interpolate` | Attempts to interpolate the *rendered contents* between states — text size and color, vector shape — producing a true morph rather than a cross-fade where the content supports it. | **Expensive** — see §3.2. | Sparingly. Only for a small element whose size/color genuinely changes and where a cross-fade looks cheap. |

(Behavioral descriptions corroborated by [Swift with Majid](https://swiftwithmajid.com/2022/08/02/content-transition-in-swiftui/): `.interpolate` "is useful when transitions affect text size and color changes"; `.numericText` "understands how the number changed, and provides a nice visual effect that changes only the needed part of the Text view representing a number.")

### 3.2 Why `.interpolate` is GPU-heavy (confirming the lag nox hit)

The header exposes the smoking gun (lines 15850–15858):

```swift
extension EnvironmentValues {
    public var contentTransition: ContentTransition { get set }
    public var contentTransitionAddsDrawingGroup: Bool { get set }
}
```

`.interpolate` needs to interpolate *rasterized* content. To do that smoothly it wants the transitioning subtree flattened into a **single offscreen Metal texture** so it can blend pixel-space between the two renders. That flattening is `drawingGroup()` — and `contentTransitionAddsDrawingGroup` is the environment flag that turns it on. Per [Swift with Majid](https://swiftwithmajid.com/2022/08/02/content-transition-in-swiftui/): setting it true enables "GPU-accelerated rendering by wrapping the transition content into a drawing group."

Here's the cost trap, and it's exactly what bit nox before:

1. **Without `drawingGroup`**, `.interpolate` falls back to a software/per-frame interpolation that is *more* expensive on a complex subtree, and on rich content it visibly degrades to a crossfade anyway.
2. **With `drawingGroup`**, you pay an **offscreen render pass every frame of the transition.** Hacking with Swift's own warning about `drawingGroup()`: it *"renders contents into an off-screen image before displaying… should not be used often, as the off-screen render pass might slow down SwiftUI for simple drawing"* ([HwS](https://www.hackingwithswift.com/books/ios-swiftui/enabling-high-performance-metal-rendering-with-drawinggroup)). "Operations like rendering gradients, blur layers, large symbols, and complex masks get expensive fast."

Now stack that on nox's reality: the content lives *inside* `NSGlassEffectView`, which is **already** doing real-time lensing/refraction sampling (Tahoe report §Performance). `.interpolate` + drawingGroup forces an offscreen flatten of glass-backed, blurred, gradient-rich content **every frame**, on top of the glass sampling pass. That's two heavy GPU passes fighting for the same frame budget — the lag is fully explained.

**Rule for nox:** never put `.interpolate` on glass-backed or gradient/blur-rich content. Use `.numericText` for numbers (cheap, native, exactly the ticker look) and `.opacity` for everything else. If a specific small glyph *must* interpolate, isolate it in its own non-glass subtree and accept the drawingGroup pass for that tiny region only.

---

## 4. The fundamentals — Disney's 12 principles + WWDC18, applied to a notch morph

WWDC18 "Designing Fluid Interfaces" is the operative text. Apple deliberately reduces the designer-facing spring model to **two parameters** — *response* and *damping* — and treats mass/stiffness as implementation detail (de Vries, verbatim): *"The first is damping, which controls how much or little overshoot there is… The second property is response. And, this controls how quickly the value will try and get to the target."*

### 4.1 Slow-in / slow-out (ease) — already free

A spring *is* slow-in/slow-out. It accelerates from rest and decelerates into the target by construction. This is why Apple avoids the word duration: *"we like to avoid using duration when we're describing elastic behaviors, because it reinforces this concept of constant dynamic change. The spring is always moving, and it's ready to move somewhere else."* For nox: never use a `.linear` or fixed-duration curve on a state morph. Springs only.

### 4.2 Anticipation — use it on press, sparingly on morph

Disney's anticipation = a small countermove before the main action. In UI this is the brief scale-*down* on press before a panel opens. nox already has `quickAnticipation` (response 0.18, damping 0.85) for exactly this — button-press anticipation. Apply it to the *trigger* (the press), not the surface morph. Apple does not anticipate auto-triggered transitions (a banner that arrives on its own shouldn't "wind up" first); anticipation belongs to *gesture-initiated* actions where the user's touch is the windup.

### 4.3 Follow-through / overshoot — gated on momentum (the central rule)

This is the most important fundamental for getting "premium" right, and Apple is unusually explicit:

> "A spring doesn't need to overshoot. You don't need to use springy springs. So, we recommend **starting with 100% damping**, or no overshoot when you're tuning elastic behaviors. That way you'll get smooth, graceful, and seamless motion that doesn't distract from the task at hand."

And the conditional that follows — *this is the rule nox should encode*:

> "If the gesture that's driving the motion itself has momentum, then you should reward that momentum with a little bit of overshoot. … if a gesture has momentum, and there isn't any overshoot, it can often feel broken or unsatisfying."

The Music-app minibar example is **directly nox's case** (a small bar at the bottom that taps up into Now Playing — structurally identical to a pill that opens into a slab):

> "Because the tap doesn't have any momentum in the direction of the presentation of Now Playing, we use **100% damping** to make sure it doesn't overshoot. But, if you swipe to dismiss Now Playing, there is momentum in the direction of the dismissal, and so we use **80% damping** to have a little bit of bounce and squish, making the gesture a lot more satisfying."

Applied to nox:
- **Tap / click to open the slab → ~100% damping** (no overshoot). Smooth, intentional. → `panelClose`-style damping on *open*, or a critically-damped `smooth`. (Note nox's current `panelOpen` is 0.62 damping = quite bouncy; per Apple's own minibar logic, a *click*-opened slab should be closer to critically damped. A *swipe*-opened slab earns the bounce. See recipe §7 for splitting these.)
- **Swipe / drag to dismiss → ~80% damping** (a little bounce/squish), because the gesture carried momentum. nox's `swipeReset` (0.85) is close; for a *committed* swipe-dismiss, drop to ~0.80 to "reward the momentum."
- **Auto-arriving banner (no gesture) → mostly damped, tiny overshoot at most.** It wasn't summoned by a momentum gesture, so a big bounce would feel unmotivated. A *small* overshoot is defensible as brand expression (WWDC23 calls DI motion a "deliberate elasticity… like a living organism") but keep it subtle — `trackArrival` (0.65) is at the edge; consider 0.70–0.75 for a less excitable arrival.

### 4.4 Squash & stretch — the "squeeze," and how it's actually achieved

Disney's squash/stretch preserves volume: as something accelerates it stretches along the motion axis and thins perpendicular; on impact it squashes. Apple uses this literally for app launch (WWDC18, verbatim):

> "when you launch an app, the icon **elastically stretches down** to become the app as it opens" … and "stretches up in the opposite direction as you close the app."

That is the canonical Apple "small → large" morph, and it is **non-uniform scaling** — the silhouette stretches more along the axis of growth than across it. There are two ways to get the squeeze, and the premium look uses both:

1. **Geometry-driven (preferred for a container morph).** Don't `scaleEffect` the whole thing uniformly. Animate **width and height as separate values on the same spring but to non-proportional targets**, so mid-flight the aspect ratio is momentarily "wrong" — wider-than-tall while expanding outward, then it reconciles. This is intrinsic to matchedGeometryEffect when the source/target frames have different aspect ratios: the interpolated frames pass through intermediate shapes that read as a squeeze. nox's slab is much taller than the pill, so the natural frame interpolation already produces a vertical stretch — lean into it by anchoring at `.top` so it stretches *downward from the notch*, exactly like the app-launch metaphor.
2. **Explicit non-uniform scale for the flourish.** For a deliberate squash on arrival/impact, drive `scaleEffect(x:y:)` with **different x and y** on a short overshoot leg — e.g. on a banner landing, `scaleEffect(x: 1.04, y: 0.97)` at the overshoot phase (slightly wide and squat, as if it "landed" with weight), settling to `(1,1)`. This is a textbook PhaseAnimator overshoot phase (§2.1) or a two-track KeyframeAnimator (§2.2).

The reason a single uniform `scaleEffect` feels cheap is that it has no volume behavior — it's a photographic zoom, not an elastic body. The squeeze comes from x and y disagreeing for a moment.

### 4.5 Timing & weight — material as a weight cue (Liquid Glass)

WWDC25 "Meet Liquid Glass" gives nox a *material* lever for conveying weight that older UIs lacked. Per Apple (Session 219, paraphrased from transcript):

> When glass flexes and morphs to larger sizes, its material characteristics change to simulate a **thicker, more substantial material, casting deeper, richer shadows, with more pronounced lensing and refraction effects.**

So the slab isn't just bigger — as it grows it should read as *heavier*: shadow deepens, lensing intensifies. This is a follow-through cue (the material "settles" into its new mass). With `NSGlassEffectView` this is partly automatic, but you reinforce it by animating shadow radius/opacity *on the same spring* as the frame (small pill = faint/no shadow per DI report; expanded slab = deeper shadow). The shadow growing slightly *behind* the frame settle (a hair slower) sells the weight.

### 4.6 Interruptibility (Apple's non-Disney addition) — do not break it

The single biggest "feel" differentiator Apple calls out is that motion must be **redirectable mid-flight**:

> "for iPhone 10, we built a fully redirectable interface." … "it's important for our interfaces to be able to reflect that ability of constantly redirecting. … It always feels alive."

Springs are interruptible and *additive* by nature — a new spring can take over from a moving value without a visible discontinuity (this is what `.interactiveSpring`'s `blendDuration` is for, per the Tahoe report). **KeyframeAnimator and fixed-duration animations are NOT freely interruptible** — they're scripted timelines. This is the concrete reason to keep the surface morph on a plain spring (not keyframes): if the user clicks the pill again mid-open, or a new track arrives mid-banner, a spring redirects gracefully; a keyframe timeline restarts or jumps. nox already has the right primitive; the rule is *don't replace it with a timeline for the core transitions.*

---

## 5. Two-stage / multi-spring morph — the premium secret

The recurring finding across the DI report, the clones, and Apple's own framing: **a premium morph is not one spring — it's a surface spring and a content spring with different timing.**

### 5.1 Surface spring vs. content spring (confirmed pattern)

- **Surface (the silhouette / glass shape) leads.** Slightly faster, can carry the small overshoot. This is the thing the eye locks onto; it should commit decisively. (DI clones: `expandLiveActivity` response ~0.40.)
- **Content (text, controls, secondary art) follows** by a beat. Slightly slower and/or more damped, so it "fills in" after the container has established the new shape. (DI clones: `expandLiveActivityContentTransition` response ~0.45 — a ~50ms lag created purely by the slower spring, *not* an explicit delay.)

Why two springs instead of an explicit delay: a delay is a fixed timer (brittle, non-interruptible). Two springs of different response naturally stagger and *both remain interruptible*. Apple's Fluid-Interfaces principle that springs "stagger naturally when start positions differ" is the same idea — let physics create the rhythm.

nox already encodes the two halves: `pillMorph`/`panelOpen` for the surface, and a separate content reveal. The discipline is to make sure the content reveal is on a *distinct, slightly slower* spring (e.g. surface `panelOpen` 0.42, content `snappy`/`pillMorph` 0.40 but applied to the inner `.transition`, or explicitly `trackArrival`-ish for content fade-in), and that content uses blur+scale+opacity (DI report §5) not a bare opacity.

### 5.2 Material settling as the third "spring"

Beyond surface and content, Liquid Glass adds a *material* response (§4.5): shadow depth and lensing intensifying as the shape grows. Treat this as a third, *slowest* track — the glass "thickens" into its new mass a hair after the frame lands. Animating shadow on the same spring family but with the most damping (e.g. `smooth`) gives the settle.

So the full premium morph is three layered timings:
1. **Surface** — fastest, decisive, small overshoot if gesture-driven (`panelOpen`/`pillMorph`).
2. **Content** — ~50ms behind via a slightly slower spring; blur+scale+opacity, not bare fade (`trackArrival`/`snappy`).
3. **Material** — slowest, most damped; shadow/lensing deepening to convey weight (`smooth`/`gentleSettle`).

### 5.3 How Apple sequences a banner: expand fast → dwell → retract slower

The asymmetry rule (already noted in Tahoe report for show/hide, here applied to the banner life cycle):
- **Expand in: fast and slightly expressive** — it needs to grab attention. A momentum-free arrival still wants to feel lively, so this is the one auto-animation that earns a *touch* of overshoot (`trackArrival`).
- **Dwell: hold** — see §6 for duration.
- **Retract out: slower and fully damped** — *"settling above the camera should feel intentional, not sloppy"* (DI clone synthesis; clones uniformly use higher damping / critical damping on close). Retraction should not bounce — a bounce on exit reads as the UI being unsure. `panelClose` (0.78) or `smooth` (1.0).

The general law: **appear faster than you disappear is wrong for banners** — it's the inverse. A banner should *arrive* expressively (fast, lively) and *leave* calmly (slower, damped). This differs from a user-dismissed panel (which leaves fast because the user asked it to). Match the timing to *who initiated the exit*: system-initiated retract = calm/slow; user-initiated dismiss = quick/responsive.

---

## 6. Banner dwell / auto-dismiss timing

The transient "new media" banner needs an appear → read → dismiss budget. Apple's own conventions:

### 6.1 Live Activity / Dynamic Island expanded-on-update

When a Live Activity *updates*, the Dynamic Island **expands automatically for "a couple of seconds"** then collapses back to compact ([newly.app](https://newly.app/articles/ios-live-activities), [canopas](https://medium.com/canopas/integrating-live-activity-and-dynamic-island-in-ios-a-complete-guide-part-2-0546c8f8c642)). "A couple of seconds" is the operative figure — empirically ~2s of dwell for the auto-expanded peek before it retracts.

### 6.2 Notification banner convention

System notification banners (the temporary style that auto-dismisses) sit on screen for roughly **4–5 seconds** before sliding away if untouched — long enough to read a short string, short enough not to nag. This is the upper bound for a *content-bearing* banner the user is expected to read.

### 6.3 Synthesis for nox's "new media" banner

The nox banner is closer to the DI auto-expand (a glanceable "now playing X" peek) than to a full notification:
- **Appear:** ~0.34–0.40s expressive spring (`trackArrival`).
- **Dwell:** **~2.0s** for a glance-only banner (artwork + title), extend to **~3.5–4s** if it carries text the user must read (e.g. a transcription result). This matches DI's "couple of seconds" floor and stays under the notification 4–5s ceiling.
- **Retract:** ~0.3–0.5s, fully damped (`panelClose`/`smooth`), no overshoot.
- **Interrupt rule (from §4.6):** if a *new* media event arrives during dwell, don't queue-and-wait — redirect: cancel the retract timer, morph content in place (artwork flies via matched id, text `.numericText`/`.opacity` swaps), reset the dwell timer. If the user *hovers*, freeze the dwell timer (hover = intent to read). The DI clones implement a `queuePacingDelay ~0.1s` and `hideShowDelay ~0.35s`; nox's equivalent is "debounce rapid events by ~0.1s, hold ~2s, but a hover or new event overrides the timer."

A concrete dwell constant to add to the design system: `bannerDwell: TimeInterval = 2.0` (glance) with an overload `bannerDwellReadable = 3.75` (text-bearing). Drive the retract off a cancellable `Task.sleep`, cancelled by hover or a new event.

---

## 7. Concrete recipe for nox's pill → banner → slab morph

Goal: every transition is one continuous liquid surface, with surface/content/material layered timings, gesture-gated overshoot, and a banner that arrives lively and leaves calm. Built on the existing `NoxAnimations` vocabulary.

### 7.1 Surface morph (the silhouette) — Liquid Glass + matched id

Use `GlassEffectContainer` + `glassEffectID` for the *glass shape* (morphs lensing region, single sample pass — Tahoe report). One shared id across all three states so the silhouette is continuous.

```swift
@Namespace private var nox            // surface namespace
@Namespace private var content        // content-element namespace (artwork etc.)

GlassEffectContainer(spacing: 24) {            // 24pt: merge when within range (Tahoe report)
    Group {
        switch state {
        case .pill:
            PillBody()
                .glassEffect(.regular, in: .capsule)
        case .banner:
            BannerBody()
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
        case .slab:
            SlabBody()
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }
    .glassEffectID("nox-surface", in: nox)     // continuous silhouette across states
}
```

Drive the state change with the right spring **per initiator** (the §4.3 momentum rule):

```swift
// Click/tap open (no momentum) → critically damped, no overshoot:
withAnimation(NoxAnimations.smooth) { state = .slab }          // ~100% damping, "intentional"

// Swipe/drag open (momentum) → reward with a little bounce:
withAnimation(.spring(response: 0.42, dampingFraction: 0.80)) { state = .slab }  // ~80% damping

// System banner arrival (no gesture) → lively but mostly damped:
withAnimation(NoxAnimations.trackArrival) { state = .banner }  // 0.5 / 0.65

// Banner/slab retract (system-initiated exit) → calm, fully damped, no bounce:
withAnimation(NoxAnimations.panelClose) { state = .pill }      // 0.32 / 0.78
```

Note the deliberate split of nox's current single `panelOpen` (0.42/0.62) into a *click* path (`smooth`, no overshoot) and a *swipe* path (0.42/0.80). Per Apple's own minibar example this is the correct distinction; a click-opened slab should not bounce.

### 7.2 Persistent element flies (artwork) — matchedGeometryEffect

The album art exists at every state. Give it its own matched id so it *glides* rather than cross-fades — anchored `.top` so growth emanates from the notch (app-launch metaphor, §4.4):

```swift
ArtworkView(image: art)
    .matchedGeometryEffect(id: "nox-artwork", in: content, anchor: .top)
    .frame(width: state == .pill ? 16 : state == .banner ? 28 : 96,
           height: state == .pill ? 16 : state == .banner ? 28 : 96)
// rides whatever withAnimation drove the state change — keep it in the SAME closure.
```

### 7.3 Content reveal — the slower second spring (NOT bare opacity)

Content swaps via the layered transition from the DI report (blur + scale + opacity), on a *slightly slower* spring than the surface, wrapped in `compositingGroup()` to avoid layer artifacts:

```swift
SlabInnerContent()
    .transition(.modifier(
        active:   ContentMorph(blur: 20, scale: 0.6, opacity: 0, anchor: .top),
        identity: ContentMorph(blur: 0,  scale: 1.0, opacity: 1, anchor: .top)
    ))
    .compositingGroup()
// Apply a distinct, slightly slower content spring so it lags the surface ~50ms:
.animation(NoxAnimations.snappy, value: state)   // surface used smooth/trackArrival → content lags naturally
```

For numbers (timer, elapsed) inside any state: `.contentTransition(.numericText())` — cheap, native, exactly the ticker look. **Never `.interpolate`** on this glass-backed content (§3.2).

### 7.4 Banner as a 3-stage PhaseAnimator (arrive → dwell → retract with squash)

The banner genuinely has phases; PhaseAnimator expresses the arrive-overshoot cleanly, and the dwell/retract is driven by a cancellable task:

```swift
enum BannerPhase: CaseIterable { case incoming, landed }

BannerBody()
    .phaseAnimator(BannerPhase.allCases, trigger: mediaEventID) { view, phase in
        view
            .scaleEffect(x: phase == .incoming ? 1.04 : 1.0,    // wide + squat on land = weight (§4.4)
                         y: phase == .incoming ? 0.97 : 1.0,
                         anchor: .top)
            .offset(y: phase == .incoming ? -8 : 0)
    } animation: { phase in
        switch phase {
        case .incoming: return NoxAnimations.trackArrival   // 0.5/0.65 lively in
        case .landed:   return NoxAnimations.smooth         // 1.0 damping settle
        }
    }

// Dwell + retract, cancellable by hover / new event (§6.3):
.task(id: mediaEventID) {
    try? await Task.sleep(for: .seconds(isTextBearing ? 3.75 : 2.0))
    guard !isHovering else { return }                       // hover freezes dwell
    withAnimation(NoxAnimations.panelClose) { state = .pill }  // calm retract
}
```

### 7.5 Material weight cue (third track) — shadow deepens behind the morph

Per WWDC25 (§4.5), grow the shadow as the surface grows, on the most-damped spring so it settles last:

```swift
.shadow(color: .black.opacity(state == .pill ? 0.0 : state == .banner ? 0.25 : 0.5),
        radius: state == .pill ? 0 : state == .banner ? 8 : 15, y: 4)
.animation(NoxAnimations.gentleSettle, value: state)   // slowest track → material "thickens" into mass
```

(Shadow values from the DI report: 0 on compact pill, ~0.5/15 on expanded — matches.)

### 7.6 The three layered timings, summarized

| Track | Drives | Preset (existing) | Damping intent |
|---|---|---|---|
| **Surface** (silhouette/glass) | frame + corner radius + glass shape, via `glassEffectID` | click→`smooth`; swipe→`spring(0.42, 0.80)`; banner-in→`trackArrival`; retract→`panelClose` | gesture-gated overshoot (§4.3) |
| **Content** (text/controls) + persistent art | inner `.transition` (blur+scale+opacity) + `matchedGeometryEffect` art | `snappy` / `pillMorph` (slightly slower than surface) | ~50ms lag, mostly damped |
| **Material** (shadow/lensing) | shadow radius/opacity | `gentleSettle` / `smooth` (slowest) | fully damped, settles last |

### 7.7 Hard don'ts (carried from fundamentals)

- Don't `.interpolate` glass-backed/gradient content — double GPU pass, the lag nox already hit (§3.2). Use `.numericText` (numbers) / `.opacity` (everything else).
- Don't use a uniform `scaleEffect` for the morph — no volume, reads cheap. Let frame interpolation + `(x≠y)` squash do it (§4.4).
- Don't keyframe the *surface* morph — kills interruptibility (§4.6). Keyframes/PhaseAnimator only for flourishes (banner overshoot, dot pulse).
- Don't bounce on a *system-initiated* retract — reads as indecisive (§5.3). Calm + damped.
- Don't add overshoot to a *click*-opened slab — no momentum to reward (§4.3, Music minibar). Bounce is for *swipe*-driven motion.
- Don't use explicit `DispatchQueue.asyncAfter` delays to stagger surface vs content — use two springs of different response (interruptible, §5.1). Reserve timers for the banner *dwell* only (which is genuinely a hold, not a stagger).
- Don't forget `compositingGroup()` around blur+opacity content transitions (DI report §10).

---

## 8. Quick reference

| Question | Answer |
|---|---|
| Does `matchedGeometryEffect` animate by itself? | No — it declares geometry; the frame change must be inside `withAnimation`/`.animation`. Snaps without one. |
| matchedGeometryEffect hard rule? | Exactly **one** `isSource: true` per `(id, namespace)` at all times, else undefined behavior. |
| Glass-shape morph vs view-frame morph? | `glassEffectID(_:in:)` morphs the sampled glass silhouette; `matchedGeometryEffect` morphs an ordinary view's frame (use for the persistent artwork). |
| PhaseAnimator vs KeyframeAnimator? | Phase = discrete states, springs between them, per-leg animation, interruptible-ish. Keyframe = scripted continuous trajectory, multi-track, NOT freely interruptible. |
| Best tool for "compact→overshoot→settle"? | PhaseAnimator with a per-phase `animation:` closure (fast/bouncy in, smooth settle). |
| Cheapest content transition for numbers? | `.contentTransition(.numericText())`. |
| Why did `.interpolate` lag? | It needs `contentTransitionAddsDrawingGroup` → an offscreen Metal pass *every frame*, stacked on top of `NSGlassEffectView`'s own sampling pass. Two heavy GPU passes. |
| Default damping to start from (Apple)? | **100% (no overshoot).** Add bounce only when the *gesture* had momentum (WWDC18 Music minibar). |
| Click-open slab damping? | ~100% (`smooth`) — no momentum, no bounce. |
| Swipe-open / swipe-dismiss damping? | ~80% (`spring(…, 0.80)`) — reward the momentum with a little squish. |
| How is the "squeeze" achieved? | Non-uniform: width and height to non-proportional targets on one spring (frame interpolation through "wrong" aspect ratios), + optional explicit `scaleEffect(x≠y)` on an overshoot leg. Anchor `.top` to stretch from the notch (app-launch metaphor). |
| Premium morph = how many springs? | Three layered tracks: surface (fastest), content (~50ms behind), material/shadow (slowest, most damped). |
| Banner dwell time? | ~2.0s glance (matches DI auto-expand "couple of seconds"); ~3.75s if text-bearing (under the 4–5s notification ceiling). Hover or new event overrides the timer. |
| Banner arrive vs retract timing? | Arrive fast/lively (`trackArrival`); retract slow/calm/damped (`panelClose`/`smooth`) because the system, not the user, initiated the exit. |
| Material weight cue? | As glass grows it simulates thicker material — deeper shadow, stronger lensing (WWDC25). Animate shadow on the slowest spring so it settles last. |
