#!/usr/bin/env python3
"""Rebuild proto2 definitions from jadx-decompiled Square Wire 1.x classes (Navdy firmware)."""
import os, re, sys, collections

SRC = sys.argv[1]          # .../src/main/java
OUT = sys.argv[2]          # output dir
ROOT_PKG = "com/navdy/service/library/events"
DT = {k: k.lower() for k in "INT32 INT64 UINT32 UINT64 SINT32 SINT64 BOOL STRING BYTES FIXED32 SFIXED32 FIXED64 SFIXED64 FLOAT DOUBLE".split()}
JAVA_SCALAR = {"java.lang.Integer": "int32", "java.lang.Long": "int64", "java.lang.Boolean": "bool",
               "java.lang.String": "string", "java.lang.Float": "float", "java.lang.Double": "double",
               "okio.ByteString": "bytes"}

# ---- constant resolution for jadx-inlined tags -------------------------------------------
KNOWN = {"android.support.v4.media.TransportMediator.KEYCODE_MEDIA_PLAY": 126,
         "android.support.v4.media.TransportMediator.KEYCODE_MEDIA_PAUSE": 127}
_const_cache = {}
def resolve(expr, search_roots):
    expr = expr.strip()
    if re.fullmatch(r"-?\d+", expr): return int(expr)
    if expr in KNOWN: return KNOWN[expr]
    if expr in _const_cache: return _const_cache[expr]
    cls, name = expr.rsplit(".", 1)
    rel = cls.replace(".", "/") + ".java"
    for r in search_roots:
        p = os.path.join(r, rel)
        if os.path.exists(p):
            m = re.search(r"\b%s\s*;\s*//\s*=\s*(-?\d+)" % re.escape(name), open(p, errors="ignore").read())
            if m:
                _const_cache[expr] = int(m.group(1)); return _const_cache[expr]
    _const_cache[expr] = None
    return None

# ---- parse one java file ----------------------------------------------------------------
CLS_RE = re.compile(r"^(\s*)public (?:static )?(?:final )?(class|enum) (\w+)(.*)$")
FIELD_ANN = re.compile(r"@com\.squareup\.wire\.ProtoField\((.*)\)\s*$")
FIELD_DECL = re.compile(r"public\s*(?:/\*\s*final\s*\*/)?\s*(?:final\s+)?([\w.<>]+)\s+(\w+);")
ENUM_VAL = re.compile(r"^\s+(\w+)\((-?\d+)\)[,;]")

def parse(path, pkg):
    lines = open(path, errors="ignore").read().splitlines()
    types = []           # list of dicts
    stack = []           # (indent, typeinfo)
    pending_ann = None
    for ln in lines:
        m = CLS_RE.match(ln)
        if m:
            ind = len(m.group(1)); kind, name, rest = m.group(2), m.group(3), m.group(4)
            while stack and stack[-1][0] >= ind: stack.pop()
            parent = stack[-1][1] if stack else None
            is_msg = kind == "class" and ("extends com.squareup.wire.Message" in rest or "extends com.squareup.wire.ExtendableMessage" in rest) and "Builder" not in rest
            is_enum = kind == "enum" and "ProtoEnum" in rest
            t = {"name": name, "kind": "message" if is_msg else ("enum" if is_enum else "other"),
                 "fields": [], "values": [], "children": [], "parent": parent}
            if parent: parent["children"].append(t)
            else: types.append(t)
            stack.append((ind, t)); continue
        if not stack: continue
        cur = stack[-1][1]
        a = FIELD_ANN.search(ln)
        if a: pending_ann = a.group(1); continue
        if pending_ann is not None:
            if ln.strip().startswith("@"): continue      # e.g. @java.lang.Deprecated between annotation and field
            d = FIELD_DECL.search(ln)
            if d and cur["kind"] == "message":
                cur["fields"].append((pending_ann, d.group(1), d.group(2)))
            pending_ann = None; continue
        if cur["kind"] == "enum":
            e = ENUM_VAL.match(ln)
            if e: cur["values"].append((e.group(1), int(e.group(2))))
    return types

def ann_get(ann, key):
    m = re.search(r"\b%s\s*=\s*([\w.]+)" % key, ann); return m.group(1) if m else None

def proto_type(ann, jtype):
    dt = ann_get(ann, "type")
    dt = dt.rsplit(".", 1)[-1] if dt else "MESSAGE"
    if dt in DT: return DT[dt]
    ref = ann_get(ann, "messageType") or ann_get(ann, "enumType")
    if ref: ref = ref[:-len(".class")] if ref.endswith(".class") else ref
    else:
        g = re.match(r"java\.util\.List<(.+)>", jtype); ref = g.group(1) if g else jtype
    if ref in JAVA_SCALAR: return JAVA_SCALAR[ref]
    return "." + ref

def emit(t, ind, out):
    p = "  " * ind
    if t["kind"] == "enum":
        out.append(f"{p}enum {t['name']} {{")
        # proto enum values live in the enclosing scope: prefix to avoid collisions
        for n, v in t["values"]: out.append(f"{p}  {t['name']}_{n} = {v};")
        out.append(f"{p}}}"); return
    if t["kind"] != "message": 
        for c in t["children"]: emit(c, ind, out)
        return
    out.append(f"{p}message {t['name']} {{")
    for c in t["children"]:
        if c["kind"] in ("message", "enum"): emit(c, ind + 1, out)
    for ann, jt, fname in sorted(t["fields"], key=lambda f: int(ann_get(f[0], "tag") or 0)):
        lab = ann_get(ann, "label"); lab = lab.rsplit(".", 1)[-1].lower() if lab else "optional"
        out.append(f"{p}  {lab} {proto_type(ann, jt)} {fname} = {ann_get(ann, 'tag')};")
    if t["name"] == "NavdyEvent" and ind == 0: out.append(f"{p}  extensions 3 to max;")
    out.append(f"{p}}}")

PKGS = []
def pkg_wrapper(pkg): return pkg.rsplit(".", 1)[-1].capitalize() + "Pkg"
def mapref(m):
    fq = m.group(1)
    for pkg in sorted(PKGS, key=len, reverse=True):
        if fq.startswith(pkg + "."):
            rest = fq[len(pkg) + 1:]
            return " .navdy." + (rest if pkg == ROOT_PKG.replace("/", ".") else pkg_wrapper(pkg) + "." + rest) + " "
    return " ." + fq + " "

def main():
    search_roots = [SRC] + sys.argv[3:]
    by_pkg = collections.defaultdict(list)
    for dp, _, fs in os.walk(os.path.join(SRC, ROOT_PKG)):
        for f in sorted(fs):
            if not f.endswith(".java"): continue
            pkg = os.path.relpath(dp, SRC).replace(os.sep, ".")
            for t in parse(os.path.join(dp, f), pkg):
                if t["kind"] in ("message", "enum"): by_pkg[pkg].append(t)
    PKGS.extend(by_pkg)
    root = ROOT_PKG.replace("/", ".")
    # NavdyEvent "extensions" -> plain optional fields (identical on the wire, nicer in Swift)
    ext = open(os.path.join(SRC, ROOT_PKG, "Ext_NavdyEvent.java"), errors="ignore").read()
    nev = open(os.path.join(SRC, ROOT_PKG, "NavdyEvent.java"), errors="ignore").read()
    mtype = {n: int(v) for n, v in re.findall(r"^\s+(\w+)\((\d+)\)[,;]", nev, re.M)}
    rows, bad, mismatch = [], [], []
    for m in re.finditer(r"Extension<com\.navdy\.service\.library\.events\.NavdyEvent, ([\w.]+)> (\w+);.*?setTag\(([^)]+)\)", ext):
        tag = resolve(m.group(3), search_roots)
        mt = mtype.get(m.group(2)[0].upper() + m.group(2)[1:]) or mtype.get(m.group(1).rsplit(".", 1)[-1])
        rule = mt + 100 if mt is not None else None
        if tag is not None and rule is not None and tag != rule: mismatch.append((m.group(2), tag, rule))
        tag = tag if tag is not None else rule
        if tag is None: bad.append((m.group(2), m.group(3))); continue
        rows.append((tag, m.group(1), m.group(2)))
    rows.sort()
    body = []
    for pkg, ts in sorted(by_pkg.items()):
        chunk = []
        for t in ts: emit(t, 0 if pkg == root else 1, chunk)
        if pkg == root:
            i = max(k for k, l in enumerate(chunk) if l.startswith("message NavdyEvent"))
            j = next(k for k in range(i, len(chunk)) if chunk[k] == "}")
            chunk[j:j] = ["  // --- payloads (Ext_NavdyEvent, tag = MessageType + 100) ---"] + \
                         [f"  optional .{c} {n} = {t};" for t, c, n in rows]
            body += [f"// ===== {pkg}"] + chunk
        else:
            body += [f"// ===== {pkg}", f"message {pkg_wrapper(pkg)} {{"] + chunk + ["}"]
    text = "\n".join(body)
    text = re.sub(r"  extensions 3 to max;\n", "", text)
    text = re.sub(r"(\n\s*)packed (\w+) (\w+) = (\d+);", r"\1repeated \2 \3 = \4 [packed = true];", text)
    text = re.sub(r" \.(com\.navdy\.[\w.]+) ", mapref, text)
    hdr = ['syntax = "proto2";', "// Navdy phone<->HUD protocol, regenerated from Wire classes in navdy-display-Hud-java.",
           "// Wire framing: Frame{fixed32 size=1} (5 bytes: 0x0D + LE uint32) then NavdyEvent bytes.",
           "package navdy;", ""]
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, "navdy.proto"), "w").write("\n".join(hdr) + text + "\n")
    dup = [t for t, c in collections.Counter(r[0] for r in rows).items() if c > 1]
    print(f"packages={len(by_pkg)} types={sum(len(v) for v in by_pkg.values())} payloads={len(rows)} unresolved={bad} dup_tags={dup} rule_mismatch={mismatch}")
main()
