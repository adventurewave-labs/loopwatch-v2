#!/usr/bin/env python3
"""Deterministic mutations of vectors.txt -> JSON lines {id, base, variant, body} on stdout.

Each base payload is emitted as-is plus variants that real filter bypasses rely on:
case games, alternative attribute separators, entity-encoded scheme characters,
control characters inside the scheme, alternative quoting, junk attributes, and wrapping
in otherwise-allowed markup. Same input -> same output (seeded), so CI results are stable.
"""
import json, random, re, sys, hashlib, pathlib

here = pathlib.Path(__file__).parent
bases = [l.rstrip("\n") for l in open(here / "vectors.txt", encoding="utf-8")
         if l.strip() and not l.startswith("#")]
rng = random.Random(1337)

def rand_case(s):
    return "".join(c.upper() if rng.random() < 0.5 else c.lower() for c in s)

def variants(b):
    yield "base", b
    yield "upper", b if "base64," in b else b.upper()
    yield "randcase", re.sub(r"<(/?)([a-zA-Z]+)", lambda m: "<" + m.group(1) + rand_case(m.group(2)), b)
    yield "attr-case", re.sub(r"\b(on[a-z]+|src|href|style|action|data|formaction|srcdoc)=", lambda m: rand_case(m.group(1)) + "=", b)
    yield "slash-sep", re.sub(r"<([a-zA-Z]+) ", r"<\1/", b)
    yield "newline-sep", re.sub(r"<([a-zA-Z]+) ", "<\\1\n", b)
    yield "tab-sep", re.sub(r"<([a-zA-Z]+) ", "<\\1\t", b)
    yield "formfeed-sep", re.sub(r"<([a-zA-Z]+) ", "<\\1\x0c", b)
    yield "colon-dec", b.replace("javascript:", "javascript&#58;").replace("https:", "https&#58;")
    yield "colon-hex", b.replace("javascript:", "javascript&#x3A;").replace("https:", "https&#x3a;")
    yield "colon-named", b.replace("javascript:", "javascript&colon;")
    yield "scheme-tab", b.replace("javascript:", "jav\tascript:").replace("https:", "ht\ttps:")
    yield "scheme-nl", b.replace("javascript:", "java\nscript:")
    yield "scheme-entity-tab", b.replace("javascript:", "java&#9;script:")
    yield "scheme-lead-space", b.replace('="javascript:', '="  javascript:').replace("=javascript:", "=  javascript:")
    yield "js-dec-all", b.replace("javascript:", "".join(f"&#{ord(c)};" for c in "javascript:"))
    yield "js-hex-nosemi", b.replace("javascript:", "".join(f"&#x{ord(c):x}" for c in "javascript") + ":")
    yield "slashes-enc", b.replace("//evil", "&#47;&#47;evil").replace("//evil", "&#x2f;&#x2F;evil")
    yield "backslash-host", b.replace("//evil", "\\\\evil")
    yield "single-quote", b.replace('"', "'")
    yield "unquoted", b.replace('"', "")
    yield "junk-attr", re.sub(r"<([a-zA-Z]+)([ /])", r'<\1 title="a>b" \2', b, count=1)
    yield "in-p", f"<p>text {b} more</p>"
    yield "in-code", f"<pre><code>{b}</code></pre>"
    yield "in-table", f"<table><tr><td>{b}</td></tr></table>"
    yield "css-escape", b.replace("url(", "\\75 rl(").replace("expression(", "\\65 xpression(")
    yield "css-comment", b.replace("url(", "u/**/rl(").replace("@import", "@im/**/port")
    yield "double-open", b.replace("<", "<<", 1)

out, seen = [], set()
for i, b in enumerate(bases):
    for name, body in variants(b):
        if not isinstance(body, str) or body in seen:
            continue
        seen.add(body)
        out.append({"id": hashlib.sha256(body.encode()).hexdigest()[:12], "base": i, "variant": name, "body": body})
for o in out:
    print(json.dumps(o))
print(f"{len(bases)} base vectors -> {len(out)} unique cases", file=sys.stderr)
