/* GoldWare OS Office: the cast. Original pixel-art characters, drawn from the small grids below
   (no image files). Each grid is the LEFT half of the character, mirrored when painted; the last
   column is the middle. Letters: . clear, o outline, b body, h light, s shade, w white, k dark,
   a accent, c second accent, p cheek. Each character has its own palette and signature colour.
   Exposes window.OfficeCast = { names, has(name), color(name), size(name), canvas(name), url(name), customize(looks) }.
   custom/office-cast.js (git-ignored) calls OfficeCast.customize({...}) to restyle characters; the
   GoldWare OS pill reads the same file, so both draw the same look. See docs/CUSTOMIZING.md. */
(() => {
  const CAST = {
    Bolt: { // steel-blue robot with an antenna and a cyan visor
      color: '#6d8fb8',
      pal: { o: '#1c2a3a', b: '#6d8fb8', h: '#9bb8d8', s: '#4b6a90', k: '#10161f', c: '#7fe8f0', a: '#f2c94c', w: '#e8eef5' },
      rows: [
        '........a',
        '........o',
        '..ooooooo',
        '.obhhhhhh',
        '.obbbbbbb',
        '.okkkkkkk',
        'aokkcckkk',
        'aokkcckkk',
        '.okkkkkkk',
        '.obbbbbbb',
        '..oosssss',
        '...obbbbb',
        '..oobhhhh',
        '.obbbwwbb',
        '.obbbwwbb',
        '.obbbbbbb',
        '..ossssss',
        '...ookkoo',
        '...ookkoo',
        '..oooo...'
      ]
    },
    Mocha: { // brown bear with a cream muzzle and round ears
      color: '#a8714a',
      pal: { o: '#3a2416', b: '#a8714a', h: '#c99366', s: '#7d5233', k: '#17100b', w: '#f3e6cf', p: '#e8957f', a: '#d9a441' },
      rows: [
        '.ooo.....',
        'obbbo....',
        'obpbooooo',
        'obbbbbbbb',
        '.obbbbbbb',
        '.obbbbbbb',
        '.obbkkbbb',
        '.obbkkbbb',
        '.obbbbwww',
        '.obbbwwww',
        '.obbbwkkk',
        '..obbbwww',
        '..oobbbbb',
        '.obbbbaaa',
        'obbbbbbaa',
        'obbbbbbbb',
        'obbbhbbbb',
        '.obbbbbbb',
        '.oobboobb',
        '.ooooo...'
      ]
    },
    Pixel: { // purple cube creature with one big grin
      color: '#8d5fd0',
      pal: { o: '#2a1747', b: '#8d5fd0', h: '#b48af0', s: '#6a3fae', k: '#12091f', w: '#f4eefc', p: '#f08fc0', a: '#ffd95e' },
      rows: [
        '.......ao',
        '.......aa',
        '..oooooo.',
        '.obhhhhhh',
        'obhhhhhhh',
        'obbbbbbbb',
        'obbwwwbbb',
        'obbwkkwbb',
        'obbwkkwbb',
        'obbwwwbbb',
        'obbbbbbbb',
        'obpbbbbbb',
        'obbkkkkkk',
        'obbbwwwww',
        'obbbbbbbb',
        'obssssssss',
        '.oosssssss',
        '..oooooooo'
      ]
    },
    Latte: { // cream cat with a tabby cap and a long tail curl
      color: '#d9b27a',
      pal: { o: '#4a3320', b: '#ecd2a6', h: '#fbebcf', s: '#c9a273', k: '#1a120b', w: '#ffffff', p: '#ef9a9a', a: '#b8763c', g: '#8fc46b' },
      rows: [
        '.oo......',
        'oabo.....',
        'oaabooooo',
        'oabbbaabb',
        '.obbbbbbb',
        '.obbbbbbb',
        '.obgkbbbb',
        '.obbbbbbb',
        '.obbpbbwb',
        '..obbbbpb',
        '..oobbbbb',
        '...obbbbb',
        '..obbhhhh',
        '.obbbbbbb',
        '.obbbbbbb',
        '.obaabbbb',
        '.obbbbbbb',
        '.oabbooob',
        '.obbbo...',
        '..ooo....'
      ]
    },
    Sprout: { // round green seedling with a leaf on top
      color: '#58b052',
      pal: { o: '#17391a', b: '#58b052', h: '#8bd884', s: '#3b8a3a', k: '#0f1d10', w: '#f3fbea', p: '#f4a6a0', a: '#2f7f3a', c: '#a6e86b' },
      rows: [
        '.....oo..',
        '....occo.',
        '...occcco',
        '....oaaao',
        '.....oaao',
        '..oooooao',
        '.obhhhhho',
        'obhhhhhbb',
        'obbbbbbbb',
        'obbwkbbbb',
        'obbkkbbbb',
        'obbbbbbbb',
        'obpbbwwww',
        'obbbbbbbb',
        'obbbbbbbb',
        '.obbbbbbb',
        '.osssssss',
        '..ooosoos',
        '..ooo.ooo'
      ]
    },
    Ember: { // orange fox with white cheeks and a flame-tipped tail
      color: '#e07b39',
      pal: { o: '#4a2110', b: '#e07b39', h: '#f5a463', s: '#b55a22', k: '#1a0e08', w: '#fff4e6', p: '#f08a7a', a: '#ffd23f', c: '#e8452c' },
      rows: [
        'oo.......',
        'obbo.....',
        'obwbo....',
        'obwbbooooo',
        'obbbbbbbb',
        '.obbbbbbb',
        '.obkkbbbb',
        '.obkkbbbb',
        '.owbbbbbb',
        '.owwbbbwb',
        '..owwwwww',
        '..oowwwkk',
        '...obbbbb',
        '..obbhhhh',
        '.obbbbbbb',
        '.obbwwwww',
        '.obbbwwww',
        '.oobbbbbb',
        '.okkoboob',
        '..ooo.oco'
      ]
    },
    Beans: { // dark coffee-bean with a crease, little barista cap and a smile
      color: '#7a4a2b',
      pal: { o: '#24140a', b: '#7a4a2b', h: '#a06a42', s: '#573219', k: '#120a05', w: '#f6efe2', p: '#e7968a', a: '#d65a4a' },
      rows: [
        '..ooooooo',
        '.owwwwwww',
        '.owwwwwaa',
        '..oooooooo',
        '..obhhhhhh',
        '.obhhbbbbb',
        '.obbbbbbs.',
        '.obbkkbbsb',
        '.obbkkbbsb',
        '.obbbbbbsb',
        '.obpbbbbs.',
        '.obbbbkkkk',
        '.obbbbbbsb',
        '.obbbbbbsb',
        '..obbbbbs.',
        '..osbbbbbb',
        '...oosssss',
        '....ooooo.'
      ]
    },
    Frost: { // ice-blue penguin with a white belly and an orange beak
      color: '#6fb6d8',
      pal: { o: '#12304a', b: '#6fb6d8', h: '#a5dcf2', s: '#4a8fb4', k: '#0a1a28', w: '#f1fbff', a: '#f0a030', p: '#f4a9b4' },
      rows: [
        '...ooooo.',
        '..obhhhhh',
        '.obbbbbbb',
        '.obbbbbbb',
        '.obbkkbbb',
        '.obbkkbbb',
        '.obbbbaaa',
        '.obbbbbaa',
        '..obbbwww',
        '.obbbwwww',
        'obbbwwwww',
        'obbbwwwww',
        'obbbwwwww',
        'obbbwwwww',
        '.obbbwwww',
        '.obbbbwww',
        '..osbbbbb',
        '..oaaooaa',
        '..oaaa.aa',
        '...oo....'
      ]
    },
    Wisp: { // friendly lavender ghost with a wavy hem
      color: '#a99ae0',
      pal: { o: '#2a2250', b: '#d9d1f5', h: '#f1edfd', s: '#a99ae0', k: '#161030', w: '#ffffff', p: '#f0a6d0', a: '#8e7fd0' },
      rows: [
        '...ooooo.',
        '..obhhhhh',
        '.obhhhhhh',
        '.obbbbbbb',
        'obbbbbbbb',
        'obbbkkbbb',
        'obbbkkbbb',
        'obbbbbbbb',
        'obbpbbbbb',
        'obbbbkkkk',
        'obbbbbbbb',
        'obbbbbbbb',
        'osbbbbbbb',
        'osbbbbbbb',
        'ossbbbbbb',
        'osssbbbbb',
        'oas.sbbbb',
        'oo..ossss',
        '.....oooo'
      ]
    },
    Biscuit: { // golden dog with floppy ears and a pink tongue
      color: '#d9a441',
      pal: { o: '#4a2f0e', b: '#e8b95a', h: '#f8d98c', s: '#b98430', k: '#1a1006', w: '#fff3d6', p: '#ef7f8a', a: '#8a5a1e' },
      rows: [
        '..ooooooo',
        '.obhhhhhh',
        'oabbbbbbb',
        'oaabkkbbb',
        'oaabkkbbb',
        'oaabbbbbb',
        'oaab.wwww',
        '.oabbwwkk',
        '..obbwwwk',
        '..oobbwpp',
        '...obbwpp',
        '..obbhhhh',
        '.obbbbbbb',
        '.obbbwwww',
        '.obbbwwww',
        '.obbbbbbb',
        '.oabbooob',
        '.oaboo...',
        '..ooo....'
      ]
    }
  };

  const built = {};
  function build(name) {
    const c = CAST[name];
    if (!c) return null;
    if (built[name]) return built[name];
    const w = Math.max(...c.rows.map(r => r.length)) * 2, h = c.rows.length;
    const cv = document.createElement('canvas');
    cv.width = w; cv.height = h;
    const g = cv.getContext('2d');
    c.rows.forEach((row, y) => {
      const full = row.padEnd(w / 2, row.slice(-1) || '.');
      const line = full + [...full].reverse().join('');
      [...line].forEach((ch, x) => {
        const col = c.pal[ch];
        if (ch === '.' || !col) return;
        g.fillStyle = col; g.fillRect(x, y, 1, 1);
      });
    });
    return (built[name] = { canvas: cv, w, h });
  }
  const urls = {};
  window.OfficeCast = {
    names: Object.keys(CAST),
    // The grid itself, for the GoldWare OS pill (it runs this file in JavaScriptCore).
    data: name => CAST[name] && { color: CAST[name].color, pal: { ...CAST[name].pal }, rows: CAST[name].rows.slice() },
    // Your own look, from custom/office-cast.js: per character, `color` and `rows` replace, `pal`
    // merges (so { pal: { b: '#c04040' } } recolours just the body). Unknown names are ignored.
    customize: looks => {
      Object.entries(looks || {}).forEach(([name, o]) => {
        const c = CAST[name];
        if (!c || !o) return;
        if (typeof o.color === 'string') c.color = o.color;
        if (o.pal) Object.assign(c.pal, o.pal);
        if (Array.isArray(o.rows) && o.rows.length) c.rows = o.rows.map(String);
        delete built[name]; delete urls[name];
      });
    },
    has: name => !!CAST[name],
    color: name => CAST[name] && CAST[name].color,
    size: name => { const b = build(name); return b && [b.w, b.h]; },
    canvas: name => { const b = build(name); return b && b.canvas; },
    // A square tile (as a data URL) for HTML avatars.
    url: name => {
      if (urls[name]) return urls[name];
      const b = build(name);
      if (!b) return '';
      const side = Math.max(b.w, b.h), cv = document.createElement('canvas');
      cv.width = cv.height = side;
      cv.getContext('2d').drawImage(b.canvas, Math.floor((side - b.w) / 2), Math.floor((side - b.h) / 2));
      return (urls[name] = cv.toDataURL());
    }
  };
})();
