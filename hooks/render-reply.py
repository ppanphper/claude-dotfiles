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


def pygments_css():
    try:
        from pygments.formatters import HtmlFormatter
        return HtmlFormatter(style="github-dark").get_style_defs(".codehilite")
    except Exception:
        return ""


CSS_TMPL = """
* {{ box-sizing: border-box; }}
html, body {{ margin: 0; padding: 0; background: #0d1117; }}
body {{
  width: {width}px; padding: 28px 32px;
  color: #c9d1d9;
  font: 16px/1.65 -apple-system, "PingFang SC", "Microsoft YaHei",
        "Segoe UI", "Helvetica Neue", Arial, "Noto Sans CJK SC", sans-serif;
  word-wrap: break-word;
}}
.hdr {{
  font-weight: 700; font-size: 15px; color: #e6edf3;
  padding: 8px 12px; margin: -8px -12px 18px; border-radius: 8px;
  background: #161b22; border: 1px solid #30363d;
}}
h1,h2,h3,h4 {{ color: #e6edf3; line-height: 1.3; margin: 18px 0 10px; }}
h1 {{ font-size: 1.5em; border-bottom: 1px solid #30363d; padding-bottom: 6px; }}
h2 {{ font-size: 1.3em; border-bottom: 1px solid #21262d; padding-bottom: 4px; }}
h3 {{ font-size: 1.12em; }}
p {{ margin: 8px 0; }}
a {{ color: #58a6ff; text-decoration: none; }}
ul, ol {{ padding-left: 1.6em; margin: 8px 0; }}
li {{ margin: 3px 0; }}
code {{
  font-family: "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace;
  font-size: 0.88em; background: #6e768166; padding: 0.15em 0.4em; border-radius: 5px;
}}
pre {{
  background: #161b22; border: 1px solid #30363d; border-radius: 8px;
  padding: 14px 16px; overflow-x: auto; margin: 12px 0;
}}
pre code {{ background: none; padding: 0; font-size: 0.86em; line-height: 1.5; }}
.codehilite {{ background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 14px 16px; margin: 12px 0; }}
.codehilite pre {{ background: none; border: 0; padding: 0; margin: 0; }}
blockquote {{ border-left: 3px solid #30363d; margin: 10px 0; padding: 2px 14px; color: #8b949e; }}
table {{ border-collapse: collapse; margin: 12px 0; }}
th, td {{ border: 1px solid #30363d; padding: 6px 12px; }}
th {{ background: #161b22; }}
hr {{ border: 0; border-top: 1px solid #30363d; margin: 16px 0; }}
"""


def build_html(body, width, header):
    hdr = '<div class="hdr">%s</div>' % html.escape(header) if header else ""
    return ("<!doctype html><html><head><meta charset='utf-8'><style>%s\n%s</style></head>"
            "<body>%s%s</body></html>") % (CSS_TMPL.format(width=width), pygments_css(), hdr, body)


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
    args = ap.parse_args()

    md_text = sys.stdin.read()
    if not md_text.strip():
        return 1
    chrome = find_chrome()
    if not chrome:
        return 1

    body, _ = md_to_html_body(md_text)
    page = build_html(body, args.width, args.header)
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, encoding="utf-8") as f:
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
