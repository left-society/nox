// Notetaker site — drives the hero notch through its states + the macOS dock.
// One file. No framework.

(function () {
  'use strict';

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
    { state: 'panel', hold: 14000, tabs: ['notes', 'images', 'videos', 'music'], tabHold: 3200 },
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
  const hoverNotch   = document.getElementById('hoverNotch');

  if (hoverSection && hoverPath && hoverCursor && hoverNotch) {
    const length = hoverPath.getTotalLength();
    hoverPath.style.strokeDasharray  = String(length);
    hoverPath.style.strokeDashoffset = String(length);

    let scrollRaf = null;
    let lastNotchState = '';

    function paint() {
      scrollRaf = null;

      const rect    = hoverSection.getBoundingClientRect();
      const total   = hoverSection.offsetHeight - window.innerHeight;
      const scrolled = Math.max(0, -rect.top);
      const progress = Math.max(0, Math.min(1, total > 0 ? scrolled / total : 0));

      // Path draws from 0 → length as scroll goes 0 → 1.
      hoverPath.style.strokeDashoffset = String(length * (1 - progress));

      // Cursor rides the drawn end of the path. SVG coordinates,
      // so we sit it inside the SVG and use a transform attribute.
      const point = hoverPath.getPointAtLength(length * progress);
      hoverCursor.setAttribute('transform', `translate(${point.x}, ${point.y})`);

      // Cursor fades out as it merges with the notch.
      hoverCursor.style.opacity = String(progress > 0.94 ? 0 : 1);

      // Notch transitions: tease at 0.55, open at 0.85.
      let next = '';
      if (progress > 0.85) next = 'is-open';
      else if (progress > 0.55) next = 'is-tease';
      if (next !== lastNotchState) {
        hoverNotch.classList.remove('is-tease', 'is-open');
        if (next) hoverNotch.classList.add(next);
        lastNotchState = next;
      }
    }

    function onScroll() {
      if (scrollRaf == null) scrollRaf = requestAnimationFrame(paint);
    }

    window.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', onScroll, { passive: true });
    paint(); // initial frame
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
