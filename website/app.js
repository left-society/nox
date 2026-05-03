/* ================================================================
   nox.app — cinematic scroll
   ----------------------------------------------------------------
   Architecture:
     1. Lenis owns scrolling (smooth-inertia). Hooks into rAF.
     2. GSAP ScrollTrigger drives the timeline as you scroll past
        the .cinema-stage. Each beat advances the notch through
        a series of state morphs.
     3. The resting waveform canvas (visible in beat 1) draws via
        rAF with a 4-sinusoid algorithm so the notch feels alive
        even when nothing is scroll-scrubbing it.
   ================================================================ */

(() => {
  'use strict';

  // ============================================================
  // 1. Lenis — smooth scroll
  // ============================================================
  const lenis = new Lenis({
    duration: 1.0,
    // Premium ease: starts fast, settles slowly. Apple uses
    // approximately this curve on their product pages.
    easing: (t) => Math.min(1, 1.001 - Math.pow(2, -10 * t)),
    wheelMultiplier: 1,
    touchMultiplier: 1.6,
    smoothWheel: true,
  });

  // Drive Lenis from rAF and let GSAP know about scroll.
  function raf(time) {
    lenis.raf(time);
    requestAnimationFrame(raf);
  }
  requestAnimationFrame(raf);


  // ============================================================
  // 2. Resting-pill waveform canvas
  // ----------------------------------------------------------------
  // Same 4-sinusoid algorithm the macOS app uses — gives the
  // resting pill a "music is happening" presence even though
  // nothing is actually playing. The canvas is always running;
  // very cheap (one fill + a few sin() per frame).
  // ============================================================
  function drawWaveCanvas() {
    const cv = document.querySelector('.rest-wave');
    if (!cv) return;
    const ctx = cv.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    const w = cv.width = cv.offsetWidth * dpr;
    const h = cv.height = cv.offsetHeight * dpr;
    ctx.scale(dpr, dpr);

    let t0 = performance.now();
    function tick() {
      const t = (performance.now() - t0) / 1000;
      ctx.clearRect(0, 0, w, h);
      ctx.strokeStyle = '#C5A3FF';
      ctx.lineWidth = 1.5 * dpr;
      ctx.lineCap = 'round';

      const W = w / dpr;
      const H = h / dpr;
      const cy = H / 2;
      const N = 24;             // bar count
      const gap = (W - 2) / N;
      for (let i = 0; i < N; i++) {
        const x = 1 + i * gap + gap * 0.5;
        // 4 stacked sinusoids, prime-ish frequencies so the
        // pattern never repeats visibly.
        const phase = i * 0.35;
        const a = Math.sin(t * 1.8 + phase) * 0.55;
        const b = Math.sin(t * 2.6 - phase * 0.7) * 0.30;
        const c = Math.sin(t * 4.1 + phase * 1.3) * 0.18;
        const amp = (a + b + c) * 0.5 + 0.6;   // 0.0 → 1.0 ish
        const barH = Math.max(2, amp * (H - 4));
        ctx.beginPath();
        ctx.moveTo(x, cy - barH / 2);
        ctx.lineTo(x, cy + barH / 2);
        ctx.stroke();
      }
      requestAnimationFrame(tick);
    }
    tick();
  }


  // ============================================================
  // 3. GSAP ScrollTrigger timeline
  // ----------------------------------------------------------------
  // Three beats, each one full viewport tall. The pinning of the
  // MacBook is handled by `position: sticky` in CSS — simpler and
  // smoother than ScrollTrigger's pin feature for this case. We
  // use ScrollTrigger here purely to scrub property animations
  // (notch dimensions, text fades, MacBook tilt) against scroll
  // progress.
  // ============================================================
  function setupCinema() {
    if (typeof gsap === 'undefined' || typeof ScrollTrigger === 'undefined') {
      console.warn('GSAP / ScrollTrigger not loaded; cinema is static.');
      return;
    }
    gsap.registerPlugin(ScrollTrigger);

    // Tell GSAP about Lenis scroll progress so ScrollTrigger
    // can read it correctly. Without this, ScrollTrigger would
    // listen to native scroll events (which Lenis doesn't fire).
    lenis.on('scroll', ScrollTrigger.update);
    gsap.ticker.add((time) => lenis.raf(time * 1000));
    gsap.ticker.lagSmoothing(0);

    const notch = document.getElementById('notch');
    const mac   = document.getElementById('cinemaMac');
    const dock  = document.querySelector('.mbp-dock');
    const restState = document.querySelector('.notch-state[data-state="rest"]');
    const musicState = document.querySelector('.notch-state[data-state="music"]');

    // ----- Beat 1: Hero entrance (no scroll trigger; runs on
    //                              initial paint) -----
    // Words materialize one at a time, then sub + CTA fade in.
    gsap.to('.hero-title .word', {
      opacity: 1, y: 0,
      stagger: 0.18,
      duration: 0.9,
      ease: 'power3.out',
      delay: 0.25,
    });
    gsap.to('.hero-sub', {
      opacity: 1, y: 0,
      duration: 0.7, ease: 'power2.out',
      delay: 0.85,
    });
    gsap.to('.hero-cta', {
      opacity: 1, y: 0,
      duration: 0.7, ease: 'power2.out',
      delay: 1.1,
    });
    // Scroll hint fades in last; CSS keyframe handles the bob.
    gsap.to('.scroll-hint', {
      opacity: 1,
      duration: 0.6,
      delay: 1.6,
    });

    // ----- The cross-beat scroll timeline -----
    // Each "+=N" segment scrubs over N viewport heights. The
    // entire timeline runs across the cinema-stage's height, which
    // equals the sum of the three .beat min-heights (300vh).
    const tl = gsap.timeline({
      scrollTrigger: {
        trigger: '.cinema-stage',
        start: 'top top',
        end: 'bottom bottom',
        scrub: 0.6,        // smoothing factor — higher = lazier
        invalidateOnRefresh: true,
      },
    });

    // ───── Timeline reads (in scroll-progress 0→3 units) ─────
    // 0.0–0.5   Beat 1 fades out. MacBook tilts +1.2°.
    // 0.5–1.5   Beat 2 (pillar) fades IN, holds, fades OUT.
    // 1.5–2.0   MacBook un-tilts; shifts LEFT to make room for
    //           right-side music text.
    // 1.7–2.4   Notch morphs to music slab.
    // 2.0–3.0   Beat 3 right-side text fades in and stays visible.

    // Beat 1 OUT — hero fades out as scroll begins.
    tl.to('.beat-hero-text', { opacity: 0, y: -30, duration: 0.4, ease: 'power2.in' }, 0.3);
    tl.to('.mbp', { rotateZ: 1.2, duration: 0.7, ease: 'power2.inOut' }, 0.3);

    // Beat 2 IN — pillar fades in mid-Beat 1's exit, ramping up
    // through the middle of the timeline. Set initial state via
    // gsap.set so the fromTo's start values aren't applied
    // before scroll triggers the timeline.
    gsap.set('.beat-pillar-text', { opacity: 0, y: 24 });
    tl.to('.beat-pillar-text',
      { opacity: 1, y: 0, duration: 0.4, ease: 'power2.out' },
      0.7);
    // Pillar holds for a beat, then fades out.
    tl.to('.beat-pillar-text', { opacity: 0, y: -20, duration: 0.4, ease: 'power2.in' }, 1.5);

    // MacBook prep for music beat — un-tilt and shift LEFT so
    // the right-side music text has room to appear (Apple iPhone
    // 17 Pro pattern: product slides aside, copy enters).
    tl.to('.mbp', { rotateZ: 0, duration: 0.5, ease: 'power2.inOut' }, 1.5);
    tl.to('.cinema-mac', { x: '-15vw', duration: 0.8, ease: 'power3.inOut' }, 1.6);

    // Beat 3 IN — notch morphs to music slab.
    tl.to(restState,  { opacity: 0, duration: 0.3 }, 1.7);
    tl.to(musicState, { opacity: 1, duration: 0.5 }, 1.85);
    tl.to(notch, {
      width: 720, height: 340,
      top: 6,
      borderRadius: 28,
      duration: 0.9,
      ease: 'power3.inOut',
    }, 1.7);
    tl.to(dock, { opacity: 0, y: 20, duration: 0.5 }, 1.7);

    // Beat 3 side text fades in and STAYS — the user is supposed
    // to read this. Long hold (2.1 → end of timeline).
    gsap.set('.beat-music-text', { opacity: 0, x: 30 });
    tl.to('.beat-music-text',
      { opacity: 1, x: 0, duration: 0.6, ease: 'power2.out' },
      2.1);

    // Subtle tilt for cinematic flair on the music beat.
    tl.to('.mbp', { rotateZ: -1.0, duration: 0.6, ease: 'power2.inOut' }, 2.0);
    tl.to('.mbp', { rotateZ: 0, duration: 0.4, ease: 'power2.inOut' }, 2.7);
  }


  // ============================================================
  // 4. Boot
  // ============================================================
  document.addEventListener('DOMContentLoaded', () => {
    drawWaveCanvas();
    setupCinema();
  });
})();
