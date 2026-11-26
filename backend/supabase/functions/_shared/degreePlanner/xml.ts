// A small XML reader, written because the degree "pack" builder has to read
// Penn's Degree Works audit templates in the Supabase Edge runtime, in Deno
// and in a plain build script alike, and none of the three should need a
// dependency (an npm XML package would be one more thing to vet, bundle and
// keep working under the edge runtime's import rules).
//
// It is strict where strictness protects the result and silent where it does
// not: a closing tag that does not match its opening tag throws, because a
// template read with a wrong tree would give a planner wrong requirements
// without any visible symptom; but a DOCTYPE, a processing instruction or a
// comment is skipped, because Penn's files carry an XML declaration and
// nothing else we need to honour. Namespaces are not interpreted (the tag is
// whatever precedes the first space or `>`), and the encoding named in the
// declaration is the caller's business: this function receives a string.
//
// `text` is every direct text run of the element joined in document order,
// entity-decoded and NOT trimmed. Callers decide what whitespace means; the
// wrong choice here would be to trim, since the whitespace between two
// SubText pieces of a qualifier can matter to whoever joins them.

export interface XmlNode {
  tag: string;
  attrs: Record<string, string>;
  children: XmlNode[];
  text: string;
}

const NAMED: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };

export function decodeEntities(s: string): string {
  if (s.indexOf("&") < 0) return s;
  return s.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/g, (whole, body: string) => {
    if (body[0] === "#") {
      const cp = body[1] === "x" || body[1] === "X" ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      if (!Number.isFinite(cp) || cp < 0 || cp > 0x10ffff) return whole;
      return String.fromCodePoint(cp);
    }
    return NAMED[body] ?? whole;
  });
}

function lineOf(src: string, pos: number): number {
  let n = 1;
  for (let i = 0; i < pos && i < src.length; i++) if (src.charCodeAt(i) === 10) n++;
  return n;
}

function fail(src: string, pos: number, msg: string): never {
  throw new Error(`XML error at line ${lineOf(src, pos)}: ${msg}`);
}

const NAME_END = /[\s/>]/;

export function parseXml(src: string): XmlNode {
  const stack: XmlNode[] = [];
  let root: XmlNode | null = null;
  let i = 0;
  const n = src.length;
  if (src.charCodeAt(0) === 0xfeff) i = 1;

  const addText = (t: string) => {
    const top = stack[stack.length - 1];
    if (top) top.text += decodeEntities(t);
  };

  while (i < n) {
    const lt = src.indexOf("<", i);
    if (lt < 0) {
      addText(src.slice(i));
      break;
    }
    if (lt > i) addText(src.slice(i, lt));
    i = lt;

    if (src.startsWith("<!--", i)) {
      const end = src.indexOf("-->", i + 4);
      if (end < 0) fail(src, i, "unterminated comment");
      i = end + 3;
    } else if (src.startsWith("<![CDATA[", i)) {
      const end = src.indexOf("]]>", i + 9);
      if (end < 0) fail(src, i, "unterminated CDATA");
      const top = stack[stack.length - 1];
      if (top) top.text += src.slice(i + 9, end);
      i = end + 3;
    } else if (src.startsWith("<?", i)) {
      const end = src.indexOf("?>", i + 2);
      if (end < 0) fail(src, i, "unterminated processing instruction");
      i = end + 2;
    } else if (src.startsWith("<!", i)) {
      // DOCTYPE and friends. An internal subset may nest brackets.
      let depth = 0;
      let j = i + 2;
      for (; j < n; j++) {
        const c = src[j];
        if (c === "[") depth++;
        else if (c === "]") depth--;
        else if (c === ">" && depth <= 0) break;
      }
      if (j >= n) fail(src, i, "unterminated declaration");
      i = j + 1;
    } else if (src.startsWith("</", i)) {
      const end = src.indexOf(">", i + 2);
      if (end < 0) fail(src, i, "unterminated closing tag");
      const name = src.slice(i + 2, end).trim();
      const open = stack.pop();
      if (!open) fail(src, i, `closing tag </${name}> with nothing open`);
      if (open.tag !== name) fail(src, i, `mismatched tag: <${open.tag}> closed by </${name}>`);
      i = end + 1;
    } else {
      // Opening or self-closing tag. Attribute values may contain ">", so
      // scan with quote awareness rather than indexOf(">").
      let j = i + 1;
      while (j < n && !NAME_END.test(src[j])) j++;
      const tag = src.slice(i + 1, j);
      if (!tag) fail(src, i, "empty tag name");
      const attrs: Record<string, string> = {};
      let selfClosing = false;
      for (;;) {
        while (j < n && /\s/.test(src[j])) j++;
        if (j >= n) fail(src, i, `unterminated tag <${tag}`);
        if (src[j] === ">") {
          j++;
          break;
        }
        if (src[j] === "/" && src[j + 1] === ">") {
          selfClosing = true;
          j += 2;
          break;
        }
        const eq = src.indexOf("=", j);
        if (eq < 0) fail(src, j, `attribute without value in <${tag}>`);
        const name = src.slice(j, eq).trim();
        if (!name || /[\s<>"'/]/.test(name)) fail(src, j, `bad attribute name in <${tag}>`);
        let k = eq + 1;
        while (k < n && /\s/.test(src[k])) k++;
        const q = src[k];
        if (q !== '"' && q !== "'") fail(src, k, `unquoted attribute value in <${tag}>`);
        const close = src.indexOf(q, k + 1);
        if (close < 0) fail(src, k, `unterminated attribute value in <${tag}>`);
        attrs[name] = decodeEntities(src.slice(k + 1, close));
        j = close + 1;
      }
      const node: XmlNode = { tag, attrs, children: [], text: "" };
      const parent = stack[stack.length - 1];
      if (parent) parent.children.push(node);
      else if (root) fail(src, i, `second root element <${tag}>`);
      else root = node;
      if (!selfClosing) stack.push(node);
      i = j;
    }
  }
  if (stack.length) throw new Error(`XML error: <${stack[stack.length - 1].tag}> is never closed`);
  if (!root) throw new Error("XML error: no root element");
  return root;
}

/** Every descendant (not the node itself) with the tag, in document order. */
export function findAll(node: XmlNode, tag: string, out: XmlNode[] = []): XmlNode[] {
  for (const c of node.children) {
    if (c.tag === tag) out.push(c);
    findAll(c, tag, out);
  }
  return out;
}

/** Number of elements per tag in the whole tree, the node included. */
export function countTags(node: XmlNode, into: Record<string, number> = {}): Record<string, number> {
  into[node.tag] = (into[node.tag] ?? 0) + 1;
  for (const c of node.children) countTags(c, into);
  return into;
}
