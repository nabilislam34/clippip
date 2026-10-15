    // ---------- Weight/separator normalization ----------
    function normalizeWeights(raw) {
        let t = raw.replace(/\r\n/g, '\n');
        t = t.replace(/(\d+(?:\.\d+)?)::\s*\n+\s*([^:\n][\s\S]*?)\s*\n+\s*::/g, (_, w, inner) => `${w}::${inner.trim()}::`);
        t = t.replace(/::\s*(?=\d+(?:\.\d+)?::)/g, '::, ');
        t = t.replace(/\s*,\s*/g, ', ').replace(/,\s*,+/g, ', ');
        return t;
    }

    // ---------- Tokenizers ----------
    function splitByComma(t) { return t.split(/\s*,\s*/g).map(x => x.trim()).filter(Boolean); }
    function splitCommaOrNL(t) { return t.split(/\s*,\s*|\n+/g).map(x => x.trim()).filter(Boolean); }
    function splitLoose(t) { return t.split(/\s*,\s*|\n+|\s{2,}/g).map(x => x.trim()).filter(Boolean); }

    function splitCommaOrNLSafe(t) { t = normalizeWeights(t).replace(/\r\n/g, '\n'); return splitCommaOrNL(t); }
    function splitLooseSafe(t) { t = normalizeWeights(t).replace(/\r\n/g, '\n'); return splitLoose(t); }

    // ---------- Transforms ----------
    const T = {
        // v2.1.3: Joins multiple ||...|| blocks into one ||...|...||
        joinRandBlocks: (t) => {
            const matches = [...t.matchAll(/\|\|([\s\S]*?)\|\|/g)];
            if (matches.length < 2) return t;
            const contents = matches.map(m => m[1]);
            return `||${contents.join('|')}||`;
        },

        // NEW v2.2.0: Removes pipes intelligntly.
        // 1. If pipe is adjacent to a comma (e.g. "Mix with comma" syntax |,), remove only pipe.
        // 2. If pipe is between text (A|B), replace it with a comma.
        unwrapPipes: (t) => {
            if (!t) return t;
            // Handle Mix-Comma style "|," or ",|" -> keep the comma, drop the pipe
            let out = t.replace(/\|\s*,/g, ',').replace(/,\s*\|/g, ',');
            // Remove start/end blocks
            out = out.replace(/^\|+|\|+$/g, '');
            // Replace remaining internal pipes with comma+space
            out = out.replace(/\|+/g, ', ');
            // Cleanup double spaces/commas that might result
            out = out.replace(/\s*,\s*/g, ', ').trim();
            // Cleanup leading/trailing comma
            out = out.replace(/^,\s*|\s*,$/g, '');
            return out;
        },

        // NEW v2.2.0: Fixes malformed randomizers (e.g. ||A|B||C|D|| -> ||A|B|C|D||)
        // Ensures double pipes are ONLY at start and end.
        fixRandFormat: (t) => {
            if (!t) return t;
            let clean = t.trim();
            // Strip all leading/trailing pipes
            clean = clean.replace(/^\|+|\|+$/g, '');
            // Replace ANY sequence of internal pipes with a single pipe
            clean = clean.replace(/\|+/g, '|');
            // Re-wrap
            return `||${clean}||`;
        },

        dupeSel: (t) => t ? `${t}, ${t}` : t,
        braceWrap: (t) => `{${t}}`,

        braceAdjust: (t, dir) => {
            if (dir > 0) return `{${t}}`;
            if (t.startsWith('{') && t.endsWith('}')) {
                return t.slice(1, -1);
            }
            return t;
        },

        mixWithComma: (t) => {
            let fixed = t.replace(/([^,])\s*[\r\n]+/g, '$1,');
            fixed = fixed.replace(/[\r\n]+/g, ' ');
            fixed = fixed.replace(/\s*,\s*/g, ',');
            return `||${fixed.trim()}|,||`;
        },

        pipesWrap: (t) => {
            if (/^\s*\|\|[\s\S]*\|\|\s*$/.test(t)) return t.trim();
            const tokens = splitCommaOrNLSafe(t);
            const joined = tokens.join('|').replace(/^\|+|\|+$/g, '');
            return `||${joined}||`;
        },
        wrapOnly:  (t) => `||${t}||`,

        weight: (t, w) => t.split(/\r?\n/).map(s => {
            let line = s.trim();
            if (!line) return '';
            if (/\d$/.test(line)) line += ',';
            return `${w}::${line}::`;
        }).filter(Boolean).join('\n'),

        neg2: (t) => {
            let inner = t.replace(/^\s*-?\d+(?:\.\d+)?::/,'').replace(/::\s*$/,'').trim();
            if (/\d$/.test(inner)) inner += ',';
            return `-2::${inner}::`;
        },

        stripLinebreaks: (t) => t.replace(/\r?\n+/g, ' ').replace(/\s{2,}/g, ' ').trim(),
        commaToNL: (t) => {
            const normalized = normalizeWeights(t).replace(/\r?\n+/g, ' ');
            const parts = normalized.split(/\s*,\s*/g).map(x => x.trim()).filter(Boolean);
            return parts.map(p => p + ',').join('\n');
        },
        nlToComma: (t) => t.split(/\r?\n/).map(s=>s.trim()).filter(Boolean).join(', '),
        insertCommas: (t) => splitLooseSafe(t).join(', '),

        collapseNL1: (t) => {
            let n = t.replace(/\r\n/g, '\n');
            n = n.replace(/[ \t]+\n/g, '\n');
            n = n.replace(/\n{2,}/g, '\n');
            return n;
        },
    };

    async function getClipboard() { try { return await navigator.clipboard.readText(); } catch { return ''; } }

    function moveLinesCore(text, ss, se, dir) {
        const lines = text.split('\n');
        const last  = lines.length - 1;

        // Map char offset → line index
        function offsetToLine(off) {
            let count = 0;
            for (let i = 0; i < lines.length; i++) {
                count += lines[i].length + 1; // +1 for '\n'
                if (off < count) return i;
            }
            return last;
        }
        // Map line index → char offset of its first character
        function lineToOffset(li) {
            let count = 0;
            for (let i = 0; i < li; i++) count += lines[i].length + 1;
            return count;
        }

        let startLine = offsetToLine(ss);
        let endLine   = offsetToLine(se);

        // If selection ends exactly at start of a line (col 0) and spans >1 line, don't include it
        if (se > ss && se === lineToOffset(endLine)) endLine--;
        if (endLine < startLine) endLine = startLine;

        if (dir === 'up'   && startLine === 0)    return null;
        if (dir === 'down' && endLine   === last)  return null;

        const block = lines.slice(startLine, endLine + 1);
        let newLines;
        let newStartLine;

        if (dir === 'up') {
            const above = lines[startLine - 1];
            newLines = [
                ...lines.slice(0, startLine - 1),
                ...block,
                above,
                ...lines.slice(endLine + 1),
            ];
            newStartLine = startLine - 1;
        } else {
            const below = lines[endLine + 1];
            newLines = [
                ...lines.slice(0, startLine),
                below,
                ...block,
                ...lines.slice(endLine + 2),
            ];
            newStartLine = startLine + 1;
        }

        const newEndLine = newStartLine + (endLine - startLine);
        const newText    = newLines.join('\n');

        // Preserve column offset of original ss within first line
        const origColStart = ss - lineToOffset(startLine);
        const origColEnd   = se - lineToOffset(endLine);
        const newLineToOffset = (li) => {
            let c = 0;
            for (let i = 0; i < li; i++) c += newLines[i].length + 1;
            return c;
        };
        const clamp = (v, max) => Math.min(v, max);
        const newStart = newLineToOffset(newStartLine) + clamp(origColStart, newLines[newStartLine].length);
        // origColEnd can be lines[endLine].length+1 when se was at col 0 of the next line (after endLine--),
        // so allow up to length+1 to preserve the "past-end-of-line" position.
        const newEnd   = newLineToOffset(newEndLine)   + Math.min(origColEnd, newLines[newEndLine].length + 1);

        return { newText, newStart, newEnd };
    }
module.exports = { T, moveLinesCore, normalizeWeights };
