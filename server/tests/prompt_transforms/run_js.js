// Runs the REAL userscript transforms (extracted verbatim) over the fixtures
// and prints JSON, so the Python port can be compared against them.
const fs = require('fs');
const path = require('path');
const { T, moveLinesCore } = require('./js_transforms_extracted.js');

const fixtures = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures.json'), 'utf8'));

// python transform id -> how the JS produces it
const SEL = {
  weight1: (t) => T.weight(t, '1.0'),
  weight05: (t) => T.weight(t, '0.5'),
  neg2: T.neg2,
  braceWrap: T.braceWrap,
  braceUnwrap: (t) => T.braceAdjust(t, -1),
  pipesWrap: T.pipesWrap,
  wrapOnly: T.wrapOnly,
  joinRandBlocks: T.joinRandBlocks,
  fixRandFormat: T.fixRandFormat,
  unwrapPipes: T.unwrapPipes,
  mixWithComma: T.mixWithComma,
  commaToNL: T.commaToNL,
  nlToComma: T.nlToComma,
  insertCommas: T.insertCommas,
  stripLinebreaks: T.stripLinebreaks,
  collapseNL1: T.collapseNL1,
  dupeSel: T.dupeSel,
};

const out = {};
for (const fx of fixtures) {
  for (const [id, fn] of Object.entries(SEL)) {
    out[`${fx.name}||${id}`] = fn(fx.text);
  }
  // document transforms: whole text, caret at 0, plus a caret on line 2
  for (const dir of ['up', 'down']) {
    for (const [tag, ss, se] of [['caret0', 0, 0], ['line2', Math.min(fx.text.length, (fx.text.indexOf('\n') + 1) || 0), Math.min(fx.text.length, (fx.text.indexOf('\n') + 1) || 0)], ['all', 0, fx.text.length]]) {
      const r = moveLinesCore(fx.text, ss, se, dir);
      out[`${fx.name}||move_${dir}_${tag}`] = r === null ? null : [r.newText, r.newStart, r.newEnd];
    }
  }
}
process.stdout.write(JSON.stringify(out, null, 1));
