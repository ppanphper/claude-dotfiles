#!/usr/bin/env python3
"""Render a Claude reply (Markdown) to a PNG via headless Chrome.

Reads Markdown from stdin, writes an image, and prints one line to stdout:
    photo\t<path>      → send with sendPhoto (inline preview, within TG limits)
    document\t<path>   → send with sendDocument (too tall/large for a photo)

Exits non-zero (printing nothing) if it can't produce an image, so the caller
can fall back to a plain-text Telegram message. Optional deps degrade:
  - `markdown` + `pygments`  → rich HTML + syntax highlighting (else a minimal
                               built-in converter).
  - `PIL` (Pillow)           → autocrop to content + exact dimension decision
                               (else the raw screenshot, sent as a document).
Chrome/Chromium is required.
"""
import argparse
import html
import os
import re
import shutil
import subprocess
import sys
import tempfile

CHROME_CANDIDATES = [
    os.environ.get("NOTIFY_CHROME", ""),
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "chrome",
]


def find_chrome():
    for c in CHROME_CANDIDATES:
        if not c:
            continue
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
        p = shutil.which(c)
        if p:
            return p
    return None


def md_to_html_body(md_text):
    """Markdown → HTML fragment. Prefers the `markdown` lib; falls back to a
    small converter that still handles code fences, headings, lists and bold."""
    try:
        import markdown  # type: ignore
        exts = ["fenced_code", "tables", "sane_lists", "nl2br"]
        try:
            import pygments  # noqa: F401
            exts.append("codehilite")
        except Exception:
            pass
        return markdown.markdown(md_text, extensions=exts, output_format="html5"), True
    except Exception:
        return _minimal_md(md_text), False


def _inline(s):
    s = html.escape(s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", s)
    s = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', s)
    return s


def _minimal_md(md_text):
    out, in_code, in_list = [], False, False
    for line in md_text.split("\n"):
        if line.strip().startswith("```"):
            if in_code:
                out.append("</code></pre>"); in_code = False
            else:
                if in_list:
                    out.append("</ul>"); in_list = False
                out.append("<pre><code>"); in_code = True
            continue
        if in_code:
            out.append(html.escape(line)); continue
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            if in_list:
                out.append("</ul>"); in_list = False
            n = len(m.group(1)); out.append("<h%d>%s</h%d>" % (n, _inline(m.group(2)), n)); continue
        if re.match(r"^\s*[-*+]\s+", line):
            if not in_list:
                out.append("<ul>"); in_list = True
            out.append("<li>%s</li>" % _inline(re.sub(r"^\s*[-*+]\s+", "", line))); continue
        if in_list:
            out.append("</ul>"); in_list = False
        if not line.strip():
            out.append("")
        else:
            out.append("<p>%s</p>" % _inline(line))
    if in_code:
        out.append("</code></pre>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def pygments_css(theme="dark"):
    try:
        from pygments.formatters import HtmlFormatter
        style = "default" if theme == "light" else "github-dark"
        return HtmlFormatter(style=style).get_style_defs(".codehilite")
    except Exception:
        return ""


# Source-order list of the fence languages (```python → "python"). The markdown
# lib's codehilite output drops the language name, so we pull it from the raw text
# and re-attach it to each code block in source order; counts must match or we skip
# labelling (see decorate_code_blocks) to stay safe.
def fence_langs(md_text):
    langs, in_code = [], False
    for line in md_text.split("\n"):
        s = line.strip()
        if s.startswith("```") or s.startswith("~~~"):
            if not in_code:
                rest = s[3:].strip()
                langs.append(rest.split()[0] if rest else "")
                in_code = True
            else:
                in_code = False
    return langs


# Tag each top-level code block with data-lang="<language>" so the CSS title bar can
# show it. codehilite wraps blocks in <div class="codehilite">; the minimal/fenced
# path emits a bare <pre>. Either way the open tags appear in source order, so we map
# them 1:1 to fence_langs(). If the counts disagree (e.g. an indented code block the
# scanner didn't see) we leave the HTML untouched — the dots still render, just no
# label — rather than risk mislabelling.
def decorate_code_blocks(html_str, langs):
    if not langs:
        return html_str
    token = '<div class="codehilite">' if 'class="codehilite"' in html_str else "<pre>"
    if html_str.count(token) != len(langs):
        return html_str
    parts = html_str.split(token)
    out = [parts[0]]
    for i, seg in enumerate(parts[1:]):
        lang = langs[i]
        if lang:
            out.append(token[:-1] + ' data-lang="%s">' % html.escape(lang))
        else:
            out.append(token)
        out.append(seg)
    return "".join(out)


# ── semantic colouring ───────────────────────────────────────────────────────
# Markdown carries no "importance" metadata, so we colour by signal: status
# symbols, the value inside an inline `code` span, a small high-confidence keyword
# dictionary, and GitHub-style > [!WARNING] callouts. Everything runs on the HTML
# AFTER code blocks are stashed out (so source code is never recoloured) and only
# on text nodes (never inside tags), so the output stays valid HTML.
KW_GOOD = ["全部通过", "全绿", "已完成", "已可用", "可用", "通过", "成功", "完成", "修复", "正常",
           "passed", "success", "fixed", "resolved"]
KW_BAD = ["失败", "失效", "报错", "错误", "异常", "禁用", "禁止", "无法", "不能", "不可", "致命",
          "崩溃", "中断", "拒绝", "阻塞", "回退", "failed", "error", "denied", "forbidden",
          "invalid", "fatal", "broken", "blocked"]
KW_WARN = ["警告", "注意", "谨慎", "警惕", "待定", "暂停", "未做", "遗留", "todo", "warning", "caution"]
_NEG = "(?<![不没无未])"   # skip 不成功 / 未通过 etc. for the positive dictionary
KW_GOOD_RE = re.compile(_NEG + "(" + "|".join(map(re.escape, KW_GOOD)) + ")")
KW_BAD_RE = re.compile("(" + "|".join(map(re.escape, KW_BAD)) + ")", re.I)
KW_WARN_RE = re.compile("(" + "|".join(map(re.escape, KW_WARN)) + ")", re.I)
ALERT_LABEL = {"note": "说明", "tip": "提示", "important": "重要", "warning": "警告", "caution": "注意"}


def _on_text_nodes(html_str, fn):
    """Apply fn to text segments only, leaving <tags> untouched."""
    return "".join(p if p.startswith("<") else fn(p) for p in re.split(r"(<[^>]+>)", html_str))


def _symbols(t):
    t = re.sub(r"([✓✅√])", r'<span class="sem-ok">\1</span>', t)
    t = re.sub(r"([✗❌✘×])", r'<span class="sem-bad">\1</span>', t)
    t = re.sub(r"(⚠️?)", r'<span class="sem-warn">\1</span>', t)
    return t


def _keywords(t):
    t = KW_BAD_RE.sub(r'<span class="kw-bad">\1</span>', t)
    t = KW_WARN_RE.sub(r'<span class="kw-warn">\1</span>', t)
    t = KW_GOOD_RE.sub(r'<span class="kw-good">\1</span>', t)
    return t


def _code_status(m):
    txt = m.group(1)
    low = txt.lower()
    if re.search(r"(?:^|[^a-z])(true|ok|pass|passed|success|ready|done)(?:$|[^a-z])", low) \
       or "rc=0" in low or "✓" in txt or "全绿" in txt:
        return '<code class="sem-ok">%s</code>' % txt
    if re.search(r"(?:^|[^a-z])(false|fail|failed|error|err|denied|invalid)(?:$|[^a-z])", low) \
       or "✗" in txt:
        return '<code class="sem-bad">%s</code>' % txt
    return m.group(0)


def _render_alerts(html_str):
    # A blockquote may hold several [!TYPE] paragraphs (markdown merges adjacent
    # > blocks separated by a blank line into one <blockquote>), so split on each
    # <p>[!TYPE] marker and emit one alert card per marker; keep any non-alert lead
    # as a plain blockquote, and leave blockquotes with no marker untouched.
    def conv(m):
        inner = m.group(1)
        if not re.search(r"<p>\[!\w+\]", inner):
            return m.group(0)
        parts = re.split(r"<p>\[!(\w+)\]\s*(?:<br\s*/?>)?\s*", inner)
        out = []
        if parts[0].strip():
            out.append("<blockquote>%s</blockquote>" % parts[0])
        for i in range(1, len(parts), 2):
            typ = parts[i].lower()
            body = parts[i + 1] if i + 1 < len(parts) else ""
            label = ALERT_LABEL.get(typ, typ.upper())
            cls = typ if typ in ALERT_LABEL else "note"
            out.append('<div class="alert alert-%s"><div class="alert-title">%s</div><p>%s</div>'
                       % (cls, html.escape(label), body))
        return "".join(out)
    return re.sub(r"<blockquote>\s*(.*?)\s*</blockquote>", conv, html_str, flags=re.S)


def semantic_html(html_str):
    stash = []

    def keep(m):
        stash.append(m.group(0))
        return "\x00%d\x00" % (len(stash) - 1)

    s = re.sub(r'<div class="codehilite".*?</div>', keep, html_str, flags=re.S)
    s = re.sub(r"<pre.*?</pre>", keep, s, flags=re.S)
    s = _render_alerts(s)
    s = re.sub(r"<code>([^<]+)</code>", _code_status, s)   # inline code only (pre is stashed)
    s = _on_text_nodes(s, _symbols)
    s = _on_text_nodes(s, _keywords)
    return re.sub(r"\x00(\d+)\x00", lambda m: stash[int(m.group(1))], s)


# Colours are CSS variables so a single `.theme-light` class swaps the whole palette
# (--theme light). {accent} is the status colour piped in by notify.sh (green = done,
# amber = wait): it tints the header bar, status dot, links, list markers and the
# quote rule, so "finished" vs "needs me" reads at a glance. color-mix needs Chrome
# 111+ (2023); every Chrome that runs --headless=new here has it.
CSS_TMPL = """
* {{ box-sizing: border-box; }}
:root {{
  --accent: {accent};
  --bg:#0d1117; --fg:#c9d1d9; --fg-strong:#e6edf3; --muted:#8b949e;
  --card:#161b22; --card2:#1b222c; --border:#30363d; --border2:#21262d; --code-bg:#6e768166;
  --ok:#3fb950; --bad:#f85149; --warn:#d29922; --imp:#a371f7;
}}
.theme-light {{
  --bg:#ffffff; --fg:#1f2328; --fg-strong:#0d1117; --muted:#59636e;
  --card:#f6f8fa; --card2:#eaeef2; --border:#d1d9e0; --border2:#d8dee4; --code-bg:#818b981f;
  --ok:#1a7f37; --bad:#cf222e; --warn:#9a6700; --imp:#8250df;
}}
html, body {{ margin:0; padding:0; background:var(--bg); }}
body {{
  width:{width}px; min-height:100vh; padding:26px 30px 30px; color:var(--fg);
  -webkit-font-smoothing:antialiased;
  font:16px/1.7 -apple-system, "PingFang SC", "Microsoft YaHei",
       "Segoe UI", "Helvetica Neue", Arial, "Noto Sans CJK SC", sans-serif;
  word-wrap:break-word;
}}
.hdr {{
  display:flex; align-items:flex-start; gap:10px;
  padding:11px 15px; margin:0 0 20px; border-radius:10px;
  border:1px solid var(--border); border-left:4px solid var(--accent);
  background:linear-gradient(180deg, var(--card2), var(--card));
}}
.hdr .dot {{ width:9px; height:9px; margin-top:6px; border-radius:50%; flex:none; background:var(--accent);
            box-shadow:0 0 0 3px color-mix(in srgb, var(--accent) 22%, transparent); }}
.hdr .hbody {{ display:flex; flex-direction:column; gap:2px; min-width:0; }}
.hdr .htitle {{ font-weight:650; font-size:15px; color:var(--fg-strong); }}
.hdr .hmeta {{ font-size:12px; color:var(--muted);
              font-family:"SF Mono", Menlo, Consolas, monospace; word-break:break-all; }}
h1,h2,h3,h4 {{ color:var(--fg-strong); line-height:1.3; margin:20px 0 10px; font-weight:650; }}
h1 {{ font-size:1.5em; border-bottom:1px solid var(--border); padding-bottom:7px; }}
h2 {{ font-size:1.28em; border-bottom:1px solid var(--border2); padding-bottom:5px; }}
h3 {{ font-size:1.12em; }}
p {{ margin:9px 0; }}
strong {{ color:var(--fg-strong); }}
a {{ color:var(--accent); text-decoration:none;
    border-bottom:1px solid color-mix(in srgb, var(--accent) 40%, transparent); }}
ul, ol {{ padding-left:1.5em; margin:9px 0; }}
li {{ margin:4px 0; }}
li::marker {{ color:var(--accent); }}
code {{ font-family:"SF Mono", "JetBrains Mono", Menlo, Consolas, monospace; font-size:0.86em;
       background:var(--code-bg); padding:0.16em 0.42em; border-radius:6px; }}
/* Code block as a macOS-style window: traffic-light dots + language label up top.
   The bar lives on the outer container (.codehilite, or a bare <pre>); a <pre>
   nested inside .codehilite is reset so the bar isn't drawn twice. */
pre, .codehilite {{ position:relative; background:var(--card); border:1px solid var(--border);
                   border-radius:10px; padding:40px 16px 14px; overflow-x:auto; margin:13px 0; }}
pre::before, .codehilite::before {{ content:""; position:absolute; top:15px; left:15px;
  width:11px; height:11px; border-radius:50%; background:#ff5f56; box-shadow:19px 0 #ffbd2e, 38px 0 #27c93f; }}
pre::after, .codehilite::after {{ content:attr(data-lang); position:absolute; top:12px; right:15px;
  font-size:11px; color:var(--muted); font-family:"SF Mono", Menlo, monospace; }}
pre code {{ background:none; padding:0; font-size:0.85em; line-height:1.55; }}
.codehilite pre {{ position:static; background:none; border:0; padding:0; margin:0; }}
.codehilite pre::before, .codehilite pre::after {{ display:none; }}
blockquote {{ border-left:3px solid var(--accent); margin:12px 0; padding:4px 14px;
             color:var(--muted); background:color-mix(in srgb, var(--card) 55%, transparent);
             border-radius:0 8px 8px 0; }}
table {{ border-collapse:collapse; margin:13px 0; width:100%; font-size:0.95em; }}
th, td {{ border:1px solid var(--border); padding:7px 13px; text-align:left; }}
th {{ background:var(--card2); color:var(--fg-strong); font-weight:650; }}
tbody tr:nth-child(2n) {{ background:color-mix(in srgb, var(--card) 40%, transparent); }}
hr {{ border:0; border-top:1px solid var(--border); margin:18px 0; }}
/* semantic colouring (NOTIFY_TG_IMAGE_SEMANTIC): status symbols, code status
   values, keyword dictionary, and GitHub-style alert callouts */
.sem-ok {{ color:var(--ok); }}
.sem-bad {{ color:var(--bad); }}
.sem-warn {{ color:var(--warn); }}
code.sem-ok {{ color:var(--ok); }}
code.sem-bad {{ color:var(--bad); }}
.kw-good {{ color:var(--ok); font-weight:650; }}
.kw-bad {{ color:var(--bad); font-weight:650; }}
.kw-warn {{ color:var(--warn); font-weight:650; }}
.alert {{ border-left:4px solid var(--border); border-radius:8px; padding:8px 15px 10px;
         margin:13px 0; background:color-mix(in srgb, var(--card) 55%, transparent); }}
.alert p {{ margin:5px 0; }}
.alert-title {{ font-weight:700; font-size:0.82em; letter-spacing:0.04em; margin-bottom:2px; }}
.alert-note {{ border-color:var(--accent); }} .alert-note .alert-title {{ color:var(--accent); }}
.alert-tip {{ border-color:var(--ok); }} .alert-tip .alert-title {{ color:var(--ok); }}
.alert-important {{ border-color:var(--imp); }} .alert-important .alert-title {{ color:var(--imp); }}
.alert-warning {{ border-color:var(--warn); }} .alert-warning .alert-title {{ color:var(--warn); }}
.alert-caution {{ border-color:var(--bad); }} .alert-caution .alert-title {{ color:var(--bad); }}
"""


def build_html(body, width, header, accent="#58a6ff", meta="", theme="dark"):
    cls = "theme-light" if theme == "light" else ""
    hdr = ""
    if header or meta:
        title = ""
        if header:
            # Status is shown by the coloured dot, so strip a leading status emoji
            # (🟢/🟡/🔴…) from the title to avoid doubling up with the dot.
            t = re.sub(r"^[\U0001F300-\U0001FAFF☀-➿️\s]+", "", header).strip()
            title = '<div class="htitle">%s</div>' % html.escape(t)
        metah = '<div class="hmeta">%s</div>' % html.escape(meta) if meta else ""
        hdr = ('<div class="hdr"><span class="dot"></span>'
               '<div class="hbody">%s%s</div></div>') % (title, metah)
    return ("<!doctype html><html><head><meta charset='utf-8'><style>%s\n%s</style></head>"
            "<body class='%s'>%s%s</body></html>") % (
            CSS_TMPL.format(width=width, accent=accent), pygments_css(theme), cls, hdr, body)


def estimate_height(md_text, width):
    cpl = max(20, int(width / 9))  # chars per line at this width
    lines = 0
    for ln in md_text.split("\n"):
        lines += max(1, -(-len(ln) // cpl))  # ceil
    px = int(lines * 30 * 1.4) + 240        # generous + padding, then crop
    return max(480, min(px, 16000))


def run_chrome(chrome, html_path, out_path, width, height, scale):
    args = [chrome, "--headless=new", "--disable-gpu", "--no-proxy-server",
            "--hide-scrollbars", "--no-sandbox", "--disable-dev-shm-usage",
            "--force-device-scale-factor=%d" % scale,
            "--window-size=%d,%d" % (width, height),
            "--virtual-time-budget=6000",
            "--screenshot=%s" % out_path, "file://%s" % html_path]
    try:
        subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=40, check=False)
    except Exception:
        return False
    return os.path.isfile(out_path) and os.path.getsize(out_path) > 0


def run_chrome_pdf(chrome, html_path, out_pdf):
    args = [chrome, "--headless=new", "--disable-gpu", "--no-proxy-server",
            "--no-sandbox", "--disable-dev-shm-usage", "--no-pdf-header-footer",
            "--print-to-pdf=%s" % out_pdf, "file://%s" % html_path]
    try:
        subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=40, check=False)
    except Exception:
        return False
    return os.path.isfile(out_pdf) and os.path.getsize(out_pdf) > 0


def autocrop(path):
    """Trim trailing background. Returns (width, height, clipped) or None."""
    try:
        from PIL import Image, ImageChops
    except Exception:
        return None
    im = Image.open(path).convert("RGB")
    bg = Image.new("RGB", im.size, im.getpixel((0, 0)))
    bbox = ImageChops.difference(im, bg).getbbox()
    if not bbox:
        return (im.width, im.height, False)
    clipped = bbox[3] >= im.height - 4   # content reaches the bottom → was cut off
    bottom = min(im.height, bbox[3] + 28)
    im = im.crop((0, 0, im.width, bottom))
    im.save(path)
    return (im.width, im.height, clipped)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--width", type=int, default=int(os.environ.get("NOTIFY_TG_IMAGE_WIDTH", "760")))
    ap.add_argument("--scale", type=int, default=2)
    ap.add_argument("--header", default="")
    ap.add_argument("--accent", default=os.environ.get("NOTIFY_TG_IMAGE_ACCENT", "#58a6ff"))
    ap.add_argument("--meta", default="")
    ap.add_argument("--theme", default=os.environ.get("NOTIFY_TG_IMAGE_THEME", "dark"))
    ap.add_argument("--semantic", default=os.environ.get("NOTIFY_TG_IMAGE_SEMANTIC", "1"))
    args = ap.parse_args()

    md_text = sys.stdin.read()
    if not md_text.strip():
        return 1
    chrome = find_chrome()
    if not chrome:
        return 1

    body, _ = md_to_html_body(md_text)
    body = decorate_code_blocks(body, fence_langs(md_text))
    if str(args.semantic) not in ("0", "", "false", "no"):
        body = semantic_html(body)
    page = build_html(body, args.width, args.header, args.accent, args.meta, args.theme)
    # Keep the intermediate HTML beside the requested PNG/PDF. notify.sh places
    # that output in its per-send temp directory, so its EXIT/signal trap can
    # remove the HTML too if this renderer is terminated before finally runs.
    out_dir = os.path.dirname(os.path.abspath(args.out))
    with tempfile.NamedTemporaryFile(
            "w", prefix="reply-", suffix=".html", dir=out_dir,
            delete=False, encoding="utf-8") as f:
        f.write(page); html_path = f.name

    try:
        height = estimate_height(md_text, args.width)
        if not run_chrome(chrome, html_path, args.out, args.width, height, args.scale):
            return 1
        dims = autocrop(args.out)
        if dims is None:
            # No Pillow: can't measure/trim → send as a document to be safe.
            print("document\t%s" % args.out)
            return 0
        w, h, clipped = dims
        if clipped:
            # Content overran our window — render the full thing as a PDF instead.
            pdf = os.path.splitext(args.out)[0] + ".pdf"
            if run_chrome_pdf(chrome, html_path, pdf):
                print("document\t%s" % pdf); return 0
        # Telegram sendPhoto limits: width+height <= 10000 and ratio <= 20.
        if (w + h) <= 10000 and h <= w * 20:
            print("photo\t%s" % args.out)
        else:
            print("document\t%s" % args.out)
        return 0
    finally:
        try:
            os.unlink(html_path)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
