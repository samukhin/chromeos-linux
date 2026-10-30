(function () {
  "use strict";

  // Native chrome-untrusted://terminal in this ChromiumOS snapshot is a
  // 94-byte bootstrap (openVmshellProcess with no UI). The build patches that
  // bootstrap to eval(localStorage.t||""), and session/terminal-inject.pl
  // stores this file there over CDP. So this IS the terminal app: a small
  // VT/xterm-class emulator wired to chrome.terminalPrivate.
  //
  // Supported: 256/truecolor SGR, cursor/erase/insert/delete ops, scroll
  // regions, alt screen (?1049), DECCKM, autowrap, insert mode, tabs, DEC
  // special graphics, DSR/DA replies, bracketed paste, focus events, SGR/X10
  // mouse tracking, scrollback, selection + copy/paste, font zoom.

  var d = document;
  var tp = chrome.terminalPrivate;
  var dec = new TextDecoder("utf-8");

  // The eval stub may run before <body> exists; defer all DOM work.
  function boot() {

  // ---------------------------------------------------------------- theme --
  var FONT_STACK = '"DejaVu Sans Mono","Liberation Mono",Consolas,monospace';
  var DEFAULT_FG = "#d4d4d4";
  var DEFAULT_BG = "#1e1e1e";
  var CURSOR_BG = "#aeafad";
  var SELECTION_BG = "rgba(168,190,255,0.30)";
  var SCROLLBACK_MAX = 5000;
  var BLINK_MS = 530;

  function buildPalette() {
    var p = [
      "#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc",
      "#11a8cd", "#e5e5e5", "#666666", "#f14c4c", "#23d18b", "#f5f543",
      "#3b8eea", "#d670d6", "#29b8db", "#ffffff"
    ];
    var lv = [0, 95, 135, 175, 215, 255];
    for (var r = 0; r < 6; r++)
      for (var g = 0; g < 6; g++)
        for (var b = 0; b < 6; b++)
          p.push("rgb(" + lv[r] + "," + lv[g] + "," + lv[b] + ")");
    for (var i = 0; i < 24; i++) {
      var v = 8 + i * 10;
      p.push("rgb(" + v + "," + v + "," + v + ")");
    }
    return p;
  }
  var PALETTE = buildPalette();

  // ----------------------------------------------------------- cell model --
  // cell: { c: string, f: fg, b: bg, a: attrs }
  //   f/b: -1 = default, 0..255 = palette index, >= 0x1000000 = 0xRRGGBB
  //   a bits: bold, dim, italic, underline, inverse, hidden, strike
  var A_BOLD = 1, A_DIM = 2, A_ITALIC = 4, A_UNDERLINE = 8, A_INVERSE = 16,
      A_HIDDEN = 32, A_STRIKE = 64;

  function blankCell() { return { c: " ", f: -1, b: -1, a: 0 }; }
  function blankRow(cols) {
    var r = new Array(cols);
    for (var i = 0; i < cols; i++) r[i] = blankCell();
    return r;
  }
  function copyRow(row) {
    var r = new Array(row.length);
    for (var i = 0; i < row.length; i++) {
      var c = row[i];
      r[i] = { c: c.c, f: c.f, b: c.b, a: c.a };
    }
    return r;
  }

  var cols = 80, rows = 24;
  var screen = [];
  var scrollback = [];
  var altScreen = false, savedScreen = null;

  var cx = 0, cy = 0;
  var savedCx = 0, savedCy = 0, savedAttr = 0, savedFg = -1, savedBg = -1,
      savedG = [0, 0];
  var wrapPending = false;
  var scrollTop = 0, scrollBottom = rows - 1;
  var tabs = [];
  var lastPrinted = "";
  var cursorAttrs = 0, cursorFg = -1, cursorBg = -1; // current pen

  var modes = {
    decckm: false, decawm: true, insert: false, cursorVisible: true,
    bracketedPaste: false, focusEvents: false,
    mouse: 0,       // 0 off, 1 = ?1000, 2 = ?1002, 3 = ?1003
    mouseSgr: false // ?1006
  };
  var charsets = [0, 0]; // 0 = ascii, 1 = DEC special graphics
  var activeCharset = 0;

  var pid = null;
  var dead = false;
  var viewOffset = 0; // lines scrolled up from the live edge
  var dirty = true;
  var bellUntil = 0;
  var cursorBlinkOn = true;

  // ------------------------------------------------------------- wcwidth ---
  function isCombining(cp) {
    return (
      (cp >= 0x0300 && cp <= 0x036f) || (cp >= 0x0483 && cp <= 0x0489) ||
      (cp >= 0x0591 && cp <= 0x05bd) || (cp >= 0x0610 && cp <= 0x061a) ||
      (cp >= 0x064b && cp <= 0x065f) || cp === 0x0670 ||
      (cp >= 0x0e31 && cp <= 0x0e3a) || (cp >= 0x1ab0 && cp <= 0x1aff) ||
      (cp >= 0x1dc0 && cp <= 0x1dff) || (cp >= 0x20d0 && cp <= 0x20f0) ||
      (cp >= 0xfe00 && cp <= 0xfe0f) || (cp >= 0xfe20 && cp <= 0xfe2f)
    );
  }
  function isWide(cp) {
    return (
      (cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0x303e) ||
      (cp >= 0x3041 && cp <= 0x33ff) || (cp >= 0x3400 && cp <= 0x4dbf) ||
      (cp >= 0x4e00 && cp <= 0x9fff) || (cp >= 0xa000 && cp <= 0xa4cf) ||
      (cp >= 0xa960 && cp <= 0xa97f) || (cp >= 0xac00 && cp <= 0xd7a3) ||
      (cp >= 0xf900 && cp <= 0xfaff) || (cp >= 0xfe10 && cp <= 0xfe19) ||
      (cp >= 0xfe30 && cp <= 0xfe6f) || (cp >= 0xff00 && cp <= 0xff60) ||
      (cp >= 0xffe0 && cp <= 0xffe6) || (cp >= 0x1f300 && cp <= 0x1f64f) ||
      (cp >= 0x1f900 && cp <= 0x1f9ff) || (cp >= 0x20000 && cp <= 0x3fffd)
    );
  }
  function wcwidth(ch) {
    var cp = ch.codePointAt(0);
    if (cp < 0x20 || (cp >= 0x7f && cp < 0xa0)) return 0;
    if (isCombining(cp)) return 0;
    return isWide(cp) ? 2 : 1;
  }

  // DEC special graphics (ESC ( 0): ASCII -> line drawing.
  var GRAPHICS = {
    "`": "◆", a: "▒", b: "␉", c: "␌", d: "␍", e: "␊", f: "°", g: "±",
    h: "␤", i: "␋", j: "┘", k: "┐", l: "┌", m: "└", n: "┼", o: "⎺",
    p: "⎻", q: "─", r: "⎼", s: "⎽", t: "├", u: "┤", v: "┴", w: "┬",
    x: "│", y: "≤", z: "≥", "{": "π", "|": "≠", "}": "£", "~": "·"
  };

  // --------------------------------------------------------------- parser --
  var ST_GROUND = 0, ST_ESC = 1, ST_CSI = 2, ST_OSC = 3, ST_OSC_ESC = 4,
      ST_CHARSET = 5;
  var st = ST_GROUND;
  var csiParams = "", csiInter = "", oscBuf = "";

  function resetTabs() {
    tabs = [];
    for (var i = 8; i < cols; i += 8) tabs[i] = true;
  }
  resetTabs();

  function allocScreen() {
    screen = [];
    for (var i = 0; i < rows; i++) screen.push(blankRow(cols));
  }
  allocScreen();

  function clampCursor() {
    if (cx < 0) cx = 0;
    if (cx > cols - 1) cx = cols - 1;
    if (cy < 0) cy = 0;
    if (cy > rows - 1) cy = rows - 1;
  }

  function lineFeed() {
    wrapPending = false;
    if (cy === scrollBottom) scrollUp(1);
    else if (cy < rows - 1) cy++;
  }

  function scrollUp(n) {
    for (var i = 0; i < n; i++) {
      if (!altScreen && scrollTop === 0) {
        scrollback.push(screen.splice(scrollTop, 1)[0]);
        if (scrollback.length > SCROLLBACK_MAX) scrollback.shift();
        screen.splice(scrollBottom, 0, blankRow(cols));
      } else {
        screen.splice(scrollTop, 1);
        screen.splice(scrollBottom, 0, blankRow(cols));
      }
    }
    if (viewOffset > 0) viewOffset = Math.min(
      viewOffset + n, scrollback.length);
  }

  function scrollDown(n) {
    for (var i = 0; i < n; i++) {
      screen.splice(scrollBottom, 1);
      screen.splice(scrollTop, 0, blankRow(cols));
    }
  }

  function eraseInLine(mode) {
    var row = screen[cy], from = 0, to = cols;
    if (mode === 0) from = cx;
    else if (mode === 1) to = cx + 1;
    for (var i = from; i < to; i++) row[i] = blankCell();
  }

  function eraseInDisplay(mode) {
    var i;
    if (mode === 0) {
      eraseInLine(0);
      for (i = cy + 1; i < rows; i++) screen[i] = blankRow(cols);
    } else if (mode === 1) {
      eraseInLine(1);
      for (i = 0; i < cy; i++) screen[i] = blankRow(cols);
    } else if (mode === 2) {
      for (i = 0; i < rows; i++) screen[i] = blankRow(cols);
    } else if (mode === 3) {
      for (i = 0; i < rows; i++) screen[i] = blankRow(cols);
      scrollback = [];
      viewOffset = 0;
    }
  }

  function saveCursor() {
    savedCx = cx; savedCy = cy;
    savedAttr = cursorAttrs; savedFg = cursorFg; savedBg = cursorBg;
    savedG = charsets.slice();
  }
  function restoreCursor() {
    cx = savedCx; cy = savedCy;
    cursorAttrs = savedAttr; cursorFg = savedFg; cursorBg = savedBg;
    charsets = savedG.slice();
    wrapPending = false;
    clampCursor();
  }

  function fullReset() {
    modes.decckm = false; modes.decawm = true; modes.insert = false;
    modes.cursorVisible = true; modes.bracketedPaste = false;
    modes.focusEvents = false; modes.mouse = 0; modes.mouseSgr = false;
    cursorAttrs = 0; cursorFg = -1; cursorBg = -1;
    charsets = [0, 0]; activeCharset = 0;
    scrollTop = 0; scrollBottom = rows - 1;
    cx = cy = 0; wrapPending = false;
    eraseInDisplay(2);
    scrollback = [];
    viewOffset = 0;
    altScreen = false; savedScreen = null;
    resetTabs();
  }

  function makeCell(ch) {
    return { c: ch, f: cursorFg, b: cursorBg, a: cursorAttrs };
  }

  function doWrap() {
    wrapPending = false;
    cx = 0;
    lineFeed();
  }

  function writeChar(ch) {
    var w = wcwidth(ch);
    if (w === 0) {
      // combining mark: append to previous cell
      var px = cx > 0 ? cx - 1 : 0;
      var prev = screen[cy][px];
      if (prev.c === "" && px > 0) prev = screen[cy][px - 1];
      if (prev.c !== " ") prev.c += ch;
      return;
    }
    if (w === 2 && cx === cols - 1 && modes.decawm) doWrap();
    else if (wrapPending) doWrap();

    if (charsets[activeCharset] === 1 && GRAPHICS[ch]) ch = GRAPHICS[ch];

    if (modes.insert) {
      var row = screen[cy];
      for (var i = cols - 1; i >= cx + w; i--) row[i] = row[i - w] || blankCell();
    }
    screen[cy][cx] = makeCell(ch);
    if (w === 2 && cx + 1 < cols) {
      var sp = makeCell("");
      screen[cy][cx + 1] = sp;
    }
    lastPrinted = ch;
    cx += w;
    if (cx >= cols) {
      cx = cols - 1;
      if (modes.decawm) wrapPending = true;
    }
  }

  // --- CSI parameter helpers ---
  function parseParams() {
    var items = csiParams.length ? csiParams.split(";") : [];
    for (var i = 0; i < items.length; i++) {
      if (items[i].indexOf(":") >= 0) items[i] = items[i].split(":");
      else items[i] = [items[i]];
    }
    return items;
  }
  function param(items, i, def) {
    if (i >= items.length || items[i][0] === "") return def;
    var v = parseInt(items[i][0], 10);
    return isNaN(v) ? def : v;
  }

  function sgr(items) {
    var i = 0;
    function rgb(vals, start) {
      // truecolor: [2, r, g, b] possibly with empty colorspace slot
      var nums = [], j;
      for (j = start; j < vals.length && nums.length < 3; j++) {
        if (vals[j] !== "") nums.push(parseInt(vals[j], 10) & 255);
      }
      while (nums.length < 3) nums.push(0);
      return 0x1000000 | (nums[0] << 16) | (nums[1] << 8) | nums[2];
    }
    if (items.length === 0) items = [["0"]];
    while (i < items.length) {
      var sub = items[i];
      var n = sub[0] === "" ? 0 : parseInt(sub[0], 10) || 0;
      if (n === 0) { cursorAttrs = 0; cursorFg = -1; cursorBg = -1; }
      else if (n === 1) cursorAttrs |= A_BOLD;
      else if (n === 2) cursorAttrs |= A_DIM;
      else if (n === 3) cursorAttrs |= A_ITALIC;
      else if (n === 4) cursorAttrs |= A_UNDERLINE;
      else if (n === 7) cursorAttrs |= A_INVERSE;
      else if (n === 8) cursorAttrs |= A_HIDDEN;
      else if (n === 9) cursorAttrs |= A_STRIKE;
      else if (n === 21 || n === 22) cursorAttrs &= ~(A_BOLD | A_DIM);
      else if (n === 23) cursorAttrs &= ~A_ITALIC;
      else if (n === 24) cursorAttrs &= ~A_UNDERLINE;
      else if (n === 25) cursorAttrs &= ~A_DIM; // no-blink, approximate
      else if (n === 27) cursorAttrs &= ~A_INVERSE;
      else if (n === 28) cursorAttrs &= ~A_HIDDEN;
      else if (n === 29) cursorAttrs &= ~A_STRIKE;
      else if (n >= 30 && n <= 37) cursorFg = n - 30;
      else if (n === 38 || n === 48) {
        var target = n === 38 ? "f" : "b";
        if (sub[1] === "5") {
          var idx = parseInt(sub[2] || "0", 10) & 255;
          if (target === "f") cursorFg = idx; else cursorBg = idx;
          i++;
        } else if (sub[1] === "2") {
          // colon form carries a colorspace slot: 38:2::r:g:b
          var start = sub.length >= 6 && sub[3] === "" ? 3 : 2;
          var v = rgb(sub, start);
          if (target === "f") cursorFg = v; else cursorBg = v;
        }
      }
      else if (n === 39) cursorFg = -1;
      else if (n >= 40 && n <= 47) cursorBg = n - 40;
      else if (n === 49) cursorBg = -1;
      else if (n >= 90 && n <= 97) cursorFg = n - 90 + 8;
      else if (n >= 100 && n <= 107) cursorBg = n - 100 + 8;
      i++;
    }
  }

  function setPrivateMode(items, on) {
    for (var i = 0; i < items.length; i++) {
      var m = param(items, i, 0);
      if (m === 1) modes.decckm = on;
      else if (m === 4) modes.insert = on; // IRM
      else if (m === 7) { modes.decawm = on; if (!on) wrapPending = false; }
      else if (m === 12) { /* cursor blink: always on */ }
      else if (m === 25) modes.cursorVisible = on;
      else if (m === 47 || m === 1047) switchAlt(on, false);
      else if (m === 1049) switchAlt(on, true);
      else if (m === 1000) modes.mouse = on ? 1 : 0;
      else if (m === 1002) modes.mouse = on ? 2 : 0;
      else if (m === 1003) modes.mouse = on ? 3 : 0;
      else if (m === 1004) modes.focusEvents = on;
      else if (m === 1006) modes.mouseSgr = on;
      else if (m === 2004) modes.bracketedPaste = on;
    }
  }

  function switchAlt(on, saveCursor) {
    if (on === altScreen) return;
    if (on) {
      savedScreen = { rows: screen.map(copyRow), cx: cx, cy: cy };
      screen = [];
      for (var i = 0; i < rows; i++) screen.push(blankRow(cols));
      altScreen = true;
      viewOffset = 0;
      if (saveCursor) { cx = 0; cy = 0; }
    } else {
      if (savedScreen) {
        screen = savedScreen.rows;
        cx = savedScreen.cx; cy = savedScreen.cy;
        clampCursor();
      }
      altScreen = false;
      savedScreen = null;
    }
    wrapPending = false;
    dirty = true;
  }

  var csiPrivate = false;

  function csiDispatch(final) {
    var inter = csiInter;
    var isPrivate = csiPrivate;

    switch (final) {
      case "A": cy -= Math.max(1, paramP(0)); clampToRegion(); wrapPending = false; break;
      case "B": case "e": cy += Math.max(1, paramP(0)); clampToRegion(); wrapPending = false; break;
      case "C": case "a": cx += Math.max(1, paramP(0)); clampCursor(); wrapPending = false; break;
      case "D": cx -= Math.max(1, paramP(0)); clampCursor(); wrapPending = false; break;
      case "E": cy += Math.max(1, paramP(0)); cx = 0; clampToRegion(); wrapPending = false; break;
      case "F": cy -= Math.max(1, paramP(0)); cx = 0; clampToRegion(); wrapPending = false; break;
      case "G": case "`": cx = Math.max(0, paramP(0) - 1); clampCursor(); wrapPending = false; break;
      case "d": cy = Math.max(0, paramP(0) - 1); clampToRegion(); wrapPending = false; break;
      case "H": case "f":
        cy = Math.max(0, paramP(0, 1) - 1);
        cx = Math.max(0, paramP(1, 1) - 1);
        clampToRegion(); clampCursor(); wrapPending = false;
        break;
      case "J": eraseInDisplay(paramP(0, 0)); break;
      case "K": eraseInLine(paramP(0, 0)); break;
      case "L": { // insert lines at cursor (within region)
        var nL = Math.max(1, paramP(0));
        if (cy >= scrollTop && cy <= scrollBottom) {
          for (var i = 0; i < nL; i++) {
            screen.splice(scrollBottom, 1);
            screen.splice(cy, 0, blankRow(cols));
          }
        }
        break;
      }
      case "M": { // delete lines at cursor
        var nM = Math.max(1, paramP(0));
        if (cy >= scrollTop && cy <= scrollBottom) {
          for (var j = 0; j < nM; j++) {
            screen.splice(cy, 1);
            screen.splice(scrollBottom, 0, blankRow(cols));
          }
        }
        break;
      }
      case "@": { // insert blank chars
        var nA = Math.max(1, paramP(0));
        var rowA = screen[cy];
        for (var k = cols - 1; k >= cx + nA; k--) rowA[k] = rowA[k - nA];
        for (var k2 = 0; k2 < nA && cx + k2 < cols; k2++) rowA[cx + k2] = blankCell();
        break;
      }
      case "P": { // delete chars
        var nP = Math.max(1, paramP(0));
        var rowP = screen[cy];
        for (var p1 = cx; p1 < cols; p1++) {
          rowP[p1] = (p1 + nP < cols) ? rowP[p1 + nP] : blankCell();
        }
        break;
      }
      case "X": { // erase chars
        var nX = Math.max(1, paramP(0));
        var rowX = screen[cy];
        for (var x1 = cx; x1 < cols && x1 < cx + nX; x1++) rowX[x1] = blankCell();
        break;
      }
      case "S": scrollUp(Math.max(1, paramP(0))); break;
      case "T": scrollDown(Math.max(1, paramP(0))); break;
      case "m": sgr(parseParams()); break;
      case "r":
        if (!isPrivate) {
          scrollTop = Math.max(0, paramP(0, 1) - 1);
          scrollBottom = Math.min(rows - 1, paramP(1, rows) - 1);
          if (scrollTop >= scrollBottom) { scrollTop = 0; scrollBottom = rows - 1; }
          cx = 0; cy = scrollTop; wrapPending = false;
        }
        break;
      case "s": if (!isPrivate) saveCursor(); break;
      case "u": if (!isPrivate) restoreCursor(); break;
      case "h": setPrivateMode(parseParams(), true); break;
      case "l": setPrivateMode(parseParams(), false); break;
      case "g":
        if (paramP(0, 0) === 3) resetTabs();
        else delete tabs[cx];
        break;
      case "p":
        if (inter === "!") fullReset(); // DECSTR soft reset
        break;
      case "n":
        if (isPrivate) break;
        if (paramP(0, 0) === 5) send("\x1b[0n");
        else if (paramP(0, 0) === 6) send("\x1b[" + (cy + 1) + ";" + (cx + 1) + "R");
        break;
      case "c": send("\x1b[?62;22c"); break; // DA
      case "t": break; // window ops: ignore
      case "b": { // REP: repeat last graphic
        var rep = Math.max(1, paramP(0));
        if (lastPrinted) for (var r1 = 0; r1 < rep; r1++) writeChar(lastPrinted);
        break;
      }
      default: break; // unsupported: ignore
    }
  }

  function paramP(i, def) { return param(csiParsed, i, def === undefined ? 1 : def); }
  var csiParsed = [];

  function clampToRegion() {
    if (cy < scrollTop) cy = scrollTop;
    if (cy > scrollBottom) cy = scrollBottom;
    clampCursor();
  }

  function oscDispatch() {
    // OSC 0;title BEL / OSC 2;title
    var m = /^([0-9]+);([\s\S]*)$/.exec(oscBuf);
    if (m && (m[1] === "0" || m[1] === "2")) {
      d.title = m[2] || "Terminal";
    }
  }

  function feed(text) {
    for (var i = 0; i < text.length; i++) {
      var ch = text[i];
      var cc = text.charCodeAt(i);

      if (st === ST_OSC) {
        if (cc === 7) { oscDispatch(); st = ST_GROUND; }
        else if (cc === 0x1b) st = ST_OSC_ESC;
        else if (oscBuf.length < 4096) oscBuf += ch;
        continue;
      }
      if (st === ST_OSC_ESC) {
        st = ST_GROUND;
        if (ch === "\\") oscDispatch();
        continue;
      }
      if (st === ST_CHARSET) { st = ST_GROUND; continue; }

      if (st === ST_GROUND) {
        if (cc === 0x1b) { st = ST_ESC; continue; }
        if (cc === 13) { cx = 0; wrapPending = false; continue; }
        if (cc === 10 || cc === 11 || cc === 12) { lineFeed(); continue; }
        if (cc === 8) {
          if (wrapPending) wrapPending = false;
          else if (cx > 0) cx--;
          continue;
        }
        if (cc === 9) { // HT
          var t = cx + 1;
          while (t < cols && !tabs[t]) t++;
          cx = Math.min(t, cols - 1);
          wrapPending = false;
          continue;
        }
        if (cc === 7) { bellUntil = Date.now() + 90; dirty = true; continue; }
        if (cc === 14) { activeCharset = 1; continue; } // SO
        if (cc === 15) { activeCharset = 0; continue; } // SI
        if (cc < 32 || cc === 0x7f) continue;
        if (cc >= 0xd800 && cc <= 0xdbff && i + 1 < text.length) {
          ch += text[i + 1]; // surrogate pair: keep the full code point
          i++;
        }
        writeChar(ch);
        continue;
      }

      if (st === ST_ESC) {
        st = ST_GROUND;
        if (ch === "[") { st = ST_CSI; csiParams = ""; csiInter = ""; continue; }
        if (ch === "]") { st = ST_OSC; oscBuf = ""; continue; }
        if (ch === "(" || ch === ")" || ch === "*" || ch === "+") {
          st = ST_CHARSET;
          continue;
        }
        if (ch === "7") { saveCursor(); continue; }
        if (ch === "8") { restoreCursor(); continue; }
        if (ch === "D") { lineFeed(); continue; }              // IND
        if (ch === "E") { cx = 0; lineFeed(); continue; }      // NEL
        if (ch === "M") {                                       // RI
          if (cy === scrollTop) scrollDown(1);
          else if (cy > 0) cy--;
          wrapPending = false;
          continue;
        }
        if (ch === "H") { tabs[cx] = true; continue; }         // HTS
        if (ch === "c") { fullReset(); continue; }             // RIS
        if (ch === "Z") { send("\x1b[?62;22c"); continue; }    // DECID
        if (ch === "=" || ch === ">") continue;                // keypad
        if (ch === "\\") continue;                             // ST
        continue;
      }

      if (st === ST_CSI) {
        if ((cc >= 0x30 && cc <= 0x3f)) { csiParams += ch; continue; }
        if (cc >= 0x20 && cc <= 0x2f) { csiInter += ch; continue; }
        if (cc >= 0x40 && cc <= 0x7e) {
          st = ST_GROUND;
          var p0 = csiParams.charAt(0);
          if (p0 === ">" || p0 === "=" || p0 === "<") continue; // e.g. modifyOtherKeys: ignore
          csiPrivate = p0 === "?";
          if (csiPrivate) csiParams = csiParams.slice(1);
          csiParsed = parseParams();
          csiDispatch(ch);
          continue;
        }
        st = ST_GROUND; // invalid: abort
        continue;
      }
    }
  }

  // --------------------------------------------------------------- canvas --
  var canvas = d.createElement("canvas");
  var ctx = canvas.getContext("2d");
  var ta = d.createElement("textarea");
  ta.id = "ta";
  ta.autocapitalize = "off";
  ta.autocomplete = "off";
  ta.spellcheck = false;

  d.head.insertAdjacentHTML("beforeend",
    "<style>" +
    "html,body{margin:0;padding:0;height:100%;background:" + DEFAULT_BG +
    ";overflow:hidden}" +
    "#term{display:block}" +
    "#ta{position:fixed;left:0;top:0;width:1px;height:1px;opacity:0;" +
    "border:0;outline:none;resize:none;background:transparent;color:transparent;" +
    "z-index:-1;}" +
    "canvas{-webkit-user-select:none;user-select:none;cursor:text}" +
    "</style>");
  canvas.id = "term";
  d.body.appendChild(canvas);
  d.body.appendChild(ta);

  var fontSize = parseInt(localStorage.getItem("fs"), 10) || 13;
  if (fontSize < 6) fontSize = 6;
  if (fontSize > 40) fontSize = 40;
  var cellW = 8, cellH = 18, dpr = 1;

  function measure() {
    ctx.font = fontSize + "px " + FONT_STACK;
    cellW = Math.max(4, ctx.measureText("M").width); // fractional: text advances with the same step, so the cursor stays glued to the glyphs
    cellH = Math.max(8, Math.round(fontSize * 1.35));
    dpr = Math.max(1, window.devicePixelRatio || 1);
  }

  function layout() {
    measure();
    var w = Math.max(cellW * 20, window.innerWidth);
    var h = Math.max(cellH * 5, window.innerHeight);
    var newCols = Math.max(20, Math.floor(w / cellW));
    var newRows = Math.max(5, Math.floor(h / cellH));
    canvas.style.width = newCols * cellW + "px";
    canvas.style.height = newRows * cellH + "px";
    canvas.width = Math.round(newCols * cellW * dpr);
    canvas.height = Math.round(newRows * cellH * dpr);
    if (newCols !== cols || newRows !== rows) resizeGrid(newCols, newRows);
    dirty = true;
  }

  function resizeGrid(newCols, newRows) {
    var r, i;
    for (r = 0; r < rows; r++) {
      var row = screen[r];
      if (newCols > cols) {
        for (i = cols; i < newCols; i++) row.push(blankCell());
      } else {
        row.length = newCols;
      }
    }
    if (newRows > rows) {
      for (i = rows; i < newRows; i++) screen.push(blankRow(newCols));
      if (cy > newRows - 1) cy = newRows - 1;
    } else {
      screen.length = newRows;
      if (cy > newRows - 1) cy = newRows - 1;
    }
    for (r = 0; r < scrollback.length; r++) {
      var sr = scrollback[r];
      if (newCols > sr.length) {
        for (i = sr.length; i < newCols; i++) sr.push(blankCell());
      } else {
        sr.length = newCols;
      }
    }
    cols = newCols; rows = newRows;
    scrollTop = 0; scrollBottom = rows - 1;
    wrapPending = false;
    clampCursor();
    if (viewOffset > scrollback.length) viewOffset = scrollback.length;
    if (pid != null) tp.onTerminalResize(pid, cols, rows, function () {});
  }

  // -------------------------------------------------------------- render ---
  function viewStart() {
    var total = altScreen ? rows : scrollback.length + rows;
    var start = total - viewOffset - rows;
    return start < 0 ? 0 : start;
  }

  function rowAt(abs) {
    if (altScreen) return screen[abs] || null;
    if (abs < scrollback.length) return scrollback[abs];
    return screen[abs - scrollback.length] || null;
  }

  function resolve(cell, which) {
    var v = which === "f" ? cell.f : cell.b;
    var other = which === "f" ? cell.b : cell.f;
    if (cell.a & A_INVERSE) {
      v = other;
    }
    if (v === -1) {
      var base = which === "f" ? DEFAULT_FG : DEFAULT_BG;
      if ((cell.a & A_INVERSE) && other === -1) {
        base = which === "f" ? DEFAULT_BG : DEFAULT_FG;
      }
      return base;
    }
    if (v >= 0x1000000) {
      return "#" + (v & 0xffffff).toString(16).padStart(6, "0");
    }
    if (which === "f" && (cell.a & A_BOLD) && v < 8) v += 8;
    return PALETTE[v] || DEFAULT_FG;
  }

  function selRowRange(absRow) {
    if (!hasSel()) return null;
    var r1 = Math.min(sel.ar, sel.br), r2 = Math.max(sel.ar, sel.br);
    if (absRow < r1 || absRow > r2) return null;
    var c1 = sel.ar <= sel.br ? sel.ac : sel.bc;
    var c2 = sel.ar <= sel.br ? sel.bc : sel.ac;
    return { from: absRow === r1 ? c1 : 0, to: absRow === r2 ? c2 : cols - 1 };
  }

  function drawRun(vy, from, to, text, fg, bg, a) {
    var x = from * cellW;
    var w = (to - from + 1) * cellW;
    if (bg) {
      ctx.fillStyle = bg;
      ctx.fillRect(x, vy * cellH, w, cellH);
    }
    if (!(a & A_HIDDEN) && text) {
      ctx.font = ((a & A_ITALIC) ? "italic " : "") +
                 ((a & A_BOLD) ? "bold " : "") +
                 fontSize + "px " + FONT_STACK;
      ctx.fillStyle = fg;
      if (a & A_DIM) ctx.globalAlpha = 0.55;
      ctx.textBaseline = "middle";
      ctx.fillText(text, x, vy * cellH + cellH / 2 + 1);
      ctx.globalAlpha = 1;
    }
    if (a & A_UNDERLINE) {
      ctx.fillStyle = fg;
      ctx.fillRect(x, vy * cellH + cellH - 1.5, w, 1);
    }
    if (a & A_STRIKE) {
      ctx.fillStyle = fg;
      ctx.fillRect(x, vy * cellH + cellH / 2, w, 1);
    }
  }

  function render() {
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = DEFAULT_BG;
    ctx.fillRect(0, 0, cols * cellW, rows * cellH);

    var start = viewStart();
    for (var vy = 0; vy < rows; vy++) {
      var row = rowAt(start + vy);
      if (!row) continue;
      var i = 0;
      while (i < cols) {
        var cell = row[i];
        var fg = resolve(cell, "f");
        var bg = resolve(cell, "b");
        var a = cell.a;
        var from = i;
        var text = "";
        while (i < cols) {
          var c2 = row[i];
          if (resolve(c2, "f") !== fg || resolve(c2, "b") !== bg ||
              c2.a !== a) {
            break;
          }
          text += c2.c; // wide-char spacers carry "" and add nothing
          i++;
        }
        drawRun(vy, from, i - 1, text, fg, bg, a);
      }
      var sr = selRowRange(start + vy);
      if (sr) {
        ctx.fillStyle = SELECTION_BG;
        ctx.fillRect(sr.from * cellW, vy * cellH,
                     (sr.to - sr.from + 1) * cellW, cellH);
      }
    }

    // cursor
    if (modes.cursorVisible && viewOffset === 0) {
      var curY = cy;
      var blinkOk = cursorBlinkOn || !d.hasFocus();
      if (blinkOk) {
        var cc2 = screen[curY] && screen[curY][cx];
        var cfg = cc2 ? resolve(cc2, "f") : DEFAULT_FG;
        var cbg = cc2 ? resolve(cc2, "b") : DEFAULT_BG;
        var chx = cc2 && cc2.c !== "" ? cc2.c : " ";
        var px = cx * cellW, py = curY * cellH;
        ctx.font = fontSize + "px " + FONT_STACK;
        ctx.textBaseline = "middle";
        if (cc2 && cc2.c !== "") {
          ctx.fillStyle = cfg;
          ctx.fillRect(px, py, cellW, cellH);
          ctx.fillStyle = cbg;
          ctx.fillText(chx, px, py + cellH / 2 + 1);
        } else {
          ctx.fillStyle = CURSOR_BG;
          ctx.fillRect(px, py, cellW, cellH);
        }
      }
    }

    if (Date.now() < bellUntil) {
      ctx.fillStyle = "rgba(255,255,255,0.18)";
      ctx.fillRect(0, 0, cols * cellW, rows * cellH);
    }
  }

  function frame() {
    if (dirty) {
      dirty = false;
      render();
    }
    requestAnimationFrame(frame);
  }

  setInterval(function () {
    if (!modes.cursorVisible) return;
    cursorBlinkOn = !cursorBlinkOn;
    dirty = true;
  }, BLINK_MS);

  // ------------------------------------------------------------ selection --
  var sel = { a: null, b: null, ar: 0, ac: 0, br: 0, bc: 0 };
  var selecting = false;

  function hasSel() { return sel.a !== null && sel.b !== null; }

  function cellFromEvent(e) {
    var rect = canvas.getBoundingClientRect();
    var col = Math.floor((e.clientX - rect.left) / cellW);
    var vy = Math.floor((e.clientY - rect.top) / cellH);
    col = Math.max(0, Math.min(cols - 1, col));
    vy = Math.max(0, Math.min(rows - 1, vy));
    return { r: viewStart() + vy, c: col };
  }

  function setSelAnchor(p) {
    sel.a = sel.b = p;
    sel.ar = sel.br = p.r; sel.ac = sel.bc = p.c;
    dirty = true;
  }
  function extendSel(p) {
    sel.b = p;
    sel.br = p.r; sel.bc = p.c;
    dirty = true;
  }

  function selectionText() {
    if (!hasSel()) return "";
    var r1 = Math.min(sel.ar, sel.br), r2 = Math.max(sel.ar, sel.br);
    var c1 = sel.ar <= sel.br ? sel.ac : sel.bc;
    var c2 = sel.ar <= sel.br ? sel.bc : sel.ac;
    var out = [];
    for (var r = r1; r <= r2; r++) {
      var row = rowAt(r);
      var from = r === r1 ? c1 : 0;
      var to = r === r2 ? c2 : cols - 1;
      var s = "";
      if (row) {
        for (var i = Math.max(0, from); i <= Math.min(cols - 1, to); i++) {
          s += row[i].c === "" ? "" : row[i].c;
        }
      }
      out.push(s.replace(/\s+$/, ""));
    }
    return out.join("\n");
  }

  function wordAt(row, col) {
    if (!row) return null;
    function isW(ch) { return ch && /[A-Za-z0-9_./~:@%+=,-]/.test(ch); }
    var s = col, e = col;
    while (s > 0 && isW(row[s - 1].c)) s--;
    while (e < cols - 1 && isW(row[e + 1].c)) e++;
    return { s: s, e: e };
  }

  var clickCount = 0, lastClick = 0, lastBtn = false;

  canvas.addEventListener("mousedown", function (e) {
    ta.focus();
    if (e.button === 0 && modes.mouse > 0) lastBtn = true;
    if (e.button === 0) {
      if (modes.mouse > 0) { sendMouseEvent(e, 0, false); return; }
      e.preventDefault();
      var p = cellFromEvent(e);
      setSelAnchor(p);
      selecting = true;
      clickCount = (Date.now() - lastClick < 400) ? clickCount + 1 : 1;
      lastClick = Date.now();
      if (clickCount >= 2) {
        var w = wordAt(rowAt(p.r), p.c);
        if (w) {
          sel.b = { r: p.r, c: w.e };
          sel.br = p.r; sel.bc = w.e;
          sel.a = { r: p.r, c: w.s };
          sel.ar = p.r; sel.ac = w.s;
          selecting = false;
        }
        if (clickCount >= 3) {
          setSelAnchor({ r: p.r, c: 0 });
          extendSel({ r: p.r, c: cols - 1 });
          selecting = false;
        }
        dirty = true;
      }
    } else if (e.button === 1 && modes.mouse > 0) {
      sendMouseEvent(e, 1, false);
    } else if (e.button === 2 && modes.mouse > 0) {
      sendMouseEvent(e, 2, false);
    }
  });

  d.addEventListener("mousemove", function (e) {
    if (selecting) { extendSel(cellFromEvent(e)); return; }
    if (modes.mouse >= 2 && lastBtn) sendMouseEvent(e, 0, "motion");
  });
  d.addEventListener("mouseup", function (e) {
    if (e.button === 0) {
      if (modes.mouse > 0 && lastBtn) sendMouseEvent(e, 0, "release");
      lastBtn = false;
    } else if (e.button === 1 || e.button === 2) {
      if (modes.mouse > 0) sendMouseEvent(e, e.button, "release");
    }
    selecting = false;
  });
  canvas.addEventListener("contextmenu", function (e) {
    if (modes.mouse > 0) e.preventDefault();
  });

  // ------------------------------------------------------- mouse reports ---
  function mouseMods(e) {
    var m = 0;
    if (e.shiftKey) m |= 4;
    if (e.altKey) m |= 8;
    if (e.ctrlKey) m |= 16;
    return m;
  }

  function sendMouseEvent(e, button, kind) {
    if (modes.mouse === 0) return;
    if (kind === "motion" && modes.mouse < 3 && button === 0) {
      // 1002: motion only while dragging
      if (!lastBtn) return;
    }
    var p = cellFromEvent(e);
    var b = button;
    if (kind === "motion") b = 3 + 32; // motion bit, no button change (X10 style)
    if (kind === "release" && !modes.mouseSgr) b = 3;
    var mods = mouseMods(e);
    var x = p.c + 1, y = (p.r - viewStart()) + 1;
    if (modes.mouseSgr) {
      var btn = button + (kind === "motion" ? 32 : 0) + mods;
      send("\x1b[<" + btn + ";" + x + ";" + y + (kind === "release" ? "m" : "M"));
    } else {
      if (kind === "motion") b = 35; // 3+32
      var code = b + mods;
      x = Math.min(223, x); y = Math.min(223, y);
      send("\x1b[M" + String.fromCharCode(32 + code, 32 + x, 32 + y));
    }
  }

  canvas.addEventListener("wheel", function (e) {
    e.preventDefault();
    if (modes.mouse > 0 && !e.ctrlKey) {
      var up = e.deltaY < 0;
      if (modes.mouseSgr) {
        send("\x1b[<" + (up ? 64 : 65) + ";" + (cellFromEvent(e).c + 1) +
             ";" + ((cellFromEvent(e).r - viewStart()) + 1) + "M");
      } else {
        var p2 = cellFromEvent(e);
        send("\x1b[M" + String.fromCharCode(32 + (up ? 64 : 65),
             32 + Math.min(223, p2.c + 1),
             32 + Math.min(223, p2.r - viewStart() + 1)));
      }
      return;
    }
    var lines = e.deltaMode === 1 ? e.deltaY : Math.round(e.deltaY / cellH);
    viewOffset = Math.max(0, Math.min(scrollback.length, viewOffset + lines));
    dirty = true;
  }, { passive: false });

  // -------------------------------------------------------- copy / paste ---
  function copySel() {
    var t = selectionText();
    if (!t) return;
    ta.focus();
    try {
      d.execCommand("copy");
    } catch (err) { /* ignore */ }
  }

  d.addEventListener("copy", function (e) {
    if (!hasSel()) return;
    var t = selectionText();
    if (!t) return;
    e.preventDefault();
    e.clipboardData.setData("text/plain", t);
  });

  ta.addEventListener("paste", function (e) {
    var t = e.clipboardData && e.clipboardData.getData("text/plain");
    if (!t) return;
    e.preventDefault();
    sendPaste(t);
  });

  function sendPaste(t) {
    t = t.replace(/\r\n/g, "\r").replace(/\n/g, "\r");
    if (modes.bracketedPaste) t = "\x1b[200~" + t + "\x1b[201~";
    send(t);
  }

  // ------------------------------------------------------------- keyboard --
  function send(s) {
    if (pid == null || dead) return;
    tp.sendInput(pid, s, function () {});
  }

  d.addEventListener("keydown", function (e) {
    if (e.isComposing || e.keyCode === 229) return;

    // copy / paste shortcuts (ChromeOS style)
    if (e.ctrlKey && e.shiftKey && !e.altKey &&
        (e.key === "C" || e.key === "c")) {
      e.preventDefault();
      copySel();
      return;
    }
    if (e.ctrlKey && e.shiftKey && !e.altKey &&
        (e.key === "V" || e.key === "v")) {
      // Chrome delivers a paste event for Ctrl+Shift+V; nothing to do here.
      return;
    }
    // font zoom
    if (e.ctrlKey && !e.altKey && !e.shiftKey) {
      if (e.key === "+" || e.key === "=") { zoomFont(1); e.preventDefault(); return; }
      if (e.key === "-") { zoomFont(-1); e.preventDefault(); return; }
      if (e.key === "0") { fontSize = 13; localStorage.setItem("fs", "13"); layout(); e.preventDefault(); return; }
    }

    var seq = null;
    var k = e.key;

    if (k === "Enter") seq = "\r";
    else if (k === "Backspace") seq = (e.ctrlKey || e.altKey) ? "\x1b\x7f" : "\x7f";
    else if (k === "Tab") seq = e.shiftKey ? "\x1b[Z" : "\t";
    else if (k === "Escape") seq = "\x1b";
    else if (k === "ArrowUp") seq = modes.decckm ? "\x1bOA" : "\x1b[A";
    else if (k === "ArrowDown") seq = modes.decckm ? "\x1bOB" : "\x1b[B";
    else if (k === "ArrowRight") seq = modes.decckm ? "\x1bOC" : "\x1b[C";
    else if (k === "ArrowLeft") seq = modes.decckm ? "\x1bOD" : "\x1b[D";
    else if (k === "Home") seq = modes.decckm ? "\x1bOH" : "\x1b[H";
    else if (k === "End") seq = modes.decckm ? "\x1bOF" : "\x1b[F";
    else if (k === "PageUp") seq = "\x1b[5~";
    else if (k === "PageDown") seq = "\x1b[6~";
    else if (k === "Insert") seq = "\x1b[2~";
    else if (k === "Delete") seq = "\x1b[3~";
    else if (k === "F1") seq = "\x1bOP";
    else if (k === "F2") seq = "\x1bOQ";
    else if (k === "F3") seq = "\x1bOR";
    else if (k === "F4") seq = "\x1bOS";
    else if (k === "F5") seq = "\x1b[15~";
    else if (k === "F6") seq = "\x1b[17~";
    else if (k === "F7") seq = "\x1b[18~";
    else if (k === "F8") seq = "\x1b[19~";
    else if (k === "F9") seq = "\x1b[20~";
    else if (k === "F10") seq = "\x1b[21~";
    else if (k === "F11") seq = "\x1b[23~";
    else if (k === "F12") seq = "\x1b[24~";
    else if (k.length === 1) {
      if (e.ctrlKey && e.altKey) {
        seq = k; // AltGr (e.g. @ on some layouts): printable as-is
      } else if (e.ctrlKey) {
        var up = k.toUpperCase().charCodeAt(0);
        if (k === " ") seq = "\x00";
        else if (up >= 64 && up < 96) seq = String.fromCharCode(up - 64);
        else if (k === "[") seq = "\x1b";
        else seq = k;
      } else if (e.altKey) {
        seq = "\x1b" + k;
      } else if (!e.metaKey) {
        seq = k;
      }
    }

    if (seq !== null && pid != null) {
      e.preventDefault();
      send(seq);
      if (viewOffset > 0) { viewOffset = 0; dirty = true; }
    }
  });

  function zoomFont(dir) {
    fontSize = Math.max(6, Math.min(40, fontSize + dir));
    localStorage.setItem("fs", String(fontSize));
    layout();
  }

  // --------------------------------------------------------------- focus ---
  ta.addEventListener("focus", function () {
    if (modes.focusEvents) send("\x1b[I");
    cursorBlinkOn = true;
    dirty = true;
  });
  ta.addEventListener("blur", function () {
    if (modes.focusEvents) send("\x1b[O");
    dirty = true;
  });
  window.addEventListener("resize", layout);

  // -------------------------------------------------------- shell wiring ---
  function printLine(s) {
    feed(s.replace(/\n/g, "\r\n"));
    dirty = true;
  }

  function onProcessOutput(id, type, data) {
    if (id !== pid) return;
    if (type === "exit") {
      dead = true;
      printLine("\r\n[process exited]\r\n");
      return;
    }
    var text;
    if (typeof data === "string") text = data;
    else if (data instanceof ArrayBuffer) text = dec.decode(new Uint8Array(data), { stream: true });
    else if (ArrayBuffer.isView(data)) text = dec.decode(new Uint8Array(data.buffer, data.byteOffset, data.byteLength), { stream: true });
    else text = String(data);
    feed(text);
    if (viewOffset === 0) dirty = true;
    tp.ackOutput(pid);
  }

  // ------------------------------------------------------------------ go ---
  layout();
  ta.focus();
  tp.openVmshellProcess([], function (id) {
    if (id == null) {
      printLine("[failed to start shell]\r\n");
      return;
    }
    pid = id;
    tp.onProcessOutput.addListener(onProcessOutput);
    tp.onTerminalResize(pid, cols, rows, function () {});
    ta.focus();
    dirty = true;
  });

  requestAnimationFrame(frame);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
}());
