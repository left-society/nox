// Notetaker site — drives the hero notch through its states + the macOS dock.
// One file. No framework.

(function () {
  'use strict';

  // ============ Audio waveform — Canvas, 4-sinusoid sum, never repeats ============
  // Mirrors Notetaker/NotchPill/WaveformView.swift exactly: four sin
  // components at incommensurate spatial AND temporal frequencies, so
  // the silhouette never falls into a recognisable period. Reads as
  // "alive audio" at every instant, not as a marching ASCII pattern.
  (function initWaveforms() {
    const canvases = document.querySelectorAll('.wave-canvas');
    if (!canvases.length) return;

    const dpr = Math.max(1, window.devicePixelRatio || 1);
    canvases.forEach((c) => {
      // Physical size for crispness; logical size set by CSS
      const cw = c.clientWidth || 22;
      const ch = c.clientHeight || 14;
      c.width  = Math.round(cw * dpr);
      c.height = Math.round(ch * dpr);
    });

    function draw(canvas, time) {
      const ctx = canvas.getContext('2d');
      const w = canvas.width, h = canvas.height;
      ctx.clearRect(0, 0, w, h);
      ctx.beginPath();
      const steps = 32;
      const amp = 0.55;          // matches WaveformView.swift `amplitudeMul` while playing
      for (let i = 0; i <= steps; i++) {
        const t = i / steps;
        const x = t * w;
        // four phase-incoherent sinusoids — straight port from Swift
        const p1 = t * 3.4 * Math.PI - time * 4.7;
        const p2 = t * 5.9 * Math.PI - time * 3.1;
        const p3 = t * 9.1 * Math.PI - time * 6.3;
        const p4 = t * 13.7 * Math.PI - time * 2.4;
        const sig = Math.sin(p1) * 0.45 + Math.sin(p2) * 0.28 +
                    Math.sin(p3) * 0.18 + Math.sin(p4) * 0.09;
        const y = h / 2 + sig * amp * h;
        if (i === 0) ctx.moveTo(x, y);
        else         ctx.lineTo(x, y);
      }
      const tint = canvas.dataset.tint || '#ffffff';
      ctx.strokeStyle = tint;
      ctx.lineWidth   = 1.4 * dpr;     // 1.4pt stroke at @1x, scaled for retina
      ctx.lineCap     = 'round';
      ctx.lineJoin    = 'round';
      ctx.stroke();
    }

    const start = performance.now();
    function tick(now) {
      // Fold time into a small repeating window like the Swift code
      // does, to keep sin() in its precise regime.
      const raw = (now - start) / 1000;
      const time = raw % (2 * Math.PI * 1000);
      canvases.forEach((c) => draw(c, time));
      requestAnimationFrame(tick);
    }

    // Pause when tab is hidden — no point burning CPU off-screen.
    let paused = false;
    document.addEventListener('visibilitychange', () => {
      paused = document.hidden;
      if (!paused) requestAnimationFrame(tick);
    });

    requestAnimationFrame(tick);
  })();


  // ============ macOS Dock — cosine-based magnification ============
  const dock = document.getElementById('mbpDock');
  if (dock) {
    const icons = Array.from(dock.querySelectorAll('.dock-icon'));
    const baseSize = 36;          // matches .dock-icon width/height
    const minScale = 1.0;
    const maxScale = 1.65;
    const effectWidth = 180;      // px on either side of the cursor that the lift affects

    let mouseX = null;            // null = mouse outside dock
    let scales = icons.map(() => minScale);
    let raf = null;
    let lastClickIdx = -1;

    // Cache icon centers (computed lazily, refreshed on each frame because
    // they change as siblings scale).
    function iconCenters() {
      const dockRect = dock.getBoundingClientRect();
      return icons.map((icon) => {
        const r = icon.getBoundingClientRect();
        return ((r.left + r.right) / 2) - dockRect.left;
      });
    }

    function targetScales() {
      if (mouseX === null) return icons.map(() => minScale);
      const centers = iconCenters();
      return centers.map((c) => {
        const dist = mouseX - c;
        if (Math.abs(dist) > effectWidth / 2) return minScale;
        // (1 - cos(theta)) / 2 → smooth bell curve
        const theta = ((dist + effectWidth / 2) / effectWidth) * 2 * Math.PI;
        const factor = (1 - Math.cos(theta)) / 2;
        return minScale + factor * (maxScale - minScale);
      });
    }

    function frame() {
      const target = targetScales();
      let needs = mouseX !== null;
      const lerp = mouseX !== null ? 0.30 : 0.18;
      scales = scales.map((s, i) => {
        const next = s + (target[i] - s) * lerp;
        if (Math.abs(next - target[i]) > 0.003) needs = true;
        return next;
      });
      icons.forEach((icon, i) => {
        if (i === lastClickIdx) return;       // bounce animation owns this one briefly
        icon.style.transform = `scale(${scales[i].toFixed(3)})`;
      });
      raf = needs ? requestAnimationFrame(frame) : null;
    }

    function start() { if (!raf) raf = requestAnimationFrame(frame); }

    dock.addEventListener('mousemove', (e) => {
      const r = dock.getBoundingClientRect();
      mouseX = e.clientX - r.left;
      start();
    });
    dock.addEventListener('mouseleave', () => { mouseX = null; start(); });

    icons.forEach((icon, i) => {
      icon.addEventListener('click', () => {
        lastClickIdx = i;
        const s = scales[i];
        icon.style.transition = 'transform 180ms ease-out';
        icon.style.transform = `translateY(-12px) scale(${s.toFixed(3)})`;
        setTimeout(() => {
          icon.style.transform = `translateY(0px) scale(${s.toFixed(3)})`;
          setTimeout(() => {
            icon.style.transition = '';
            lastClickIdx = -1;
            start();
          }, 200);
        }, 200);
      });
    });
  }

  const notch = document.getElementById('notch');
  if (!notch) return;

  // The notch cycles through these states on a loop. Music is the
  // dominant resting state — long hold up front so visitors immediately
  // associate the pill with the now-playing surface. Then the panel
  // opens and walks through every tab.
  const cycle = [
    { state: 'music', hold: 7000 },
    { state: 'panel', hold: 16000, tabs: ['music', 'notes', 'images', 'videos', 'files'], tabHold: 3200 },
    { state: 'shot',  hold: 2600 },
    { state: 'video', hold: 3500 },
    { state: 'music', hold: 5500 },
  ];

  // Tab pane cycler — runs while the panel is open.
  const panelTabs = document.querySelectorAll('#panelTabs button');
  const panes     = document.querySelectorAll('#panelBody .pane');
  let tabTimer = null;
  function setTab(name) {
    panelTabs.forEach((b) => b.classList.toggle('is-active', b.dataset.pt === name));
    panes.forEach((p) => p.classList.toggle('is-active', p.dataset.pp === name));
  }
  function startTabCycle(tabs, hold) {
    let ti = 0;
    setTab(tabs[0]);
    clearInterval(tabTimer);
    tabTimer = setInterval(() => {
      ti = (ti + 1) % tabs.length;
      setTab(tabs[ti]);
    }, hold);
  }
  function stopTabCycle() {
    clearInterval(tabTimer);
    tabTimer = null;
  }

  let i = 0;
  let timer = null;

  function step() {
    const cur = cycle[i];
    notch.setAttribute('data-state', cur.state);

    if (cur.state === 'panel' && cur.tabs) {
      startTabCycle(cur.tabs, cur.tabHold || 3000);
    } else {
      stopTabCycle();
    }

    timer = setTimeout(() => {
      i = (i + 1) % cycle.length;
      step();
    }, cur.hold);
  }

  // Wait until the hero is on screen before starting — saves the
  // animation for someone who's actually looking, not someone who
  // landed mid-page from a deep link.
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (e.isIntersecting && timer === null) {
        step();
      }
    });
  }, { threshold: 0.4 });
  io.observe(notch);

  // Pausing on tab switch keeps things sane in the background.
  document.addEventListener('visibilitychange', () => {
    if (document.hidden && timer) {
      clearTimeout(timer);
      timer = null;
    } else if (!document.hidden && !timer) {
      step();
    }
  });


  // ============ Hover-scroll: stroke draws + cursor rides + notch opens ============
  const hoverSection = document.querySelector('.hover-scroll');
  const hoverPath    = document.getElementById('hoverPath');
  const hoverCursor  = document.getElementById('hoverCursor');
  // Two notch ids are supported: the new `.hmac-notch` inside the
  // MacBook frame and the legacy floating notch. They share the id
  // `hoverNotch` — whichever exists is what we drive.
  const hoverNotch   = document.getElementById('hoverNotch');
  const hoverCaption = document.getElementById('hoverCaption');

  if (hoverSection && hoverPath && hoverCursor && hoverNotch) {
    const length = hoverPath.getTotalLength();
    hoverPath.style.strokeDasharray  = String(length);
    hoverPath.style.strokeDashoffset = String(length);

    // Two progress values: `target` jumps with scroll, `smooth` lerps
    // toward it every frame. The cursor reads `smooth`, so it glides
    // into position even when the user flicks the trackpad fast.
    let targetProgress = 0;
    let smoothProgress = 0;
    let raf = null;
    let lastNotchState = '';

    function paint(progress) {
      // Path draws 0 → length as progress goes 0 → 1.
      hoverPath.style.strokeDashoffset = String(length * (1 - progress));

      // Cursor rides the drawn end of the path.
      const point = hoverPath.getPointAtLength(length * progress);
      hoverCursor.setAttribute('transform', `translate(${point.x}, ${point.y})`);

      // Cursor fades as it merges into the notch.
      hoverCursor.style.opacity = String(progress > 0.94 ? 0 : 1);

      // Notch state — tease at 0.55, open at 0.85.
      let next = '';
      if (progress > 0.85) next = 'is-open';
      else if (progress > 0.55) next = 'is-tease';
      if (next !== lastNotchState) {
        hoverNotch.classList.remove('is-tease', 'is-open');
        if (next) hoverNotch.classList.add(next);
        lastNotchState = next;
        if (hoverCaption) hoverCaption.classList.toggle('is-visible', next === 'is-open');
      }
    }

    function loop() {
      raf = null;
      const diff = targetProgress - smoothProgress;
      // 18% per frame ≈ ~5-6 frames to settle, feels weighty but responsive
      smoothProgress += diff * 0.18;
      paint(smoothProgress);
      // Keep going until we're within ~half a path-pixel of target
      if (Math.abs(diff) > 0.0008) raf = requestAnimationFrame(loop);
      else smoothProgress = targetProgress; // snap final drift
    }

    function recalcTarget() {
      const rect = hoverSection.getBoundingClientRect();
      const total = hoverSection.offsetHeight - window.innerHeight;
      const scrolled = Math.max(0, -rect.top);
      targetProgress = Math.max(0, Math.min(1, total > 0 ? scrolled / total : 0));
      if (!raf) raf = requestAnimationFrame(loop);
    }

    window.addEventListener('scroll', recalcTarget, { passive: true });
    window.addEventListener('resize', recalcTarget, { passive: true });
    // Snap to current scroll position on first paint so we don't see
    // the cursor swing in from 0% on a deep-link refresh.
    recalcTarget();
    smoothProgress = targetProgress;
    paint(smoothProgress);
  }


  // ============ Montage carousel — auto-cycles feature cards ============
  const montage = document.getElementById('montageStage');
  const dotsBox = document.getElementById('montageDots');
  if (montage && dotsBox) {
    const cards = Array.from(montage.querySelectorAll('.mc'));
    const dots  = Array.from(dotsBox.querySelectorAll('span'));
    const HOLD  = 3400;
    let idx = 0;
    let mTimer = null;

    function showCard(i) {
      cards.forEach((c, k) => c.classList.toggle('is-active', k === i));
      dots.forEach((d, k) => d.classList.toggle('is-active', k === i));
    }

    function tick() {
      idx = (idx + 1) % cards.length;
      showCard(idx);
      mTimer = setTimeout(tick, HOLD);
    }

    // Only start cycling when the section is on screen — no offscreen CPU.
    const startIO = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting && !mTimer) {
          mTimer = setTimeout(tick, HOLD);
        } else if (!e.isIntersecting && mTimer) {
          clearTimeout(mTimer);
          mTimer = null;
        }
      });
    }, { threshold: 0.25 });
    startIO.observe(montage);
  }


  // ============ Section animations (scroll into view) ============
  const animSections = document.querySelectorAll('[data-anim]');
  if (animSections.length && 'IntersectionObserver' in window) {
    const animIO = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (e.isIntersecting) {
          e.target.classList.add('is-visible');
          // Run the video-demo percent counter manually since CSS content can't tween
          if (e.target.dataset.anim === 'video') {
            const pct = e.target.querySelector('.vd-pct');
            if (pct) {
              setTimeout(() => {
                let v = 0;
                const id = setInterval(() => {
                  v += 2;
                  if (v >= 78) { v = 78; clearInterval(id); }
                  pct.textContent = v + '%';
                }, 100);
              }, 2100);
            }
          }
          animIO.unobserve(e.target);
        }
      });
    }, { threshold: 0.35, rootMargin: '0px 0px -10% 0px' });
    animSections.forEach((s) => animIO.observe(s));
  }
})();
