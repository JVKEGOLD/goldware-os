/* GoldWare OS first-run tour. A guided dialog over the dashboard: seven short chapters, each with
   something to try now and, where the app can tell, a check that ticks itself off.
   Progress is saved by the local server in data/onboarding.json (git-ignored, kept by make update).
   ?tour-demo opens it without saving anything (screenshots, tests); ?tour=<chapter> opens a chapter.
   The unlock gesture is private: it is never shown, named or described here. */
(function () {
  "use strict";

  var DEMO = /[?&]tour-demo\b/.test(location.search);
  var reduced = window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;
  var S = { placed: {}, state: null, perms: null, chapters: [], open: false, idx: 0, poll: null, name: "GoldWare", wake: "Hey GoldWare", local: {} };

  /* helpers (same shape as the dashboard's) */
  function h(tag, attrs) {
    var el = document.createElement(tag);
    if (attrs) for (var k in attrs) {
      if (k === "class") el.className = attrs[k];
      else if (k === "text") el.textContent = attrs[k];
      else if (k.slice(0, 2) === "on") el.addEventListener(k.slice(2), attrs[k]);
      else if (attrs[k] !== false && attrs[k] != null) el.setAttribute(k, attrs[k]);
    }
    for (var i = 2; i < arguments.length; i++) {
      var c = arguments[i];
      if (c == null || c === false) continue;
      el.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    }
    return el;
  }
  function kbd(t) { return h("kbd", { text: t }); }
  function api(path, body) {
    var init = { method: body ? "POST" : "GET", headers: {} };
    if (body) { init.headers["Content-Type"] = "application/json"; init.body = JSON.stringify(body); }
    return fetch(path, init).then(function (r) { return r.json().catch(function () { return {}; }); });
  }
  function save(change) {
    if (DEMO) { merge(change); return Promise.resolve(); }
    return api("/api/onboarding", change).then(function (j) { if (j && j.state) S.state = j.state; }).catch(function () { merge(change); });
  }
  function merge(change) {
    S.state = S.state || { status: "new", chapter: "welcome", seen: [], checks: [] };
    ["status", "chapter"].forEach(function (k) { if (change[k]) S.state[k] = change[k]; });
    ["seen", "checks"].forEach(function (k) { (change[k] || []).forEach(function (x) { if (S.state[k].indexOf(x) < 0) S.state[k].push(x); }); });
  }
  function settings(pane) { return "x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane; }

  /* what the app or this page has seen happen */
  function done(id) {
    if (S.local[id]) return true;
    if (S.state && S.state.checks.indexOf(id) >= 0) return true;
    var m = (S.perms && S.perms.milestones) || [];
    return m.indexOf(id) >= 0;
  }
  function tick(id) {
    if (done(id)) return;
    S.local[id] = true;
    save({ checks: [id] });
    refreshChecks();
  }
  function perm(key) {
    var v = S.perms && S.perms[key];
    if (!v) return { state: "unknown", text: S.perms ? "Not reported yet" : "Open the app to check" };
    if (v === "granted") return { state: "ok", text: "On" };
    if (v === "denied" || v === "not granted" || v === "restricted") return { state: "off", text: "Off" };
    if (v === "iterm closed") return { state: "unknown", text: "Open iTerm to check" };
    if (v === "not asked yet") return { state: "wait", text: "Not asked yet" };
    return { state: "unknown", text: v };
  }

  /* one row that ticks itself off */
  function check(id, label, hint) {
    return h("li", { class: "tour-check", "data-check": id },
      h("span", { class: "tour-tick", "aria-hidden": "true" }),
      h("span", { class: "tour-check-text" }, h("b", { text: label }), hint ? h("small", { text: hint }) : null),
      h("span", { class: "tour-check-state" }));
  }
  function permRow(key, label, why, pane, optional) {
    return h("li", { class: "tour-perm", "data-perm": key },
      h("span", { class: "tour-tick", "aria-hidden": "true" }),
      h("span", { class: "tour-check-text" }, h("b", null, label, optional ? h("em", { class: "tour-opt", text: "optional" }) : null), h("small", { text: why })),
      h("span", { class: "tour-check-state" }),
      pane ? h("a", { class: "btn sm tour-perm-open", href: settings(pane), text: "Open settings", "aria-label": "Open " + label + " settings" }) : null);
  }
  function refreshChecks() {
    if (!S.root) return;
    S.root.querySelectorAll("[data-check]").forEach(function (li) {
      var ok = done(li.getAttribute("data-check"));
      li.classList.toggle("ok", ok);
      li.querySelector(".tour-check-state").textContent = ok ? "Done" : "Not yet";
    });
    S.root.querySelectorAll("[data-perm]").forEach(function (li) {
      var p = perm(li.getAttribute("data-perm"));
      li.className = "tour-perm " + p.state;
      li.querySelector(".tour-check-state").textContent = p.text;
    });
    var note = S.root.querySelector(".tour-perm-note");
    if (note) note.textContent = S.perms ? (S.perms.updated ? "Checked by the app at " + new Date(S.perms.updated).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) + ". This updates by itself." : "") :
      "The app has not reported yet. Open GoldWare OS from Applications and this fills in within half a minute.";
    S.root.querySelectorAll(".tour-step").forEach(function (b, i) {
      var c = CHAPTERS[i], all = c.checks || [], n = all.filter(done).length;
      b.classList.toggle("seen", (S.state && S.state.seen.indexOf(c.id) >= 0) || i < S.idx);
      b.querySelector(".tour-step-n").textContent = all.length ? n + "/" + all.length : "";
    });
  }

  /* the chapters */
  var CHAPTERS = [
    { id: "welcome", title: "Welcome", body: welcome },
    { id: "permissions", title: "Permissions", body: permissions },
    { id: "voice", title: "Voice", body: voice, checks: ["dictated", "assistant", "wake"] },
    { id: "vision", title: "Vision Mode", body: vision, checks: ["vision-on", "vision-unlocked", "quadrants", "scan-filed", "lets-work", "lock-up", "clear-out"] },
    { id: "office", title: "The Office", body: office, checks: ["office-visited"] },
    { id: "reshape", title: "Make it yours", body: reshape, checks: ["prompt-copied"] },
    { id: "help", title: "Getting help", body: help }
  ];

  function lede(t) { return h("p", { class: "tour-lede", text: t }); }
  function tryNow() {
    var box = h("div", { class: "tour-try" }, h("span", { class: "tag", text: "Try it now" }));
    for (var i = 0; i < arguments.length; i++) box.appendChild(arguments[i]);
    return box;
  }
  function checks() {
    var ul = h("ul", { class: "tour-checks", "aria-label": "Progress" });
    for (var i = 0; i < arguments.length; i++) ul.appendChild(arguments[i]);
    return ul;
  }

  function welcome() {
    return [
      lede(S.name + " runs on this Mac: voice, vision, your agents, and a dashboard you reshape with your own AI."),
      h("div", { class: "tour-promise" },
        h("div", null, h("b", { text: "Your words stay here." }), h("span", { text: "Speech is turned into text by a model on this Mac, and cleaned up by a local model in Ollama." })),
        h("div", null, h("b", { text: "Your camera stays here." }), h("span", { text: "Frames are read for hands and pages in memory, then dropped. Nothing is recorded." })),
        h("div", null, h("b", { text: "Your data stays here." }), h("span", { text: "Tasks, notes and history live in files on this Mac, out of Git." }))),
      h("p", { class: "tour-note", text: "Two things ever reach the internet: the Hermes agents you start (they talk to the Claude or ChatGPT plan you signed in with), and Regroup with AI on a whiteboard, only when you press it." }),
      h("p", { class: "tour-note" }, "This takes about five minutes. Each chapter has one thing to try. Use ", kbd("\u2190"), " and ", kbd("\u2192"), " to move, ", kbd("Esc"), " to close. Replay it any time from the Welcome card or the ", h("b", { text: "Tour" }), " button at the top.")
    ];
  }

  function permissions() {
    return [
      lede("macOS asks before an app can hear, see or act. " + S.name + " asks for each the first time a feature needs it. Here is why, and whether each is on."),
      h("ul", { class: "tour-checks tour-perms", "aria-label": "Permissions" },
        permRow("microphone", "Microphone", "Hears you only while you hold a talk key or after the wake phrase.", "Microphone"),
        permRow("accessibility", "Accessibility", "The right-hand talk keys, pasting what you said, and moving the pointer in Vision Mode.", "Accessibility"),
        permRow("speech", "Speech Recognition", "Only for the wake phrase. Apple's recognizer listens for those words on this Mac.", "SpeechRecognition", true),
        permRow("camera", "Camera", "Vision Mode, the hand mirror and scanning. The green light is on only while one of those is.", "Camera"),
        permRow("automation", "Automation (iTerm)", "Let's work, Lock up, Clear out and the Office type into and close your terminals. macOS asks the first time you use one.", "Automation"),
        permRow("calendar", "Calendar", "The Today tab in the menu bar control center. Read only.", "Calendars", true)),
      h("p", { class: "tour-note tour-perm-note", "aria-live": "polite" }),
      tryNow(h("p", null, "Anything marked Off: press ", h("b", { text: "Open settings" }), ", find GoldWare OS in the list and switch it on. If it is already listed but not working, remove it with the minus button and add it again."))
    ];
  }

  function voice() {
    var area = h("textarea", { class: "notes tour-dictate", rows: "3", placeholder: "Click here, hold Right Option, say a sentence, let go.", "aria-label": "Practice dictation box" });
    area.addEventListener("input", function () { if (area.value.trim().split(/\s+/).length >= 2) tick("dictated"); });
    return [
      lede("Two keys to the right of the space bar. Hold one, talk, let go."),
      h("div", { class: "tour-keys" },
        h("div", null, kbd("Right Option"), h("b", { text: "Dictate" }), h("span", { text: "Types what you say into whatever app is in front, cleaned up: no ums, and your own corrections applied." })),
        h("div", null, kbd("Right Command"), h("b", { text: "Ask " + S.name }), h("span", { text: "Files what you say as a task or note. It never sends a message or finishes a task for you." })),
        h("div", null, h("span", { class: "tour-say", text: "\u201c" + S.wake + "\u201d" }), h("b", { text: "Wake phrase" }), h("span", { text: "Off until you turn it on in the menu bar. Then say it and your request, hands free." }))),
      tryNow(h("p", null, "Click the box, hold ", kbd("Right Option"), ", say ", h("i", { text: "\u201cThis is my first dictation.\u201d" }), " and let go."), area,
        h("p", null, "Then hold ", kbd("Right Command"), " and say ", h("i", { text: "\u201cRemind me tomorrow to try Vision Mode.\u201d" }), " It lands in the Tasks card.")),
      checks(check("dictated", "Dictate something", "Right Option, anywhere"), check("assistant", "Ask for a task or note", "Right Command"), check("wake", "Use the wake phrase", "Optional")),
      h("p", { class: "tour-note" }, "Double tap a key to keep listening without holding it. ", kbd("Esc"), " throws a recording away. Every step of a dictation is listed on the Voice tab.")
    ];
  }

  /* Gestures come from the gesture library (GoldWareGestures), which draws each one with its own
     caption. Each lands in the first section that takes it; whatever no section takes goes in "More
     gestures", so a new gesture is never left out. The unlock gesture is private: the library's entry
     for it is skipped and this tour shows only its own placeholder. */
  function text(g) { return (g.id + " " + g.name + " " + g.mode).toLowerCase(); }
  function isUnlock(g) { return /unlock|passcode/.test(g.id + " " + g.name.toLowerCase()) || /^locked$/i.test(g.mode); }
  var IS = {
    lock: function (g) { return /(^|[^-])lock\b|pray/.test(text(g)) && !/lock.?up/.test(text(g)); },
    work: function (g) { return /lets.?work|lock.?up|clear.?out|two.?hand/.test(text(g)); },
    send: function (g) { return /send|swipe|pinky|clear the paste/.test(text(g)) && !IS.work(g); },
    quadrants: function (g) { return /quadrant|four/.test(text(g)) && !IS.send(g); },
    pointer: function (g) { return /pointer|any style|ok-mirror/.test(text(g)) && !IS.work(g) && !IS.send(g) && !IS.quadrants(g); },
    office: function (g) { return /office/.test(text(g)); },
    scan: function (g) { return /scan|mirror/.test(text(g)); }
  };
  function gestureGrid(take, first) {
    var G = window.GoldWareGestures, grid = h("div", { class: "tour-gestures" });
    if (first) grid.appendChild(first);
    var list = G && G.list ? G.list() : [];
    list.filter(function (g) { return !isUnlock(g) && !S.placed[g.id] && take(g); }).forEach(function (g) {
      S.placed[g.id] = true;
      var cell = h("div", { class: "tour-g", "data-gesture": g.id });
      grid.appendChild(cell);
      try { G.render(cell, g.id, { loop: true, size: "m" }); }
      catch (e) { cell.appendChild(h("p", { class: "muted" }, h("b", { text: g.name }), " ", g.how)); }
    });
    return grid;
  }
  function unlockCard() {
    return h("figure", { class: "tour-g tour-unlock", "data-gesture": "unlock-placeholder", role: "group", "aria-label": "Your unlock gesture" },
      h("div", { class: "tour-lockface", "aria-hidden": "true" }, h("span", { text: "\uD83D\uDD12" })),
      h("figcaption", null, h("b", { text: "Your unlock gesture" }), h("span", { text: "Set or use your unlock gesture." }),
        h("small", { text: "It is private, like a passcode, so this tour never shows it. Nothing moves until you give it." })));
  }
  function vision() {
    S.placed = {};
    var lock = gestureGrid(IS.lock, unlockCard()), work = gestureGrid(IS.work), send = gestureGrid(IS.send),
      quads = gestureGrid(IS.quadrants), pointer = gestureGrid(IS.pointer), office = gestureGrid(IS.office),
      scan = gestureGrid(IS.scan), more = gestureGrid(function () { return true; });
    return [
      lede("Vision Mode turns the camera above the screen into a hands-free pointer, a dictation picker and a scanner. Frames are read in memory and dropped."),
      h("h3", { class: "tour-h3", text: "Turn it on, then unlock" }),
      h("p", null, "Press ", kbd("\u2318"), " ", kbd("\u2325"), " together and let go. It always starts locked, so a stray hand never acts. Praying hands, held, lock it again."),
      lock,
      h("h3", { class: "tour-h3", text: "The pointer" }),
      h("p", { text: "Unlocked, your hand is the mouse." }),
      pointer,
      h("h3", { class: "tour-h3", text: "Quadrants" }),
      h("p", { text: "Four fingers, held, switch to Quadrants: your four most recent windows snap into the corners, and fingers pick which one you talk into." }),
      quads,
      h("h3", { class: "tour-h3", text: "Send or take back what you dictated" }),
      send,
      office.childNodes.length ? h("h3", { class: "tour-h3", text: "Office Voice" }) : null,
      office.childNodes.length ? office : null,
      h("h3", { class: "tour-h3", text: "Scan a document" }),
      h("p", { text: "No unlock needed. Rest the pointer behind the camera notch to open the mirror, then hold a page still." }),
      scan,
      h("h3", { class: "tour-h3", text: "The work commands" }),
      h("p", null, "Each one is a two-hand gesture, a phrase you say with ", kbd("Right Command"), " held, or a button."),
      work,
      h("div", { class: "row tour-work" },
        h("a", { class: "shortcut-inline", href: "goldwareos://lets-work", text: "Let\u2019s work" }),
        h("a", { class: "shortcut-inline", href: "goldwareos://lock-up", text: "Lock up" }),
        h("a", { class: "shortcut-inline", href: "goldwareos://clear-out", text: "Clear out" })),
      more.childNodes.length ? h("h3", { class: "tour-h3 tour-more", text: "More gestures" }) : null,
      more.childNodes.length ? more : null,
      tryNow(h("p", null, "Press ", kbd("\u2318"), " ", kbd("\u2325"), ", set or use your unlock gesture, and point at this window. Then hold ", kbd("Right Command"), " and say ", h("i", { text: "\u201cLet\u2019s work\u201d" }), ".")),
      checks(check("vision-on", "Turn Vision Mode on"), check("vision-unlocked", "Unlock it"), check("quadrants", "Try Quadrants", "Four fingers, held"),
        check("scan-filed", "File a scan", "Optional"), check("lets-work", "Say \u201cLet\u2019s work\u201d"), check("lock-up", "Lock up", "Optional"), check("clear-out", "Clear out", "Optional")),
      h("p", { class: "tour-note" }, "Every gesture, with what it does, is on the ", h("a", { href: "#vision", "data-tour-go": "vision", text: "Vision tab" }),
        " and in the ", h("a", { href: "/dashboard/gestures.html", target: "_blank", rel: "noopener", text: "gesture gallery" }), ".")
    ];
  }

  function office() {
    return [
      lede("The Office shows every Hermes, Claude Code and Codex running on this Mac as a small character at a desk. You are the boss at the front desk."),
      h("ul", { class: "tour-list" },
        h("li", null, h("b", { text: "Click an agent" }), " to read its terminal and chat, and type to it."),
        h("li", null, h("b", { text: "New agent" }), " opens a terminal running an agent in a folder you choose. The arrow beside it picks the topic and the agent."),
        h("li", null, h("b", { text: "The boss" }), " at the front desk runs the others when you ask: \u201cstart two agents on the site, one for copy and one for the form.\u201d"),
        h("li", null, h("b", { text: "Whiteboards" }), " at each table hold that project's tasks. Click one to zoom in."),
        h("li", null, h("b", { text: "Dismiss" }), " asks an agent if it is done, then closes its terminal. Never while it is working.")),
      tryNow(h("p", null, "Open the Office, then press ", h("b", { text: "New agent" }), ". If nobody is at a desk yet, that is normal: say \u201cLet\u2019s work\u201d to fill the room."),
        h("button", { class: "btn gold", type: "button", text: "Open the Office", onclick: function () { tick("office-visited"); close("open"); location.hash = "office"; } })),
      checks(check("office-visited", "Visit the Office"))
    ];
  }

  var PROMPTS = ["Rename my assistant to Nova and change the wake word to Hey Nova", "Add a card to my dashboard that shows the weather in my city", "Make the accent color teal"];
  function reshape() {
    var box = h("div", { class: "tour-prompts" });
    PROMPTS.forEach(function (p) {
      var t = h("span", { text: p });
      box.appendChild(h("div", { class: "prompt" }, t, h("button", { class: "btn sm", type: "button", text: "Copy", "aria-label": "Copy prompt: " + p, onclick: function () {
        var ok = function () { tick("prompt-copied"); };
        if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(p).then(ok, ok); else ok();
      } })));
    });
    return [
      lede("Everything here is plain settings and open code. Change it by asking your own AI agent, the same way you would ask a person."),
      h("ol", { class: "tour-list" },
        h("li", null, "Open a terminal in your ", h("code", { text: "goldware-os" }), " folder and start your agent (", h("code", { text: "hermes" }), ", ", h("code", { text: "claude" }), " or ", h("code", { text: "codex" }), ")."),
        h("li", null, "Ask for the change. It reads ", h("code", { text: "docs/CUSTOMIZING.md" }), ", which maps every setting."),
        h("li", null, "Your settings live in ", h("code", { text: "goldware.json" }), " and ", h("code", { text: "custom/" }), ". ", h("code", { text: "make update" }), " never touches them.")),
      tryNow(h("p", { text: "Copy a prompt and paste it into your agent." }), box,
        h("p", null, "Or move cards yourself: ", h("button", { class: "btn sm", type: "button", text: "Customize the dashboard", onclick: function () {
          close("open"); location.hash = "dashboard"; setTimeout(function () { var b = document.getElementById("customize-btn"); if (b) b.click(); }, 80);
        } }))),
      checks(check("prompt-copied", "Copy a prompt"))
    ];
  }

  function help() {
    return [
      lede("When something is off, start here."),
      h("dl", { class: "menu tour-help" },
        h("div", null, h("dt", { text: "Check everything" }), h("dd", null, "In Terminal: ", h("code", { text: "cd ~/goldware-os && make doctor" }), ". It checks every piece and prints the fix for anything missing.")),
        h("div", null, h("dt", { text: "A key or gesture does nothing" }), h("dd", { text: "Look at Permissions in this tour first. Vision Mode starts locked: check the gold lock right of the notch." })),
        h("div", null, h("dt", { text: "Ask your agent" }), h("dd", { text: "Paste what went wrong into your AI agent in the goldware-os folder. It can read the code and the docs." })),
        h("div", null, h("dt", { text: "Read the guides" }), h("dd", null, h("a", { href: "/docs/CUSTOMIZING.md", target: "_blank", rel: "noopener", text: "Customizing" }), " \u00b7 ", h("a", { href: "/docs/ARCHITECTURE.md", target: "_blank", rel: "noopener", text: "How it fits together" }), " \u00b7 the Voice and Vision tabs each end with \u201cIf something is off\u201d.")),
        h("div", null, h("dt", { text: "Report a problem" }), h("dd", null, "Open an issue at ", h("a", { href: "https://github.com/JVKEGOLD/goldware-os/issues", target: "_blank", rel: "noopener", text: "github.com/JVKEGOLD/goldware-os" }), ". Include what ", h("code", { text: "make doctor" }), " printed."))),
      h("p", { class: "tour-note" }, "Replay this tour any time: the ", h("b", { text: "Tour" }), " button at the top, or the Welcome card on your dashboard.")
    ];
  }

  /* the dialog */
  function build() {
    if (S.root) return S.root;
    var steps = h("ol", { class: "tour-steps" });
    CHAPTERS.forEach(function (c, i) {
      steps.appendChild(h("li", null, h("button", { class: "tour-step", type: "button", "data-chapter": c.id, onclick: function () { go(i); } },
        h("span", { class: "tour-step-dot", "aria-hidden": "true" }), h("span", { class: "tour-step-title", text: c.title }), h("span", { class: "tour-step-n" }))));
    });
    var root = h("div", { class: "tour-backdrop", id: "tour", hidden: "" },
      h("div", { class: "tour", role: "dialog", "aria-modal": "true", "aria-labelledby": "tour-title" },
        h("nav", { class: "tour-rail", "aria-label": "Tour chapters" }, h("div", { class: "tag", text: "Getting started" }), steps,
          h("div", { class: "tour-bar", role: "progressbar", "aria-label": "Tour progress", "aria-valuemin": "1", "aria-valuemax": String(CHAPTERS.length) }, h("i"))),
        h("section", { class: "tour-main" },
          h("button", { class: "tour-x", type: "button", "aria-label": "Close the tour (you can resume it later)", title: "Close (Esc)", text: "\u00d7", onclick: function () { close("open"); } }),
          h("p", { class: "tour-count", "aria-live": "polite" }),
          h("h2", { class: "display tour-title", id: "tour-title", tabindex: "-1" }),
          h("div", { class: "tour-body" }),
          h("div", { class: "tour-foot" },
            h("button", { class: "link-btn tour-skip", type: "button", text: "Skip the tour", onclick: function () { close("skipped"); } }),
            h("span", { class: "tour-spacer" }),
            h("button", { class: "btn tour-back", type: "button", text: "Back", onclick: function () { go(S.idx - 1); } }),
            h("button", { class: "btn solid tour-next", type: "button", onclick: function () { if (S.idx >= CHAPTERS.length - 1) close("done"); else go(S.idx + 1); } })))));
    root.addEventListener("keydown", onKey);
    root.addEventListener("click", function (e) {
      if (e.target === root) close("open");
      var a = e.target.closest && e.target.closest("[data-tour-go]");
      if (a) { e.preventDefault(); close("open"); location.hash = a.getAttribute("data-tour-go"); }
    });
    document.body.appendChild(root);
    S.root = root;
    return root;
  }

  function go(i) {
    i = Math.max(0, Math.min(CHAPTERS.length - 1, i));
    S.idx = i;
    var c = CHAPTERS[i], r = S.root;
    r.querySelector(".tour-count").textContent = "Chapter " + (i + 1) + " of " + CHAPTERS.length;
    r.querySelector(".tour-title").textContent = c.title;
    var body = r.querySelector(".tour-body");
    body.textContent = "";
    c.body().forEach(function (n) { if (n) body.appendChild(n); });
    body.scrollTop = 0;
    r.querySelectorAll(".tour-step").forEach(function (b, j) {
      if (j === i) b.setAttribute("aria-current", "step"); else b.removeAttribute("aria-current");
    });
    var bar = r.querySelector(".tour-bar");
    bar.setAttribute("aria-valuenow", String(i + 1));
    bar.setAttribute("aria-valuetext", c.title);
    bar.firstChild.style.width = ((i + 1) / CHAPTERS.length * 100) + "%";
    r.querySelector(".tour-back").disabled = i === 0;
    r.querySelector(".tour-next").textContent = i === CHAPTERS.length - 1 ? "Finish" : (i === 0 ? "Start" : "Next");
    r.querySelector(".tour-main").setAttribute("data-chapter", c.id);
    save({ chapter: c.id, seen: [c.id], status: "open" });
    refreshChecks();
    r.querySelector(".tour-title").focus({ preventScroll: true });
  }

  function onKey(e) {
    if (e.key === "Escape") { e.preventDefault(); close("open"); return; }
    var typing = /^(INPUT|TEXTAREA|SELECT)$/.test((e.target && e.target.tagName) || "");
    if (!typing && e.key === "ArrowRight") { e.preventDefault(); go(S.idx + 1); return; }
    if (!typing && e.key === "ArrowLeft") { e.preventDefault(); go(S.idx - 1); return; }
    if (e.key !== "Tab") return;
    var f = Array.prototype.filter.call(S.root.querySelectorAll("button, a[href], textarea, input, [tabindex]:not([tabindex='-1'])"), function (n) { return !n.disabled && n.offsetParent !== null; });
    if (!f.length) return;
    var first = f[0], last = f[f.length - 1];
    if (e.shiftKey && (document.activeElement === first || document.activeElement === S.root.querySelector(".tour-title"))) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  }

  function open(chapter) {
    build();
    var i = CHAPTERS.map(function (c) { return c.id; }).indexOf(chapter);
    if (i < 0) i = S.state && S.state.status === "open" ? Math.max(0, CHAPTERS.map(function (c) { return c.id; }).indexOf(S.state.chapter)) : 0;
    S.returnFocus = document.activeElement;
    S.open = true;
    S.root.hidden = false;
    document.documentElement.classList.add("tour-on");
    go(i);
    clearInterval(S.poll);
    S.poll = setInterval(function () { if (!document.hidden) load(); }, 3000);
  }

  function close(status) {
    if (!S.open) return;
    S.open = false;
    S.root.hidden = true;
    document.documentElement.classList.remove("tour-on");
    clearInterval(S.poll);
    save({ status: status || "open" }).then(renderEntry);
    if (status === "done") toastMsg("Tour finished. Replay it any time from the Tour button.");
    else if (status === "skipped") toastMsg("Tour skipped. It is under the Tour button whenever you want it.");
    if (S.returnFocus && S.returnFocus.focus) S.returnFocus.focus();
  }

  function toastMsg(t) {
    var box = document.getElementById("toasts");
    if (!box) return;
    var el = h("div", { class: "toast", role: "status" }, h("span", { text: t }));
    box.appendChild(el);
    setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, 3600);
  }

  function load() {
    var p = DEMO ? Promise.resolve({ state: S.state || { status: "new", chapter: "welcome", seen: [], checks: [] }, permissions: S.perms })
      : api("/api/onboarding");
    return p.then(function (j) {
      if (j && j.state) S.state = j.state;
      if (j && "permissions" in j) S.perms = j.permissions;
      refreshChecks();
      return j;
    }).catch(function () { return null; });
  }

  /* the ways back in: a Tour button in the top bar and the Welcome card */
  function entryLabel() {
    var st = S.state && S.state.status;
    return st === "open" ? "Resume the tour" : st === "done" || st === "skipped" ? "Replay the tour" : "Take the tour";
  }
  function renderEntry() {
    var b = document.getElementById("tour-btn");
    if (!b) {
      var spacer = document.querySelector(".topbar-spacer");
      if (!spacer) return;
      b = h("button", { class: "btn sm tour-top", id: "tour-btn", type: "button", "aria-haspopup": "dialog", title: "Getting started tour", onclick: function () { open(S.state && S.state.status === "open" ? null : "welcome"); } }, "Tour");
      spacer.textContent = "";
      spacer.appendChild(b);
    }
    document.querySelectorAll(".card.welcome .card-body").forEach(function (body) {
      var row = body.querySelector(".tour-entry");
      if (!row) {
        row = h("div", { class: "row tour-entry" }, h("button", { class: "btn solid", type: "button", onclick: function () { open(S.state && S.state.status === "open" ? null : "welcome"); } }),
          h("span", { class: "muted" }));
        body.insertBefore(row, body.firstChild);
      }
      row.firstChild.textContent = entryLabel();
      var seen = (S.state && S.state.seen.length) || 0;
      row.lastChild.textContent = S.state && S.state.status === "done" ? "You finished the tour." : seen ? seen + " of " + CHAPTERS.length + " chapters seen." : "Five minutes: permissions, voice, Vision, the Office.";
    });
  }

  /* the dashboard redraws its cards, so put the tour row back each time the Welcome card is rebuilt */
  var grid = document.getElementById("grid");
  if (grid && window.MutationObserver) new MutationObserver(function () { if (grid.querySelector(".card.welcome .card-body:not(:has(.tour-entry))")) renderEntry(); }).observe(grid, { childList: true });

  api("/api/config").then(function (j) {
    var c = (j && j.config) || {};
    S.name = c.assistantName || "GoldWare";
    S.wake = c.wakePhrase || ("Hey " + S.name);
  }).catch(function () {}).then(load).then(function () {
    renderEntry();
    var m = location.search.match(/[?&]tour=([a-z-]+)/);
    if (m || DEMO) return open(m ? m[1] : "welcome");
    // Runs once: only a brand new install opens it by itself.
    if (S.state && S.state.status === "new") open("welcome");
  });

  window.GoldWareTour = {
    open: open, close: close, chapters: function () { return CHAPTERS.map(function (c) { return { id: c.id, title: c.title, checks: (c.checks || []).slice() }; }); },
    state: function () { return S.state; }, demo: DEMO, reduced: reduced,
    _setPerms: function (p) { if (DEMO) { S.perms = p; refreshChecks(); } }
  };
})();
