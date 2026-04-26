// Notetaker site — drives the hero notch through its states.
// One file. ~50 lines. No framework.

(function () {
  'use strict';

  const notch = document.getElementById('notch');
  if (!notch) return;

  // The notch cycles through these states on a loop, demonstrating
  // every kind of moment the real app handles.
  const cycle = [
    { state: 'music', hold: 3200 },
    { state: 'shot',  hold: 2400 },
    { state: 'video', hold: 3000 },
    { state: 'panel', hold: 4200 },
  ];

  let i = 0;
  let timer = null;

  function step() {
    notch.setAttribute('data-state', cycle[i].state);
    timer = setTimeout(() => {
      i = (i + 1) % cycle.length;
      step();
    }, cycle[i].hold);
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
})();
