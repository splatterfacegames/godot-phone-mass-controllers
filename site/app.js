// Simulated lobby: phones join, one buzzes, one drops and rejoins, repeat.
(function () {
  var roster = document.getElementById('sim-roster');
  var status = document.getElementById('sim-status');
  if (!roster || !status) return;

  var NAMES = [
    ['Ada', '#ff6b6b'], ['Bo', '#ffa94d'], ['Cy', '#ffd43b'], ['Dee', '#69db7c'],
    ['Eli', '#4dd4fa'], ['Fay', '#b197fc'], ['Gus', '#f783ac'], ['Han', '#63e6be']
  ];
  var players = [];
  var timers = [];
  var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  function later(fn, ms) { timers.push(setTimeout(fn, ms)); }

  function chip(p) {
    var el = document.createElement('span');
    el.className = 'sim-player';
    var av = document.createElement('span');
    av.className = 'avatar';
    av.style.background = p.color;
    av.textContent = p.name[0];
    var nm = document.createElement('span');
    nm.textContent = p.name;
    var dot = document.createElement('i');
    dot.className = 'dot';
    el.appendChild(av); el.appendChild(nm); el.appendChild(dot);
    return el;
  }

  function label() {
    var on = players.filter(function (p) { return p.online; }).length;
    status.textContent = on === 0 ? 'Waiting for players…'
      : on + (on === 1 ? ' player in' : ' players in') + ' — phones are the controllers';
  }

  function join(p) {
    p.online = true;
    p.el = chip(p);
    roster.appendChild(p.el);
    label();
  }

  function cycle() {
    timers.forEach(clearTimeout);
    timers = [];
    roster.textContent = '';
    players = NAMES.map(function (n, i) {
      return { name: n[0], color: n[1], online: false, el: null, idx: i };
    });
    label();

    players.forEach(function (p, i) {
      later(function () { join(p); }, 500 + i * 700);
    });

    var t = 500 + players.length * 700 + 900;

    // a few buzzes
    for (var b = 0; b < 3; b++) {
      later(function () {
        var on = players.filter(function (p) { return p.online && p.el; });
        if (!on.length) return;
        var pick = on[Math.floor(Math.random() * on.length)];
        pick.el.classList.add('buzz');
        setTimeout(function () { pick.el.classList.remove('buzz'); }, 700);
      }, t + b * 1600);
    }
    t += 3 * 1600 + 400;

    // one phone drops, then rejoins inside the grace period
    later(function () {
      var p = players[2];
      if (!p || !p.el) return;
      p.online = false;
      p.el.classList.add('offline');
      label();
    }, t);
    later(function () {
      var p = players[2];
      if (!p || !p.el) return;
      p.online = true;
      p.el.classList.remove('offline');
      label();
    }, t + 2400);

    if (!reduced) later(cycle, t + 2400 + 4200);
  }

  cycle();
})();
