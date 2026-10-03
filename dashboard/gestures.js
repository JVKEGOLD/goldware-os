/* GoldWare OS gesture demos: an animated, code-drawn demonstration of every Vision gesture.
 * No dependencies and no image files: every hand is SVG built here.
 *
 *   GoldWareGestures.list()                    -> [{id, name, mode, does, how, holdMs}]
 *   GoldWareGestures.render(el, id, {loop: true, size: 'm'})
 *
 * The catalog below (between the GESTURE-DATA markers) is plain JSON. tests/test_gestures.py reads it
 * to check that every gesture the Swift app recognises has a demo, and scripts/gestures_doc.py writes
 * docs/GESTURES.md from it. Edit the catalog, then run `python3 scripts/gestures_doc.py`.
 *
 * The unlock gesture is private: it is never drawn, named, or described. It renders as a placeholder.
 */
(function () {
  "use strict";

  var DATA = /*GESTURE-DATA-BEGIN*/[
    {"id": "point", "name": "Point", "mode": "Pointer", "holdMs": 0,
     "how": "Index finger up, the other fingers curled. Move your hand.",
     "does": "Moves the pointer like a finger on a trackpad. The gap between your thumb and index tips sets the speed: a wide L is up to 2.5x, thumb close to the finger is 0.25x for fine work.",
     "steps": ["Point your index finger at the screen.", "Move your hand: the pointer follows.", "Bring your thumb in close for slow, precise moves."]},
    {"id": "pinch-click", "name": "Pinch to click", "mode": "Pointer", "holdMs": 0,
     "how": "Touch your thumb tip to your index tip and let go within 0.6 s, without moving.",
     "does": "Clicks where the pointer is. Two pinches within 0.6 s in the same spot double-click. The pointer holds still for a moment after a click so a double-click lands where you aimed.",
     "steps": ["Aim with your index finger.", "Pinch thumb to index and let go: click.", "Pinch twice quickly: double-click."]},
    {"id": "pinch-scroll", "name": "Pinch and move to scroll", "mode": "Pointer", "holdMs": 0,
     "how": "Pinch, keep holding, and move your hand in any direction.",
     "does": "Scrolls: the page follows your hand. Let go mid-move to fling it; pinch again to catch it.",
     "steps": ["Pinch and hold.", "Move your hand: the page follows it.", "Let go while moving to fling the page."]},
    {"id": "rest", "name": "Rest", "mode": "Pointer", "holdMs": 0,
     "how": "Open hand or fist.",
     "does": "Nothing. The pointer stays where it is while you reposition, like lifting a mouse off the desk.",
     "steps": ["Open your hand or make a fist.", "Move freely: the pointer stays put."]},
    {"id": "ok-mirror", "name": "OK sign: hide or show the mirror", "mode": "Any style", "holdMs": 800,
     "how": "Thumb and index tips touching in a ring, the other three fingers straight. Hold for 0.8 s.",
     "does": "Hides the camera mirror under the notch while Vision keeps running, or shows it again. It is never a click.",
     "steps": ["Make an OK sign.", "Hold it while the ring fills.", "The mirror hides. Do it again to bring it back."]},
    {"id": "four-quadrants", "name": "Four fingers: switch to Quadrants", "mode": "Pointer", "holdMs": 800,
     "how": "Four fingers up with the thumb folded across your palm. Hold for 0.8 s.",
     "does": "Switches to Quadrants and tiles your windows into the four corners of the screen.",
     "steps": ["Hold up four fingers, thumb folded in.", "Hold it while the ring fills.", "Your windows tile into the four corners."]},
    {"id": "open-pointer", "name": "Open hand: back to the pointer", "mode": "Quadrants", "holdMs": 800,
     "how": "All four fingers up and the thumb spread wide. Hold for 0.8 s.",
     "does": "Leaves Quadrants and goes back to the pointer.",
     "steps": ["Open your hand, thumb spread wide.", "Hold it while the ring fills.", "You are back to the pointer."]},
    {"id": "quadrant-dictate", "name": "1 to 4 fingers: dictate into a corner", "mode": "Quadrants", "holdMs": 450,
     "how": "Hold up 1, 2, 3, or 4 fingers (the thumb does not count). Keep them up, talk, then lower your hand.",
     "does": "Picks a corner: 1 top left, 2 top right, 3 bottom left, 4 bottom right. That window comes forward, the cursor goes into its text box, and GoldWare listens while your fingers stay up. Lowering them pastes what you said.",
     "steps": ["Hold up fingers for a corner. Passing through 1 and 2 on the way to 3 picks nothing.", "Keep them up: the window comes forward and listens.", "Talk.", "Lower your hand: what you said is pasted there."]},
    {"id": "quadrant-rest", "name": "Fist: rest in Quadrants", "mode": "Quadrants", "holdMs": 0,
     "how": "Make a fist.",
     "does": "Rests. No corner is picked, so it is the safe place between messages.",
     "steps": ["Make a fist.", "Nothing is picked until you raise fingers again."]},
    {"id": "swipe-send", "name": "Swipe left: send", "mode": "Pointer and Quadrants", "holdMs": 0,
     "how": "Open hand, three or more fingers up, swept quickly to your left as you face the screen: about a fifth of the camera's view in half a second.",
     "does": "Presses Return in the window your last hand dictation pasted into, so the message sends. Only within 2 minutes of the paste, only if that window is still in front, and only if nothing was typed since. A pointing hand or a pinch never sends.",
     "steps": ["Dictate something by hand first.", "Open your hand and sweep it to your left.", "Return is pressed: the message sends."]},
    {"id": "pinky-clear", "name": "Pinky: clear the paste", "mode": "Pointer and Quadrants", "holdMs": 800,
     "how": "Little finger up on its own, thumb not spread out. Hold for 0.8 s.",
     "does": "Deletes what your last hand dictation pasted, under the same rules as sending.",
     "steps": ["Raise just your little finger.", "Hold it while the ring fills.", "The text you just dictated is deleted."]},
    {"id": "lock", "name": "Praying hands: lock", "mode": "Any style", "holdMs": 800,
     "how": "Both hands, palms together and fingertips touching. Hold for 0.8 s.",
     "does": "Locks Vision Mode. Your hands drive nothing until your unlock gesture. It also locks by itself after a minute with no hand in view.",
     "steps": ["Bring your palms together.", "Hold while the ring fills.", "The lock beside the notch closes."]},
    {"id": "unlock", "name": "Your unlock gesture", "mode": "Locked", "holdMs": null,
     "how": "Private. You choose it, and GoldWare never shows it.",
     "does": "Unlocks Vision Mode. Vision starts locked every time it turns on, so a hand passing by never acts.",
     "steps": ["Give your own unlock gesture with both hands in view."]},
    {"id": "lets-work", "name": "Let's work", "mode": "Pointer", "holdMs": 200,
     "how": "Both hands with thumb, index, and middle out (ring and little curled). Touch your thumb tips together for a moment, then pull your hands apart.",
     "does": "Opens one terminal in each corner of the screen, the same as saying \"Let's work\". It fires once, until you drop the shape.",
     "steps": ["Both hands: thumb, index, and middle out.", "Touch your thumb tips together.", "Pull your hands apart: four terminals open."]},
    {"id": "lock-up", "name": "Lock up", "mode": "Pointer", "holdMs": 300,
     "how": "Both hands open and apart for a moment, then close both into fists within a second.",
     "does": "Closes every terminal except those with an agent in the middle of a task, the same as saying \"Lock up\".",
     "steps": ["Hold both hands open.", "Close both into fists.", "Idle terminals close. A working agent stays open."]},
    {"id": "clear-out", "name": "Clear out", "mode": "Pointer", "holdMs": 500,
     "how": "Both hands open for a moment, then close one into a fist and keep the other open for half a second.",
     "does": "Closes only the Hermes terminals nobody has written in, the same as saying \"Clear out\".",
     "steps": ["Hold both hands open.", "Close one hand. Keep the other open while the ring fills.", "Unused agent terminals close. The ones you wrote in stay."]},
    {"id": "scan-hold", "name": "Hold up a document to scan", "mode": "Mirror scan", "holdMs": 1100,
     "how": "Open the mirror (rest the pointer behind the camera notch) and hold a card, receipt, or page still in view.",
     "does": "A gold outline closes around it as you hold still, then it is read on this Mac. The image is never saved.",
     "steps": ["Open the mirror and hold the page up.", "Hold still while the outline closes.", "It is read on this Mac."]},
    {"id": "scan-file", "name": "Thumbs up: file the scan", "mode": "Mirror scan", "holdMs": 700,
     "how": "After a scan is read: a fist with the thumb pointing straight up. Hold for 0.7 s.",
     "does": "Files it as one task with what it is, any due date, and the details it read. Nothing is sent to anyone.",
     "steps": ["The scan is read and waiting.", "Thumbs up and hold.", "Filed as one task."]},
    {"id": "scan-copy", "name": "Two fingers: copy the scan", "mode": "Mirror scan", "holdMs": 600,
     "how": "After a scan is read: two fingers up. Hold for 0.6 s.",
     "does": "Copies what it read to the clipboard.",
     "steps": ["The scan is read and waiting.", "Two fingers up and hold.", "Copied to the clipboard."]},
    {"id": "scan-discard", "name": "Fist: discard the scan", "mode": "Mirror scan", "holdMs": 600,
     "how": "After a scan is read, or when it failed: make a fist. Hold for 0.6 s.",
     "does": "Throws the scan away. Nothing is kept.",
     "steps": ["The scan is waiting.", "Make a fist and hold.", "Discarded."]}
  ]/*GESTURE-DATA-END*/;

  var NS = "http://www.w3.org/2000/svg";
  var uid = 0;

  function mk(tag, attrs, parent) {
    var e = document.createElementNS(NS, tag);
    for (var k in attrs) if (attrs[k] != null) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }
  function set(e, attrs) { for (var k in attrs) e.setAttribute(k, attrs[k]); }
  function lerp(a, b, t) { return a + (b - a) * t; }
  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }
  function ease(t) { return t * t * (3 - 2 * t); }
  function f1(n) { return Math.round(n * 100) / 100; }

  // ---------- the hand ----------
  // A right hand, palm to the camera, in a 100 x 100 box. Fingers are capsules (round-capped strokes)
  // that grow out of the palm; curled fingers fold down over it. Parameters, all numbers so any two
  // poses blend smoothly:
  //   f: [index, middle, ring, little] extension 0..1     fa: extra angle per finger (degrees)
  //   ta: thumb angle (0 straight up, negative out to the side)   tl: thumb length factor
  //   pinch: 0..1 pulls the thumb tip to the index tip    lit: [thumb, index, middle, ring, little] 0..1
  //   x, y, s, r: where the hand sits in the stage, its scale and tilt
  var FB = [[37.5, 46], [47.5, 44.5], [57.5, 46], [66.5, 50]];
  var FL = [33, 37, 33, 25];
  var FW = [9.4, 9.8, 9.2, 7.8];
  var FA = [-6, -1, 4, 10];
  var TB = [36.5, 71];
  var TL = 27;
  var PALM = "M33 47 C33 44 37 42.5 41 43 L66 45 C71 45.5 73 48 72.5 52 L71 72 C70.5 80 66 85 60 87 L60 99 L40 99 L40 87 C34 84.5 31 79 31 72 Z";

  function dir(a) { var r = a * Math.PI / 180; return [Math.sin(r), -Math.cos(r)]; }

  var POSE = {
    open:     { f: [1, 1, 1, 1], fa: [0, 0, 0, 0], ta: -58, tl: 1, pinch: 0, lit: [0, 0, 0, 0, 0] },
    point:    { f: [1, 0, 0, 0], fa: [0, 0, 0, 0], ta: -40, tl: 0.95, pinch: 0, lit: [0, 1, 0, 0, 0] },
    pointWide:{ f: [1, 0, 0, 0], fa: [0, 0, 0, 0], ta: -78, tl: 1.05, pinch: 0, lit: [1, 1, 0, 0, 0] },
    pointFine:{ f: [1, 0, 0, 0], fa: [0, 0, 0, 0], ta: -18, tl: 0.85, pinch: 0, lit: [1, 1, 0, 0, 0] },
    pinch:    { f: [0.72, 0, 0, 0], fa: [-26, 0, 0, 0], ta: -40, tl: 0.95, pinch: 1, lit: [1, 1, 0, 0, 0] },
    fist:     { f: [0, 0, 0, 0], fa: [0, 0, 0, 0], ta: 62, tl: 0.62, pinch: 0, lit: [0, 0, 0, 0, 0] },
    four:     { f: [1, 1, 1, 1], fa: [0, 0, 0, 0], ta: 64, tl: 0.66, pinch: 0, lit: [0, 1, 1, 1, 1] },
    ok:       { f: [0.42, 1, 1, 1], fa: [-62, 2, 4, 6], ta: -50, tl: 0.62, pinch: 0, ring: 1, lit: [1, 1, 0, 0, 0] },
    pinky:    { f: [0, 0, 0, 1], fa: [0, 0, 0, 4], ta: 58, tl: 0.62, pinch: 0, lit: [0, 0, 0, 0, 1] },
    thumbsUp: { f: [0, 0, 0, 0], fa: [0, 0, 0, 0], ta: -6, tl: 1.0, tbx: 3, tby: -21, pinch: 0, lit: [1, 0, 0, 0, 0] },
    two:      { f: [1, 1, 0, 0], fa: [-6, 5, 0, 0], ta: 60, tl: 0.62, pinch: 0, lit: [0, 1, 1, 0, 0] },
    one:      { f: [1, 0, 0, 0], fa: [0, 0, 0, 0], ta: 56, tl: 0.62, pinch: 0, lit: [0, 1, 0, 0, 0] },
    three:    { f: [1, 1, 1, 0], fa: [-4, 0, 4, 0], ta: 60, tl: 0.62, pinch: 0, lit: [0, 1, 1, 1, 0] },
    lw:       { f: [1, 1, 0, 0], fa: [-4, 2, 0, 0], ta: -72, tl: 1.05, pinch: 0, lit: [1, 1, 1, 0, 0] },
    pray:     { f: [1, 1, 1, 1], fa: [4, 2, 0, -3], ta: -6, tl: 0.9, pinch: 0, lit: [0, 0, 0, 0, 0] }
  };

  function pose(name, extra) {
    var p = JSON.parse(JSON.stringify(POSE[name]));
    p.x = 0; p.y = 0; p.s = 1; p.r = 0; p.o = 1;
    p.tbx = p.tbx || 0; p.tby = p.tby || 0; p.ring = p.ring || 0;
    for (var k in extra || {}) p[k] = extra[k];
    return p;
  }

  function Hand(parent, mirrored) {
    var root = mk("g", { "class": "gwg-hand" }, parent);
    var flip = mk("g", { transform: mirrored ? "translate(100 0) scale(-1 1)" : null }, root);
    var fingers = [], folds = [];
    var back = mk("g", {}, flip);
    for (var i = 0; i < 4; i++) {
      fingers.push({
        rim: mk("line", { "class": "gwg-rim", "stroke-width": FW[i] + 2.2 }, back),
        skin: mk("line", { "class": "gwg-skin", "stroke-width": FW[i] }, back),
        gold: mk("line", { "class": "gwg-gold", "stroke-width": FW[i] - 0.6 }, back),
        nail: mk("circle", { "class": "gwg-nail", r: FW[i] * 0.26 }, back)
      });
    }
    mk("path", { d: PALM, "class": "gwg-palm" }, flip);
    mk("path", { d: "M37 70 C45 75 56 74 65 66", "class": "gwg-crease" }, flip);
    mk("path", { d: "M37 61 C46 59 57 58 68 56", "class": "gwg-crease" }, flip);
    for (i = 0; i < 4; i++) {
      folds.push({
        rim: mk("line", { "class": "gwg-rim", "stroke-width": FW[i] + 2 }, flip),
        skin: mk("line", { "class": "gwg-fold", "stroke-width": FW[i] }, flip)
      });
    }
    var okRing = mk("circle", { r: 8, "class": "gwg-okring" }, flip);
    var thumb = {
      rim: mk("line", { "class": "gwg-rim", "stroke-width": 12.6 }, flip),
      skin: mk("line", { "class": "gwg-skin", "stroke-width": 10.4 }, flip),
      gold: mk("line", { "class": "gwg-gold", "stroke-width": 9.8 }, flip),
      nail: mk("circle", { "class": "gwg-nail", r: 2.7 }, flip)
    };
    function line(l, a, b) { set(l, { x1: f1(a[0]), y1: f1(a[1]), x2: f1(b[0]), y2: f1(b[1]) }); }

    this.tips = [];
    this.update = function (p) {
      set(root, { transform: "translate(" + f1(p.x) + " " + f1(p.y) + ") scale(" + f1(p.s) + ") rotate(" + f1(p.r) + " 50 70)",
                  opacity: f1(p.o) });
      var tips = [];
      for (var i = 0; i < 4; i++) {
        var e = clamp(p.f[i], 0, 1), d = dir(FA[i] + p.fa[i]), b = FB[i];
        var len = FL[i] * e;
        var tip = [b[0] + d[0] * len, b[1] + d[1] * len];
        tips.push(tip);
        var F = fingers[i];
        line(F.rim, b, tip); line(F.skin, b, tip); line(F.gold, b, tip);
        set(F.gold, { "stroke-opacity": f1(p.lit[i + 1] * clamp(e * 3, 0, 1)) });
        var nd = len - FW[i] * 0.35;
        set(F.nail, { cx: f1(b[0] + d[0] * nd), cy: f1(b[1] + d[1] * nd), opacity: f1(clamp((e - 0.35) * 3, 0, 1)) });
        // Curled: the finger folds down over the palm, knuckle at the top.
        var c = clamp(1 - e / 0.55, 0, 1);
        var fs = [b[0] + 0.5, b[1] - 1.5], fe = [b[0] + 1.2 * c, b[1] - 1.5 + 15 * c];
        line(folds[i].rim, fs, fe); line(folds[i].skin, fs, fe);
        set(folds[i].rim, { opacity: f1(clamp(c * 4, 0, 1)) });
        set(folds[i].skin, { opacity: f1(clamp(c * 4, 0, 1)) });
      }
      var td = dir(p.ta), tl = TL * p.tl, tb = [TB[0] + p.tbx, TB[1] + p.tby];
      var tend = [tb[0] + td[0] * tl, tb[1] + td[1] * tl];
      if (p.pinch > 0) {
        var it = tips[0], ix = dir(FA[0] + p.fa[0]);
        var target = [it[0] - ix[0] * 2 - 3.5, it[1] - ix[1] * 2 + 2];
        tend = [lerp(tend[0], target[0], p.pinch), lerp(tend[1], target[1], p.pinch)];
      }
      line(thumb.rim, tb, tend); line(thumb.skin, tb, tend); line(thumb.gold, tb, tend);
      set(thumb.gold, { "stroke-opacity": f1(p.lit[0]) });
      // The OK sign's ring: the gap the curled index and the thumb close around.
      var it0 = tips[0], mx = (tend[0] + it0[0]) / 2, my = (tend[1] + it0[1]) / 2;
      var gap = Math.sqrt((tend[0] - it0[0]) * (tend[0] - it0[0]) + (tend[1] - it0[1]) * (tend[1] - it0[1]));
      set(okRing, { cx: f1(mx - 3), cy: f1(my), r: f1(Math.max(5, gap / 2)), opacity: f1(clamp(p.ring * 2 - 1, 0, 1)) });
      var dx = tend[0] - tb[0], dy = tend[1] - tb[1], dl = Math.sqrt(dx * dx + dy * dy) || 1;
      set(thumb.nail, { cx: f1(tend[0] - dx / dl * 3), cy: f1(tend[1] - dy / dl * 3) });
      tips.unshift(tend);
      // Fingertips in stage coordinates, for effects that sit on a fingertip.
      var rr = p.r * Math.PI / 180, cs = Math.cos(rr), sn = Math.sin(rr);
      this.tips = tips.map(function (t) {
        var x = mirrored ? 100 - t[0] : t[0], y = t[1];
        var X = 50 + (x - 50) * cs - (y - 70) * sn, Y = 70 + (x - 50) * sn + (y - 70) * cs;
        return [p.x + X * p.s, p.y + Y * p.s];
      });
    };
  }

  function blendHand(a, b, t) {
    var o = {};
    for (var k in a) {
      if (Array.isArray(a[k])) o[k] = a[k].map(function (v, i) { return lerp(v, b[k][i], t); });
      else o[k] = lerp(a[k], b[k], t);
    }
    return o;
  }
  function blendFx(a, b, t) {
    var o = {};
    for (var k in a) o[k] = (k in b) ? lerp(a[k], b[k], t) : a[k];
    for (k in b) if (!(k in o)) o[k] = b[k];
    return o;
  }

  // Keys: [ms, {h, h2, fx}]. Missing fields carry over from the key before.
  function prepare(anim) {
    var last = {};
    anim.keys = anim.keys.map(function (k) {
      var v = k[1], full = {};
      ["h", "h2"].forEach(function (n) { full[n] = v[n] || last[n]; });
      full.fx = {};
      for (var x in last.fx || {}) full.fx[x] = last.fx[x];
      for (x in v.fx || {}) full.fx[x] = v.fx[x];
      last = full;
      return [k[0], full];
    });
    return anim;
  }
  function sample(anim, t) {
    var ks = anim.keys;
    if (t <= ks[0][0]) return ks[0][1];
    for (var i = 1; i < ks.length; i++) {
      if (t <= ks[i][0]) {
        var a = ks[i - 1], b = ks[i], u = ease((t - a[0]) / Math.max(1, b[0] - a[0]));
        return {
          h: a[1].h && blendHand(a[1].h, b[1].h, u),
          h2: a[1].h2 && blendHand(a[1].h2, b[1].h2, u),
          fx: blendFx(a[1].fx, b[1].fx, u)
        };
      }
    }
    return ks[ks.length - 1][1];
  }

  // ---------- shared stage pieces ----------
  // Stage is 200 x 130. Hands live on the left; the Mac screen, with the result, on the right.
  var SCR = { x: 112, y: 12, w: 82, h: 54 };

  function screen(g, opts) {
    var s = mk("g", { "class": "gwg-screen" }, g);
    mk("rect", { x: SCR.x, y: SCR.y, width: SCR.w, height: SCR.h, rx: 5, "class": "gwg-bezel" }, s);
    var inner = mk("svg", { x: SCR.x + 2, y: SCR.y + 2, width: SCR.w - 4, height: SCR.h - 4, viewBox: "0 0 78 50", overflow: "hidden" }, s);
    mk("rect", { x: 0, y: 0, width: 78, height: 50, rx: 3.5, "class": "gwg-desk" }, inner);
    var content = mk("g", {}, inner);
    if (!opts || opts.notch !== false) mk("rect", { x: 32, y: -3, width: 14, height: 6.2, rx: 2.4, "class": "gwg-notch" }, inner);
    mk("path", { d: "M" + (SCR.x + SCR.w / 2 - 9) + " " + (SCR.y + SCR.h) + " l-3 7 h24 l-3 -7 Z", "class": "gwg-stand" }, s);
    return content;
  }

  function cursor(parent) {
    var c = mk("path", { d: "M0 0 L0 8.5 L2.2 6.6 L3.8 10 L5.2 9.4 L3.7 6.1 L6.6 6.1 Z", "class": "gwg-cursor" }, parent);
    return function (x, y, o) { set(c, { transform: "translate(" + f1(x) + " " + f1(y) + ")", opacity: o == null ? 1 : f1(o) }); };
  }

  // The hold timer: a ring that fills while a held gesture is held, then flashes.
  function holdRing(g, ms, x, y) {
    var r = 10.5, C = 2 * Math.PI * r;
    var w = mk("g", { "class": "gwg-ring", transform: "translate(" + x + " " + y + ")" }, g);
    mk("circle", { r: r, "class": "gwg-ring-track" }, w);
    var arc = mk("circle", { r: r, "class": "gwg-ring-fill", "stroke-dasharray": f1(C), transform: "rotate(-90)" }, w);
    var flash = mk("circle", { r: r, "class": "gwg-ring-flash" }, w);
    var label = mk("text", { y: 3, "class": "gwg-ring-text" }, w);
    label.textContent = (ms / 1000).toFixed(ms % 1000 && ms % 100 === 0 ? 1 : ms % 100 ? 2 : 0) + "s";
    var cap = mk("text", { y: r + 8, "class": "gwg-ring-cap" }, w);
    cap.textContent = "hold";
    return function (p, done) {
      p = clamp(p || 0, 0, 1); done = done || 0;
      set(arc, { "stroke-dashoffset": f1(C * (1 - p)) });
      set(w, { opacity: f1(0.35 + 0.65 * Math.max(p > 0 ? 1 : 0, done)) });
      set(flash, { r: f1(r + done * 7), opacity: f1(done > 0 && done < 1 ? 1 - done : 0) });
      w.classList.toggle("on", p >= 1);
    };
  }

  // A motion arrow, drawn along a path, that fades in and out.
  function arrow(g, d, head) {
    var a = mk("g", { "class": "gwg-arrow" }, g);
    mk("path", { d: d, "class": "gwg-arrow-line" }, a);
    mk("path", { d: "M-4 -3.6 L1.5 0 L-4 3.6", transform: head, "class": "gwg-arrow-head" }, a);
    return function (o) { set(a, { opacity: f1(clamp(o, 0, 1)) }); };
  }

  function label(g, x, y, cls) {
    var t = mk("text", { x: x, y: y, "class": cls || "gwg-tag" }, g);
    return function (s, o) { if (t.textContent !== s) t.textContent = s; set(t, { opacity: f1(o == null ? 1 : o) }); };
  }

  function chatBox(c) {
    mk("rect", { x: 4, y: 6, width: 70, height: 40, rx: 2.5, "class": "gwg-win" }, c);
    mk("rect", { x: 8, y: 36, width: 62, height: 7, rx: 2, "class": "gwg-input" }, c);
    var text = mk("rect", { x: 10, y: 38.6, width: 0, height: 1.8, rx: 0.9, "class": "gwg-text" }, c);
    var bubble = mk("rect", { x: 40, y: 26, width: 28, height: 6, rx: 3, "class": "gwg-bubble" }, c);
    mk("rect", { x: 10, y: 12, width: 26, height: 6, rx: 3, "class": "gwg-bubble-in" }, c);
    return { text: text, bubble: bubble };
  }

  function quadGrid(c) {
    var q = [];
    [[1, 1], [40, 1], [1, 25.5], [40, 25.5]].forEach(function (p, i) {
      var g = mk("g", {}, c);
      var r = mk("rect", { x: p[0], y: p[1] + 2, width: 37, height: 21.5, rx: 2, "class": "gwg-quad" }, g);
      var n = mk("text", { x: p[0] + 4.5, y: p[1] + 9.5, "class": "gwg-quad-n" }, g);
      n.textContent = String(i + 1);
      q.push({ g: g, r: r, x: p[0], y: p[1] + 2 });
    });
    return q;
  }

  function terminals(c) {
    var t = [];
    [[2, 4], [40, 4], [2, 27], [40, 27]].forEach(function (p) {
      var g = mk("g", {}, c);
      mk("rect", { x: 0, y: 0, width: 36, height: 20, rx: 2, "class": "gwg-term" }, g);
      mk("rect", { x: 0, y: 0, width: 36, height: 3.6, rx: 1.5, "class": "gwg-term-bar" }, g);
      mk("text", { x: 2.5, y: 9.5, "class": "gwg-term-text" }, g).textContent = "$ hermes";
      var dot = mk("circle", { cx: 32, cy: 1.8, r: 1, "class": "gwg-term-dot" }, g);
      t.push({ g: g, x: p[0], y: p[1], dot: dot });
    });
    return t;
  }
  function placeTerm(t, show) {
    var s = 0.4 + 0.6 * show;
    set(t.g, { transform: "translate(" + f1(t.x + 18 * (1 - s)) + " " + f1(t.y + 10 * (1 - s)) + ") scale(" + f1(s) + ")", opacity: f1(clamp(show, 0, 1)) });
  }

  function lockIcon(g, x, y) {
    var w = mk("g", { transform: "translate(" + x + " " + y + ")", "class": "gwg-lock" }, g);
    var shackle = mk("path", { d: "M-3 0 V-3 a3 3 0 0 1 6 0 V0", "class": "gwg-lock-shackle" }, w);
    mk("rect", { x: -4.2, y: -0.5, width: 8.4, height: 6.5, rx: 1.4, "class": "gwg-lock-body" }, w);
    return function (closed) {
      set(shackle, { transform: "translate(" + f1(2.6 * (1 - closed)) + " " + f1(-1.6 * (1 - closed)) + ")" });
      w.classList.toggle("closed", closed > 0.5);
    };
  }

  // A card held in the hand (scan demos).
  function docCard(g) {
    var d = mk("g", { "class": "gwg-doc" }, g);
    mk("rect", { x: -17, y: -11, width: 34, height: 22, rx: 2, "class": "gwg-doc-card" }, d);
    mk("path", { d: "M-12 -5 h16 M-12 0 h22 M-12 5 h12", "class": "gwg-doc-lines" }, d);
    var C = 2 * (34 + 22) + 8;
    var trace = mk("rect", { x: -19.5, y: -13.5, width: 39, height: 27, rx: 3, "class": "gwg-doc-trace", "stroke-dasharray": C }, d);
    return function (x, y, p, o) {
      set(d, { transform: "translate(" + f1(x) + " " + f1(y) + ") rotate(-4)", opacity: f1(o == null ? 1 : o) });
      set(trace, { "stroke-dashoffset": f1(C * (1 - clamp(p, 0, 1))), opacity: f1(p > 0 ? 1 : 0) });
    };
  }

  // A small scan result card inside the screen.
  function scanCard(c) {
    var g = mk("g", { "class": "gwg-scancard" }, c);
    mk("rect", { x: 10, y: 9, width: 58, height: 32, rx: 3, "class": "gwg-win" }, g);
    mk("text", { x: 14, y: 17, "class": "gwg-mini" }, g).textContent = "Receipt, 42.10";
    mk("path", { d: "M14 23 h40 M14 28 h30 M14 33 h36", "class": "gwg-doc-lines" }, g);
    return g;
  }

  // ---------- per-gesture animation ----------
  var H1 = { x: 2, y: 8, s: 1.12 };          // one hand, left side of the stage
  function h1(name, extra) {
    var o = { x: H1.x, y: H1.y, s: H1.s };
    for (var k in extra || {}) o[k] = extra[k];
    return pose(name, o);
  }
  var ANIM = {};

  ANIM["point"] = {
    dur: 6000, stepAt: [0, 1300, 4000],
    keys: [
      [0, { h: h1("open"), fx: { cx: 34, cy: 26, arrow: 0, gap: 0 } }],
      [800, { h: h1("point") }],
      [1300, { h: h1("point"), fx: { arrow: 1 } }],
      [2200, { h: h1("point", { x: 16, y: 2 }), fx: { cx: 58, cy: 14 } }],
      [3100, { h: h1("point", { x: -6, y: 12 }), fx: { cx: 20, cy: 34 } }],
      [3800, { h: h1("point"), fx: { cx: 34, cy: 26, arrow: 0 } }],
      [4300, { h: h1("pointFine"), fx: { gap: 1 } }],
      [5100, { h: h1("pointFine", { x: 7, y: 5 }), fx: { cx: 38, cy: 23 } }],
      [5600, { h: h1("pointFine"), fx: { cx: 34, cy: 26 } }],
      [6000, { h: h1("open"), fx: { gap: 0 } }]
    ],
    scene: function (g) {
      var c = screen(g), cur = cursor(c);
      var trail = mk("circle", { r: 5, "class": "gwg-halo" }, c);
      var ar = arrow(g, "M84 34 h20 M84 34 h-12", "translate(104 34)");
      var ar2 = arrow(g, "M72 34 h0", "translate(72 34) rotate(180)");
      var t = label(g, 153, 84, "gwg-tag");
      return function (fx) {
        cur(fx.cx, fx.cy); set(trail, { cx: f1(fx.cx + 1), cy: f1(fx.cy + 2), opacity: f1(fx.arrow * 0.6) });
        ar(fx.arrow); ar2(fx.arrow);
        t(fx.gap > 0.5 ? "thumb close: 0.25x, fine" : "pointer follows", 1);
      };
    }
  };

  ANIM["pinch-click"] = {
    dur: 5200, stepAt: [0, 1000, 2800],
    keys: [
      [0, { h: h1("point"), fx: { click: 0, click2: 0, n: 0 } }],
      [900, { h: h1("point") }],
      [1300, { h: h1("pinch"), fx: { click: 0 } }],
      [1550, { h: h1("point"), fx: { click: 0.05, n: 1 } }],
      [2400, { fx: { click: 1 } }],
      [2900, { h: h1("point"), fx: { click: 0 } }],
      [3150, { h: h1("pinch") }],
      [3350, { h: h1("point"), fx: { click: 0.05, n: 1 } }],
      [3550, { h: h1("pinch") }],
      [3750, { h: h1("point"), fx: { click2: 0.05, n: 2 } }],
      [4700, { fx: { click: 1, click2: 1 } }],
      [5200, { fx: { click: 0, click2: 0, n: 0 } }]
    ],
    scene: function (g) {
      var c = screen(g);
      mk("rect", { x: 22, y: 18, width: 34, height: 12, rx: 3, "class": "gwg-button" }, c);
      var r1 = mk("circle", { cx: 36, cy: 24, "class": "gwg-ripple" }, c);
      var r2 = mk("circle", { cx: 36, cy: 24, "class": "gwg-ripple" }, c);
      var cur = cursor(c);
      var spark = mk("circle", { r: 3.2, "class": "gwg-spark" }, g);
      var t = label(g, 153, 84);
      return function (fx, t0, hand) {
        cur(36, 24);
        set(r1, { r: f1(2 + fx.click * 14), opacity: f1(fx.click > 0 && fx.click < 1 ? 1 - fx.click : 0) });
        set(r2, { r: f1(2 + fx.click2 * 20), opacity: f1(fx.click2 > 0 && fx.click2 < 1 ? 1 - fx.click2 : 0) });
        var tip = hand.tips[0];
        set(spark, { cx: f1(tip[0]), cy: f1(tip[1]), opacity: f1(fx.click > 0 && fx.click < 0.5 ? 1 : 0) });
        t(fx.n >= 2 ? "double-click" : fx.n >= 1 ? "click" : "aim", 1);
      };
    }
  };

  ANIM["pinch-scroll"] = {
    dur: 6000, stepAt: [0, 1300, 3400],
    keys: [
      [0, { h: h1("point"), fx: { sc: 0, arrow: 0, fling: 0 } }],
      [900, { h: h1("pinch") }],
      [1300, { h: h1("pinch"), fx: { arrow: 1 } }],
      [2600, { h: h1("pinch", { y: 30 }), fx: { sc: 16 } }],
      [3300, { h: h1("pinch", { y: 6 }), fx: { sc: 4 } }],
      [3700, { h: h1("pinch", { y: 28 }), fx: { sc: 14, arrow: 0, fling: 1 } }],
      [3800, { h: h1("point", { y: 30 }) }],
      [4900, { h: h1("point", { y: 14 }), fx: { sc: 40, fling: 0 } }],
      [5600, { h: h1("point") }],
      [6000, { fx: { sc: 40 } }]
    ],
    scene: function (g) {
      var c = screen(g);
      mk("rect", { x: 6, y: 5, width: 66, height: 42, rx: 2, "class": "gwg-win" }, c);
      var page = mk("g", {}, c);
      for (var i = 0; i < 16; i++) {
        mk("rect", { x: 11, y: -40 + i * 7, width: 30 + (i * 13) % 26, height: 2, rx: 1, "class": "gwg-text" }, page);
      }
      var ar = arrow(g, "M92 22 V58", "translate(92 58) rotate(90)");
      var t = label(g, 153, 84);
      return function (fx) {
        set(page, { transform: "translate(0 " + f1(fx.sc % 56) + ")" });
        ar(fx.arrow);
        t(fx.fling > 0.3 ? "let go: it flings on" : fx.arrow > 0.5 ? "page follows your hand" : "pinch and hold", 1);
      };
    }
  };

  ANIM["rest"] = {
    dur: 5000, stepAt: [0, 1200],
    keys: [
      [0, { h: h1("point"), fx: { a: 0 } }],
      [800, { h: h1("open") }],
      [1200, { fx: { a: 1 } }],
      [2000, { h: h1("open", { x: 14, y: 4 }) }],
      [2800, { h: h1("fist", { x: 14, y: 4 }) }],
      [3600, { h: h1("fist", { x: -4, y: 12 }) }],
      [4400, { h: h1("open") }],
      [5000, { h: h1("point"), fx: { a: 0 } }]
    ],
    scene: function (g) {
      var c = screen(g), cur = cursor(c);
      var pause = mk("g", { "class": "gwg-pause" }, c);
      mk("rect", { x: 47, y: 18, width: 2.4, height: 9, rx: 1 }, pause);
      mk("rect", { x: 52, y: 18, width: 2.4, height: 9, rx: 1 }, pause);
      var t = label(g, 153, 84);
      return function (fx) { cur(36, 24); set(pause, { opacity: f1(fx.a) }); t(fx.a > 0.5 ? "pointer stays put" : "pointing", 1); };
    }
  };

  ANIM["ok-mirror"] = {
    dur: 6800, stepAt: [0, 900, 1900], still: [null, null, 2700],
    keys: [
      [0, { h: h1("open"), fx: { hold: 0, done: 0, m: 1 } }],
      [700, { h: h1("ok") }],
      [900, { fx: { hold: 0 } }],
      [1700, { fx: { hold: 1, done: 0 } }],
      [1701, { fx: { done: 0.01 } }],
      [2200, { fx: { m: 0, done: 1 } }],
      [2900, { h: h1("open"), fx: { hold: 0, done: 0 } }],
      [3600, { h: h1("ok") }],
      [3700, { fx: { hold: 0 } }],
      [4500, { fx: { hold: 1, done: 0 } }],
      [4501, { fx: { done: 0.01 } }],
      [5000, { fx: { m: 1, done: 1 } }],
      [6000, { h: h1("open"), fx: { hold: 0, done: 0 } }],
      [6800, {}]
    ],
    scene: function (g) {
      var c = screen(g);
      var mirror = mk("g", {}, c);
      var m = mk("rect", { x: 25, y: 0, width: 28, height: 18, rx: 3, "class": "gwg-mirror" }, mirror);
      var dot = mk("g", { "class": "gwg-mirror-hand" }, mirror);
      [[34, 9], [37, 6.5], [40, 6], [43, 6.5], [46, 8.5]].forEach(function (p) { mk("circle", { cx: p[0], cy: p[1], r: 0.9 }, dot); });
      var ring = holdRing(g, 800, 153, 96);
      var t = label(g, 153, 78);
      return function (fx) {
        set(mirror, { transform: "translate(0 " + f1(-18 * (1 - fx.m)) + ")", opacity: f1(0.2 + 0.8 * fx.m) });
        ring(fx.hold, fx.done);
        t(fx.m > 0.5 ? "mirror shown" : "mirror hidden", 1);
      };
    }
  };

  function windowsScene(c) {
    var w = [];
    [[8, 6, 34, 22], [30, 14, 40, 26], [14, 22, 30, 20], [44, 4, 28, 18]].forEach(function (p) {
      var g = mk("g", {}, c);
      var r = mk("rect", { width: 10, height: 10, rx: 2, "class": "gwg-win" }, g);
      var b = mk("rect", { width: 10, height: 3, rx: 1.2, "class": "gwg-term-bar" }, g);
      w.push({ from: p, r: r, b: b });
    });
    var to = [[1.5, 1.5, 36, 22], [40.5, 1.5, 36, 22], [1.5, 26.5, 36, 22], [40.5, 26.5, 36, 22]];
    return function (k) {
      w.forEach(function (o, i) {
        var a = o.from, b = to[i], p = [0, 1, 2, 3].map(function (j) { return lerp(a[j], b[j], k); });
        set(o.r, { x: f1(p[0]), y: f1(p[1]), width: f1(p[2]), height: f1(p[3]) });
        set(o.b, { x: f1(p[0]), y: f1(p[1]), width: f1(p[2]) });
      });
    };
  }

  ANIM["four-quadrants"] = {
    dur: 5600, stepAt: [0, 900, 1900],
    keys: [
      [0, { h: h1("point"), fx: { hold: 0, done: 0, k: 0 } }],
      [700, { h: h1("four") }],
      [900, { fx: { hold: 0 } }],
      [1700, { fx: { hold: 1, done: 0 } }],
      [1701, { fx: { done: 0.01 } }],
      [2900, { fx: { k: 1, done: 1 } }],
      [4600, { h: h1("fist"), fx: { hold: 0, done: 0 } }],
      [5600, { fx: { k: 1 } }]
    ],
    scene: function (g) {
      var c = screen(g), tile = windowsScene(c);
      var nums = mk("g", { "class": "gwg-quad-labels" }, c);
      [[6, 9], [45, 9], [6, 34], [45, 34]].forEach(function (p, i) { mk("text", { x: p[0], y: p[1], "class": "gwg-quad-n" }, nums).textContent = String(i + 1); });
      var ring = holdRing(g, 800, 153, 96), t = label(g, 153, 78);
      return function (fx) {
        tile(fx.k); set(nums, { opacity: f1(clamp(fx.k * 2 - 1, 0, 1)) });
        ring(fx.hold, fx.done); t(fx.k > 0.5 ? "Quadrants" : "Pointer", 1);
      };
    }
  };

  ANIM["open-pointer"] = {
    dur: 5200, stepAt: [0, 900, 1900],
    keys: [
      [0, { h: h1("fist"), fx: { hold: 0, done: 0, k: 1 } }],
      [700, { h: h1("open") }],
      [900, { fx: { hold: 0 } }],
      [1700, { fx: { hold: 1, done: 0 } }],
      [1701, { fx: { done: 0.01 } }],
      [2400, { fx: { k: 0, done: 1 } }],
      [3200, { h: h1("point"), fx: { hold: 0, done: 0 } }],
      [4600, { h: h1("point", { x: 10, y: 3 }) }],
      [5200, { h: h1("fist"), fx: { k: 1 } }]
    ],
    scene: function (g) {
      var c = screen(g), q = quadGrid(c), cur = cursor(c);
      var ring = holdRing(g, 800, 153, 96), t = label(g, 153, 78);
      return function (fx, t0, hand) {
        q.forEach(function (o) { set(o.g, { opacity: f1(fx.k) }); });
        var p = hand.tips[1];
        cur(30 + (p[0] - 40) * 0.5, 20 + (p[1] - 18) * 0.5, 1 - fx.k);
        ring(fx.hold, fx.done); t(fx.k > 0.5 ? "Quadrants" : "Pointer", 1);
      };
    }
  };

  ANIM["quadrant-dictate"] = {
    dur: 9000, stepAt: [0, 2300, 3300, 6200],
    keys: [
      [0, { h: h1("fist"), fx: { q: 0, prog: 0, listen: 0, typed: 0, paste: 0 } }],
      [500, { h: h1("one"), fx: { q: 1 } }],
      [650, { fx: { q: 1 } }],
      [800, { h: h1("two"), fx: { q: 2 } }],
      [950, { fx: { q: 2 } }],
      [1100, { h: h1("three"), fx: { q: 3, prog: 0 } }],
      [1300, { fx: { q: 3, prog: 0.45 } }],
      [1550, { fx: { prog: 1 } }],
      [2300, { fx: { listen: 0 } }],
      [2500, { fx: { listen: 1 } }],
      [5600, { fx: { listen: 1 } }],
      [6000, { h: h1("fist"), fx: { listen: 0 } }],
      [6200, { fx: { paste: 0 } }],
      [6800, { fx: { paste: 1 } }],
      [8400, { fx: { q: 3, prog: 1 } }],
      [8700, { fx: { q: 0, prog: 0, paste: 0 } }],
      [9000, {}]
    ],
    scene: function (g) {
      var c = screen(g), q = quadGrid(c);
      var fill = mk("rect", { rx: 2, "class": "gwg-quad-on" }, c);
      var input = mk("rect", { width: 28, height: 4, rx: 1.5, "class": "gwg-input" }, c);
      var text = mk("rect", { height: 1.4, rx: 0.7, "class": "gwg-text" }, c);
      var wave = mk("g", { "class": "gwg-wave" }, g);
      var bars = [];
      for (var i = 0; i < 7; i++) bars.push(mk("rect", { x: 128 + i * 4, width: 2.2, rx: 1.1 }, wave));
      var ring = holdRing(g, 450, 186, 96);
      var t = label(g, 148, 84);
      return function (fx, ms) {
        var n = Math.round(fx.q);
        q.forEach(function (o, i) { o.r.classList.toggle("on", i + 1 === n); });
        if (n >= 1) {
          var o = q[n - 1];
          set(fill, { x: o.x, y: o.y, width: 37, height: 21.5, opacity: f1(0.25 + 0.5 * fx.prog) });
          set(input, { x: o.x + 4.5, y: o.y + 14.5, opacity: 1 });
          set(text, { x: o.x + 6, y: o.y + 15.8, width: f1(22 * fx.paste), opacity: f1(fx.paste > 0 ? 1 : 0) });
        } else {
          set(fill, { opacity: 0 }); set(input, { opacity: 0 }); set(text, { opacity: 0 });
        }
        bars.forEach(function (b, i) {
          var h = 2 + fx.listen * (3 + 5 * Math.abs(Math.sin(ms / 140 + i * 1.3)));
          set(b, { y: f1(98 - h / 2), height: f1(h) });
        });
        set(wave, { opacity: f1(fx.listen) });
        ring(fx.q === 3 ? fx.prog : 0, 0);
        t(fx.paste > 0.1 ? "pasted in 3" : fx.listen > 0.5 ? "listening in 3" : n === 3 && fx.prog >= 1 ? "3 comes forward" : n ? "passing " + n : "fist rests", 1);
      };
    }
  };

  ANIM["quadrant-rest"] = {
    dur: 4600, stepAt: [0, 1400],
    keys: [
      [0, { h: h1("two"), fx: { q: 2 } }],
      [700, { h: h1("fist"), fx: { q: 0 } }],
      [1400, { h: h1("fist") }],
      [2400, { h: h1("fist", { x: 12, y: 4 }) }],
      [3400, { h: h1("fist", { x: -2, y: 10 }) }],
      [4000, { h: h1("fist") }],
      [4600, { h: h1("two"), fx: { q: 2 } }]
    ],
    scene: function (g) {
      var c = screen(g), q = quadGrid(c), t = label(g, 153, 84);
      return function (fx) {
        var n = Math.round(fx.q);
        q.forEach(function (o, i) { o.r.classList.toggle("on", i + 1 === n); set(o.g, { opacity: f1(n ? 1 : 0.55) }); });
        t(n ? "quadrant " + n : "resting", 1);
      };
    }
  };

  ANIM["swipe-send"] = {
    dur: 5400, stepAt: [0, 1400, 2300],
    keys: [
      [0, { h: h1("fist"), fx: { typed: 1, sent: 0, arrow: 0, key: 0 } }],
      [900, { h: h1("open", { x: 30 }) }],
      [1400, { fx: { arrow: 1 } }],
      [1900, { h: h1("open", { x: -26, r: -8 }), fx: { arrow: 1 } }],
      [2000, { fx: { key: 1 } }],
      [2600, { fx: { sent: 1, typed: 0, arrow: 0 } }],
      [3200, { fx: { key: 0 } }],
      [4200, { h: h1("open", { x: 2 }) }],
      [4800, { h: h1("fist"), fx: { sent: 0, typed: 1 } }],
      [5400, {}]
    ],
    scene: function (g) {
      var c = screen(g), cb = chatBox(c);
      var key = mk("g", { "class": "gwg-key", transform: "translate(153 92)" }, g);
      mk("rect", { x: -11, y: -8, width: 22, height: 16, rx: 3 }, key);
      mk("text", { y: 4.5 }, key).textContent = "\u21b5";
      var ar = arrow(g, "M100 30 H44", "translate(44 30) rotate(180)");
      var t = label(g, 153, 78);
      mk("text", { x: 70, y: 22, "class": "gwg-tiny" }, g).textContent = "your left";
      return function (fx) {
        set(cb.text, { width: f1(40 * fx.typed) });
        set(cb.bubble, { opacity: f1(fx.sent), transform: "translate(0 " + f1(6 * (1 - fx.sent)) + ")" });
        ar(fx.arrow);
        set(key, { opacity: f1(0.35 + 0.65 * fx.key) }); key.classList.toggle("on", fx.key > 0.5);
        t(fx.sent > 0.5 ? "sent" : "dictated, not sent", 1);
      };
    }
  };

  ANIM["pinky-clear"] = {
    dur: 5400, stepAt: [0, 900, 1900],
    keys: [
      [0, { h: h1("fist"), fx: { typed: 1, hold: 0, done: 0 } }],
      [700, { h: h1("pinky") }],
      [900, { fx: { hold: 0 } }],
      [1700, { fx: { hold: 1, done: 0 } }],
      [1701, { fx: { done: 0.01 } }],
      [2600, { fx: { typed: 0, done: 1 } }],
      [3400, { h: h1("fist"), fx: { hold: 0, done: 0 } }],
      [4600, { fx: { typed: 0 } }],
      [5200, { fx: { typed: 1 } }],
      [5400, {}]
    ],
    scene: function (g) {
      var c = screen(g), cb = chatBox(c);
      var caret = mk("rect", { y: 37.6, width: 0.8, height: 3.8, "class": "gwg-caret" }, c);
      set(cb.bubble, { opacity: 0 });
      var ring = holdRing(g, 800, 153, 96), t = label(g, 153, 78);
      return function (fx, ms) {
        set(cb.text, { width: f1(40 * fx.typed) });
        set(caret, { x: f1(10.5 + 40 * fx.typed), opacity: Math.floor(ms / 450) % 2 ? 0.2 : 1 });
        ring(fx.hold, fx.done); t(fx.typed < 0.1 ? "cleared" : "just dictated", 1);
      };
    }
  };

  // Two-hand stage positions: the right hand as drawn, the left hand mirrored.
  function L(name, extra) { var o = { x: -10, y: 26, s: 0.78 }; for (var k in extra || {}) o[k] = extra[k]; return pose(name, o); }
  function R(name, extra) { var o = { x: 40, y: 26, s: 0.78 }; for (var k in extra || {}) o[k] = extra[k]; return pose(name, o); }

  ANIM["lock"] = {
    dur: 5400, hands: 2, stepAt: [0, 1000, 2000],
    keys: [
      [0, { h2: L("open", { x: -16, r: -6 }), h: R("open", { x: 46, r: 6 }), fx: { hold: 0, done: 0, lock: 0 } }],
      [900, { h2: L("pray", { x: 4, r: 10 }), h: R("pray", { x: 26, r: -10 }) }],
      [1000, { fx: { hold: 0 } }],
      [1800, { fx: { hold: 1, done: 0 } }],
      [1801, { fx: { done: 0.01 } }],
      [2400, { fx: { lock: 1, done: 1 } }],
      [3800, { fx: { hold: 1 } }],
      [4600, { h2: L("open", { x: -16, r: -6 }), h: R("open", { x: 46, r: 6 }), fx: { hold: 0, done: 0 } }],
      [5200, { fx: { lock: 0 } }],
      [5400, {}]
    ],
    scene: function (g) {
      var c = screen(g), lk = lockIcon(c, 54, 3.8);
      var ring = holdRing(g, 800, 153, 96), t = label(g, 153, 78);
      return function (fx) { lk(fx.lock); ring(fx.hold, fx.done); t(fx.lock > 0.5 ? "Vision locked" : "Vision unlocked", 1); };
    }
  };

  ANIM["lets-work"] = {
    dur: 6200, hands: 2, stepAt: [0, 1000, 2000],
    keys: [
      [0, { h2: L("fist", { x: -14 }), h: R("fist", { x: 44 }), fx: { hold: 0, done: 0, t: 0, arrow: 0 } }],
      [800, { h2: L("lw", { x: -14 }), h: R("lw", { x: 44 }) }],
      [1300, { h2: L("lw", { x: 1, r: 4 }), h: R("lw", { x: 29, r: -4 }), fx: { hold: 0 } }],
      [1550, { fx: { hold: 1 } }],
      [2000, { fx: { arrow: 1 } }],
      [2500, { h2: L("lw", { x: -22, r: -4 }), h: R("lw", { x: 52, r: 4 }), fx: { arrow: 1, done: 0.01 } }],
      [3400, { fx: { t: 1, arrow: 0, done: 1 } }],
      [4600, { h2: L("fist", { x: -14 }), h: R("fist", { x: 44 }), fx: { hold: 0, done: 0 } }],
      [5600, { fx: { t: 1 } }],
      [6200, { fx: { t: 0 } }]
    ],
    scene: function (g) {
      var c = screen(g), terms = terminals(c);
      var ar = arrow(g, "M50 116 H14", "translate(14 116) rotate(180)");
      var ar2 = arrow(g, "M58 116 H96", "translate(96 116)");
      var ring = holdRing(g, 200, 153, 96), t = label(g, 153, 78);
      return function (fx) {
        terms.forEach(function (o, i) { placeTerm(o, clamp(fx.t * 4 - i * 0.9, 0, 1)); });
        ar(fx.arrow); ar2(fx.arrow); ring(fx.hold, fx.done);
        t(fx.t > 0.5 ? "4 terminals open" : "thumbs touch", 1);
      };
    }
  };

  ANIM["lock-up"] = {
    dur: 6000, hands: 2, stepAt: [0, 1500, 2300],
    keys: [
      [0, { h2: L("fist", { x: -16 }), h: R("fist", { x: 46 }), fx: { hold: 0, done: 0, gone: 0 } }],
      [700, { h2: L("open", { x: -16 }), h: R("open", { x: 46 }) }],
      [900, { fx: { hold: 0 } }],
      [1200, { fx: { hold: 1 } }],
      [1500, { h2: L("open", { x: -16 }), h: R("open", { x: 46 }) }],
      [1900, { h2: L("fist", { x: -16 }), h: R("fist", { x: 46 }), fx: { done: 0.01 } }],
      [2900, { fx: { gone: 1, done: 1 } }],
      [4600, { fx: { hold: 0, done: 0 } }],
      [5400, { fx: { gone: 1 } }],
      [6000, { fx: { gone: 0 } }]
    ],
    scene: function (g) {
      var c = screen(g), terms = terminals(c);
      terms[1].dot.classList.add("busy");
      var ring = holdRing(g, 300, 153, 96), t = label(g, 153, 78);
      return function (fx) {
        terms.forEach(function (o, i) { placeTerm(o, i === 1 ? 1 : 1 - clamp(fx.gone * 3 - i * 0.5, 0, 1)); });
        ring(fx.hold, fx.done); t(fx.gone > 0.5 ? "idle ones closed" : "open hands", 1);
      };
    }
  };

  ANIM["clear-out"] = {
    dur: 6400, hands: 2, stepAt: [0, 1500, 2700],
    keys: [
      [0, { h2: L("fist", { x: -16 }), h: R("fist", { x: 46 }), fx: { hold: 0, done: 0, gone: 0 } }],
      [700, { h2: L("open", { x: -16 }), h: R("open", { x: 46 }) }],
      [1500, { h2: L("open", { x: -16 }), h: R("open", { x: 46 }) }],
      [1900, { h2: L("open", { x: -16 }), h: R("fist", { x: 46 }), fx: { hold: 0 } }],
      [2400, { fx: { hold: 1 } }],
      [2401, { fx: { done: 0.01 } }],
      [3300, { fx: { gone: 1, done: 1 } }],
      [4800, { h2: L("fist", { x: -16 }), fx: { hold: 0, done: 0 } }],
      [5800, { fx: { gone: 1 } }],
      [6400, { fx: { gone: 0 } }]
    ],
    scene: function (g) {
      var c = screen(g), terms = terminals(c);
      [0, 3].forEach(function (i) {
        mk("rect", { x: 2.5, y: 12, width: 18, height: 1.6, rx: 0.8, "class": "gwg-text" }, terms[i].g);
      });
      var ring = holdRing(g, 500, 153, 96), t = label(g, 153, 78);
      return function (fx) {
        terms.forEach(function (o, i) { placeTerm(o, (i === 0 || i === 3) ? 1 : 1 - clamp(fx.gone * 2 - (i === 2 ? 0.5 : 0), 0, 1)); });
        ring(fx.hold, fx.done); t(fx.gone > 0.5 ? "unused ones closed" : "one fist, one open", 1);
      };
    }
  };

  ANIM["scan-hold"] = {
    dur: 5600, stepAt: [0, 1300, 2600],
    keys: [
      [0, { h: h1("open", { y: 34 }), fx: { trace: 0, docY: 120, read: 0 } }],
      [1100, { h: h1("open", { y: 14 }), fx: { docY: 50 } }],
      [1300, { fx: { trace: 0 } }],
      [2400, { fx: { trace: 1 } }],
      [2600, { fx: { read: 0 } }],
      [3300, { fx: { read: 1 } }],
      [4600, { fx: { read: 1, trace: 1 } }],
      [5300, { h: h1("open", { y: 34 }), fx: { trace: 0, docY: 120, read: 0 } }],
      [5600, {}]
    ],
    scene: function (g) {
      var c = screen(g);
      var mirror = mk("rect", { x: 22, y: 0, width: 34, height: 22, rx: 3, "class": "gwg-mirror" }, c);
      var mini = mk("rect", { x: 30, y: 6, width: 18, height: 11, rx: 1, "class": "gwg-doc-card" }, c);
      var card = scanCard(c);
      var doc = docCard(g);
      var ring = holdRing(g, 1100, 186, 96), t = label(g, 150, 84);
      return function (fx) {
        doc(56, fx.docY, fx.trace, 1);
        set(mini, { opacity: f1(fx.docY < 80 ? 1 - fx.read : 0) });
        set(card, { opacity: f1(fx.read) });
        ring(fx.trace, 0);
        t(fx.read > 0.5 ? "read on this Mac" : fx.trace > 0 ? "hold still" : "hold it up", 1);
      };
    }
  };

  function scanOutcome(handPose, hold, kind) {
    return {
      dur: 5200, stepAt: [0, 900, 2100],
      keys: [
        [0, { h: h1("open"), fx: { hold: 0, done: 0, out: 0 } }],
        [700, { h: h1(handPose) }],
        [900, { fx: { hold: 0 } }],
        [900 + hold, { fx: { hold: 1, done: 0 } }],
        [901 + hold, { fx: { done: 0.01 } }],
        [1800 + hold, { fx: { out: 1, done: 1 } }],
        [3800, { fx: { hold: 1 } }],
        [4400, { h: h1("open"), fx: { hold: 0, done: 0 } }],
        [4900, { fx: { out: 1 } }],
        [5200, { fx: { out: 0 } }]
      ],
      scene: function (g) {
        var c = screen(g), card = scanCard(c);
        var ring = holdRing(g, hold, 153, 96), t = label(g, 153, 78);
        var extra;
        if (kind === "file") {
          extra = mk("g", { "class": "gwg-filed" }, c);
          mk("rect", { x: 14, y: 30, width: 50, height: 9, rx: 2, "class": "gwg-task" }, extra);
          mk("text", { x: 17, y: 36.4, "class": "gwg-mini" }, extra).textContent = "\u2713 Log receipt, 42.10";
        } else if (kind === "copy") {
          extra = mk("g", { "class": "gwg-clip" }, c);
          mk("rect", { x: 58, y: 28, width: 14, height: 17, rx: 2, "class": "gwg-task" }, extra);
          mk("rect", { x: 61.5, y: 26, width: 7, height: 4, rx: 1.2, "class": "gwg-clip-top" }, extra);
          mk("path", { d: "M61 34 h8 M61 38 h8 M61 42 h5", "class": "gwg-doc-lines" }, extra);
        } else {
          extra = mk("g", {}, c);
        }
        var word = { file: "filed as a task", copy: "copied", discard: "discarded" }[kind];
        return function (fx) {
          if (kind === "file") {
            set(card, { opacity: f1(1 - fx.out), transform: "translate(0 " + f1(-8 * fx.out) + ")" });
            set(extra, { opacity: f1(fx.out), transform: "translate(0 " + f1(10 * (1 - fx.out)) + ")" });
          } else if (kind === "copy") {
            set(card, { opacity: f1(1 - 0.6 * fx.out), transform: "translate(" + f1(-4 * fx.out) + " 0)" });
            set(extra, { opacity: f1(fx.out) });
          } else {
            set(card, { opacity: f1(1 - fx.out), transform: "translate(0 " + f1(16 * fx.out) + ") rotate(" + f1(8 * fx.out) + " 39 25)" });
          }
          ring(fx.hold, fx.done);
          t(fx.out > 0.5 ? word : "scan ready", 1);
        };
      }
    };
  }
  ANIM["scan-file"] = scanOutcome("thumbsUp", 700, "file");
  ANIM["scan-copy"] = scanOutcome("two", 600, "copy");
  ANIM["scan-discard"] = scanOutcome("fist", 600, "discard");

  for (var id in ANIM) prepare(ANIM[id]);

  // ---------- rendering ----------
  var reduceQuery = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
  function reduced() { return !!(reduceQuery && reduceQuery.matches); }

  function byId(id) { for (var i = 0; i < DATA.length; i++) if (DATA[i].id === id) return DATA[i]; return null; }

  function list() {
    return DATA.map(function (g) {
      return { id: g.id, name: g.name, mode: g.mode, does: g.does, how: g.how, holdMs: g.holdMs };
    });
  }

  function el(tag, cls, text, parent) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    if (parent) parent.appendChild(e);
    return e;
  }

  function holdText(ms) { return ms ? "Hold " + (ms / 1000) + " s" : ""; }

  function renderPrivate(box, g) {
    box.classList.add("gwg-private");
    var art = el("div", "gwg-private-art", null, box);
    art.setAttribute("aria-hidden", "true");
    var s = mk("svg", { viewBox: "0 0 200 130", "class": "gwg-stage" });
    art.appendChild(s);
    mk("rect", { x: 40, y: 18, width: 120, height: 94, rx: 12, "class": "gwg-private-card" }, s);
    var lk = lockIcon(s, 100, 54); lk(1);
    s.lastChild.setAttribute("transform", "translate(100 54) scale(3.2)");
    var q = mk("text", { x: 100, y: 96, "class": "gwg-private-q" }, s);
    q.textContent = "only you know it";
    return { play: function () {}, pause: function () {}, step: function () {}, destroy: function () { box.innerHTML = ""; } };
  }

  function render(host, id, opts) {
    opts = opts || {};
    var g = byId(id);
    if (!host || !g) throw new Error("GoldWareGestures.render: unknown gesture " + id);
    var loop = opts.loop !== false;
    var size = { s: "s", m: "m", l: "l" }[opts.size] || "m";
    if (host.__gwg) host.__gwg.destroy();
    host.innerHTML = "";

    var n = ++uid;
    var box = el("figure", "gwg gwg-" + size, null, host);
    box.setAttribute("data-gesture", id);
    box.setAttribute("role", "group");
    box.setAttribute("aria-labelledby", "gwg-name-" + n);
    box.setAttribute("aria-describedby", "gwg-desc-" + n);

    var stageWrap = el("div", "gwg-stage-wrap", null, box);
    var cap = el("figcaption", "gwg-cap", null, box);
    var head = el("div", "gwg-head", null, cap);
    var name = el("h3", "gwg-name", g.name, head);
    name.id = "gwg-name-" + n;
    el("span", "gwg-mode", g.mode, head);
    if (g.holdMs) el("span", "gwg-holdchip", holdText(g.holdMs), head);
    var desc = el("div", "gwg-desc", null, cap);
    desc.id = "gwg-desc-" + n;
    var how = el("p", "gwg-how", null, desc);
    el("b", null, "How: ", how); how.appendChild(document.createTextNode(g.how));
    var does = el("p", "gwg-does", null, desc);
    el("b", null, "Does: ", does); does.appendChild(document.createTextNode(g.does));

    if (id === "unlock") {
      var priv = renderPrivate(stageWrap, g);
      host.__gwg = priv;
      return priv;
    }

    var anim = ANIM[id];
    var svg = mk("svg", { viewBox: "0 0 200 130", "class": "gwg-stage", role: "img", "aria-label": g.name + ". " + g.how + " " + g.does });
    stageWrap.appendChild(svg);
    var hands = [];
    var world = mk("g", {}, svg);
    if (anim.keys[0][1].h2) hands.push(new Hand(world, true));
    var main = new Hand(world, false);
    hands.push(main);
    var fxg = mk("g", {}, svg);
    var update = anim.scene(fxg);

    var bar = el("div", "gwg-bar", null, box);
    var playBtn = el("button", "gwg-btn gwg-play", null, bar);
    playBtn.type = "button";
    var prev = el("button", "gwg-btn", "\u2039", bar); prev.type = "button"; prev.setAttribute("aria-label", "Previous step");
    var stepText = el("p", "gwg-step", "", bar);
    stepText.setAttribute("aria-live", "polite");
    var next = el("button", "gwg-btn", "\u203a", bar); next.type = "button"; next.setAttribute("aria-label", "Next step");
    var dots = el("div", "gwg-dots", null, bar);
    dots.setAttribute("aria-hidden", "true");
    var dotEls = g.steps.map(function () { return el("i", null, null, dots); });

    var steps = g.steps, at = anim.stepAt;
    var t0 = null, raf = 0, playing = false, visible = true, cur = 0, stepIdx = -1, stopped = false;

    function draw(ms) {
      var s = sample(anim, ms);
      if (s.h2) { hands[0].update(s.h2); main.update(s.h); }
      else main.update(s.h);
      update(s.fx, ms, main);
      var k = 0;
      for (var i = 0; i < at.length; i++) if (ms >= at[i]) k = i;
      if (k !== stepIdx) {
        stepIdx = k;
        stepText.textContent = (playing ? "" : "Step " + (k + 1) + " of " + steps.length + ": ") + steps[k];
        dotEls.forEach(function (d, i) { d.className = i === k ? "on" : ""; });
      }
    }
    // A still for a step: the moment just before the next step starts (the step's result).
    function stillFor(k) {
      if (anim.still && anim.still[k] != null) return anim.still[k];
      return k + 1 < at.length ? at[k + 1] - 60 : Math.round((at[k] + anim.dur) / 2);
    }
    function frame(now) {
      raf = 0;
      if (!playing) return;
      if (t0 == null) t0 = now - cur;
      cur = now - t0;
      if (cur >= anim.dur) {
        if (loop) { t0 += anim.dur * Math.floor(cur / anim.dur); cur = cur % anim.dur; }
        else { cur = anim.dur; draw(stillFor(steps.length - 1)); pause(); return; }
      }
      draw(cur);
      raf = requestAnimationFrame(frame);
    }
    function setPlayLabel() {
      playBtn.innerHTML = playing ? '<i class="gwg-ico-pause"></i>' : '<i class="gwg-ico-play"></i>';
      playBtn.setAttribute("aria-label", (playing ? "Pause" : "Play") + " the " + g.name + " demo");
      box.classList.toggle("gwg-playing", playing);
      stepText.setAttribute("aria-live", playing ? "off" : "polite");
    }
    function play() {
      if (reduced()) return;
      stopped = false;
      if (!loop && cur >= anim.dur) cur = 0;
      playing = true; t0 = null; stepIdx = -1; setPlayLabel();
      if (visible && !raf) raf = requestAnimationFrame(frame);
    }
    function pause() {
      playing = false; setPlayLabel();
      if (raf) cancelAnimationFrame(raf); raf = 0;
      stepIdx = -1;
      var k = 0; for (var i = 0; i < at.length; i++) if (cur >= at[i]) k = i;
      draw(stillFor(k)); cur = stillFor(k);
    }
    function step(k) {
      if (playing) { playing = false; setPlayLabel(); if (raf) cancelAnimationFrame(raf); raf = 0; }
      stopped = true;
      k = (k + steps.length) % steps.length;
      cur = stillFor(k); stepIdx = -1; draw(cur);
    }
    function current() { for (var i = at.length - 1; i >= 0; i--) if (cur >= at[i]) return i; return 0; }

    playBtn.addEventListener("click", function () { playing ? pause() : (stopped = false, play()); });
    prev.addEventListener("click", function () { step(current() - 1); });
    next.addEventListener("click", function () { step(current() + 1); });
    box.tabIndex = 0;
    box.addEventListener("keydown", function (e) {
      if (e.target !== box) return;
      if (e.key === " " || e.key === "Enter") { e.preventDefault(); playing ? pause() : play(); }
      else if (e.key === "ArrowRight") { e.preventDefault(); step(current() + 1); }
      else if (e.key === "ArrowLeft") { e.preventDefault(); step(current() - 1); }
    });

    function applyMotionPref() {
      box.classList.toggle("gwg-reduced", reduced());
      playBtn.hidden = reduced();
      if (reduced()) step(0); else if (!stopped) play();
    }
    var onPref = function () { applyMotionPref(); };
    if (reduceQuery) {
      if (reduceQuery.addEventListener) reduceQuery.addEventListener("change", onPref);
      else if (reduceQuery.addListener) reduceQuery.addListener(onPref);
    }
    // Only animate while on screen.
    var io = null;
    if (window.IntersectionObserver) {
      io = new IntersectionObserver(function (es) {
        visible = es[es.length - 1].isIntersecting;
        if (visible && playing && !raf) { t0 = null; raf = requestAnimationFrame(frame); }
      });
      io.observe(box);
    }
    draw(0);
    setPlayLabel();
    applyMotionPref();

    var ctl = {
      play: play, pause: pause, step: step,
      destroy: function () {
        playing = false; if (raf) cancelAnimationFrame(raf);
        if (io) io.disconnect();
        if (reduceQuery) {
          if (reduceQuery.removeEventListener) reduceQuery.removeEventListener("change", onPref);
          else if (reduceQuery.removeListener) reduceQuery.removeListener(onPref);
        }
        host.innerHTML = ""; host.__gwg = null;
      }
    };
    host.__gwg = ctl;
    return ctl;
  }

  window.GoldWareGestures = { list: list, render: render };
})();
