#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把单份 Markdown 手册转成中文 PDF（A4）。

流程与 docs/book/build_pdf.py 一致，但针对「单个 md 文件」精简为一次打印：
  1. python-markdown 渲染为 HTML（复用原书样式 + 封面）
  2. headless google-chrome 打印为 PDF

用法：
    python3 book/build_pdf_single.py [输入.md ...]
不传参数时默认转换同目录下的 flutter_build_学习手册.md。
"""

import os
import re
import subprocess
import sys
import unicodedata

import markdown

HERE = os.path.dirname(os.path.abspath(__file__))

TITLE = "flutter_build 学习手册"
SUBTITLE = "在 Linux 上交叉编译 Flutter Windows 桌面应用"
AUTHOR = "LLVM-MinGW + Wine 全开源工具链深度剖析 · 面向学习"

CSS = """
@page { size: A4; margin: 15mm 14mm 13mm 14mm; }
* { box-sizing: border-box; }
html { font-size: 9.6pt; }
body {
    font-family: "Noto Serif CJK SC", "Noto Serif CJK", "AR PL UMing CN", serif;
    line-height: 1.6; color: #1a1a1a; text-align: justify; hyphens: auto;
}
h1, h2, h3, h4 {
    font-family: "Noto Sans CJK SC", "Noto Sans CJK", "WenQuanYi Micro Hei", sans-serif;
    color: #10243e; line-height: 1.4; text-align: left;
}
h1 {
    font-size: 16pt; margin: 1.1em 0 0.6em 0; padding-bottom: 0.3em;
    border-bottom: 2pt solid #10243e; break-before: page; break-after: avoid;
}
.cover + .toc-page h1, h1.first { break-before: auto; }
h2 {
    font-size: 12.5pt; margin: 1.1em 0 0.45em 0; padding-left: 0.45em;
    border-left: 3.5pt solid #2f6fb5; break-after: avoid;
}
h3 { font-size: 10.8pt; margin: 0.9em 0 0.3em 0; break-after: avoid; }
h4 { font-size: 10pt; margin: 0.8em 0 0.25em 0; break-after: avoid; }
p { margin: 0 0 0.5em 0; }
ul, ol { margin: 0 0 0.55em 0; padding-left: 1.5em; }
li { margin: 0.14em 0; }
a { color: #2f6fb5; text-decoration: none; }
strong { color: #0d2a4a; }
code {
    font-family: "Noto Sans Mono", "DejaVu Sans Mono", monospace;
    font-size: 8.2pt; background: #f0f3f7; border: 0.5pt solid #dbe2ea;
    border-radius: 2pt; padding: 0.02em 0.25em; color: #b03a48; word-break: break-word;
}
pre {
    background: #f7f9fb; border: 0.5pt solid #d9e0e8; border-left: 2.5pt solid #7fa8d4;
    border-radius: 3pt; padding: 0.5em 0.7em; margin: 0.6em 0; overflow: hidden;
    white-space: pre-wrap; word-break: break-word; line-height: 1.45;
    break-inside: avoid;
}
pre code { background: none; border: none; padding: 0; font-size: 7.8pt; color: #22303d; }
table {
    width: 100%; border-collapse: collapse; margin: 0.6em 0 0.85em 0; font-size: 8.4pt;
    font-family: "Noto Sans CJK SC", sans-serif; break-inside: avoid;
}
th, td { border: 0.5pt solid #c3ccd6; padding: 0.26em 0.42em; text-align: left; }
th { background: #e8eef5; font-weight: 600; }
tbody tr:nth-child(even) { background: #fafbfd; }
blockquote {
    margin: 0.6em 0; padding: 0.45em 0.85em; background: #fbf7ec;
    border-left: 3pt solid #d9a441; color: #4a3c1f; font-size: 8.8pt;
}
hr { border: none; border-top: 0.6pt solid #ccd4dd; margin: 1em 0; }
.cover { text-align: center; padding-top: 40mm; break-after: page; }
.cover .kicker {
    font-family: "Noto Sans CJK SC", sans-serif; font-size: 10pt;
    letter-spacing: 0.5em; color: #2f6fb5; margin-bottom: 10mm;
}
.cover h1.title {
    font-size: 30pt; border: none; margin: 0 0 6mm 0; padding: 0;
    text-align: center; line-height: 1.25; break-before: auto;
}
.cover .subtitle { font-size: 13pt; color: #40506a; margin-bottom: 12mm; }
.cover .rule { width: 40mm; height: 2.5pt; background: #2f6fb5; margin: 0 auto 12mm auto; }
.cover .author { font-size: 10.5pt; color: #55636f; line-height: 1.9; }
"""

COVER = """
<div class="cover">
  <div class="kicker">F L U T T E R &nbsp; B U I L D</div>
  <h1 class="title">{title}</h1>
  <div class="subtitle">{subtitle}</div>
  <div class="rule"></div>
  <div class="author">{author}</div>
</div>
"""


def slugify_cjk(value, separator):
    value = unicodedata.normalize("NFKC", value)
    value = re.sub(r"[^\w]+", separator, value).strip(separator)
    return value.lower() or "_"


def render_md(text):
    md = markdown.Markdown(
        extensions=["tables", "fenced_code", "toc", "attr_list", "sane_lists", "md_in_html"],
        extension_configs={"toc": {"slugify": slugify_cjk}},
    )
    return md.convert(text)


def build_html(md_files):
    bodies = []
    for path in md_files:
        with open(path, encoding="utf-8") as fh:
            bodies.append(render_md(fh.read()))
    body = "\n".join(bodies)
    # 文档首个 h1 就是标题本身，去掉自动分页；封面单独占一页
    body = body.replace("<h1", '<h1 class="first"', 1)
    cover = COVER.format(title=TITLE, subtitle=SUBTITLE, author=AUTHOR)
    return f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>{TITLE}</title>
<style>{CSS}</style></head><body>{cover}{body}</body></html>"""


def print_pdf(html_path, pdf_path):
    cmd = [
        "google-chrome", "--headless=new", "--no-sandbox", "--disable-gpu",
        "--no-pdf-header-footer", "--run-all-compositor-stages-before-draw",
        "--virtual-time-budget=10000", f"--print-to-pdf={pdf_path}", f"file://{html_path}",
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    files = sys.argv[1:] or [os.path.join(HERE, "flutter_build_学习手册.md")]
    out = os.path.join(HERE, "flutter_build_学习手册.pdf")
    tmp_html = os.path.join(HERE, "_manual_build.html")
    with open(tmp_html, "w", encoding="utf-8") as fh:
        fh.write(build_html(files))
    print("[1/2] headless Chrome 打印中 ...")
    print_pdf(tmp_html, out)
    os.remove(tmp_html)
    size = os.path.getsize(out) / 1024 / 1024
    print(f"[2/2] 完成：{out}  ({size:.2f} MB)")


if __name__ == "__main__":
    main()
