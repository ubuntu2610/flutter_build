#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 docs/book/chapters/*.md 编排成一本中文 PDF 讲解书。

流程：
  1. 用 python-markdown 把各章节拼成一份 HTML（含封面、目录、打印样式）
  2. 第一遍用 headless Chrome 打印，扫描每页文本，算出各章标题落在第几页
  3. 把页码回填进目录，再打印第二遍
  4. 用 pypdf + reportlab 在每页页脚叠加页码

用法：
    python3 docs/book/build_pdf.py
"""

import os
import re
import subprocess
import tempfile
import unicodedata

import markdown

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

TITLE = "CameraFileCopy 深度解析"
SUBTITLE = "用摄像头接收文件：cimbar 光传输协议与它的 Android 实现"
AUTHOR = "基于 github.com/sz3/cfc (v0.6.8) 源码讲解"
OUTPUT = os.path.join(HERE, "CameraFileCopy-深度解析.pdf")

# 第一篇：CameraFileCopy（约 20 页）
PART1 = [
    "00-intro.md",
    "01-architecture.md",
    "02-pipeline.md",
    "03-android-jni.md",
    "04-scheduler.md",
    "05-geometry.md",
    "06-symbol-color.md",
    "07-ecc-fountain.md",
    "08-encoder.md",
    "09-store-params.md",
    "10-perf-lab.md",
    "11-ecosystem.md",
]

# 第二篇：recv.html（约 10 页）
PART2 = [
    "20-recv-overview.md",
    "21-recv-ui.md",
    "22-recv-capture.md",
    "23-recv-workers.md",
    "24-recv-wasm.md",
    "25-recv-sink.md",
    "26-recv-zstd.md",
    "27-recv-pwa.md",
]

PART2_COVER = """
<div class="partmark">
  <div class="partno">第 二 篇</div>
  <div class="parttitle">recv.html：浏览器里的解码器</div>
  <div class="partdesc">
    同一个 libcimbar，换一种宿主——没有 Android、没有 JNI：摄像头来自 getUserMedia，解码跑在 WebAssembly 与 Worker 里。
  </div>
</div>
"""

CHAPTERS = PART1

CSS = """
@page {
    size: A4;
    margin: 15mm 14mm 13mm 14mm;
}
* { box-sizing: border-box; }
html { font-size: 9.2pt; }
body {
    font-family: "Noto Serif CJK SC", "Noto Serif CJK", "AR PL UMing CN", serif;
    line-height: 1.55;
    color: #1a1a1a;
    text-align: justify;
    hyphens: auto;
}
h1, h2, h3, h4 {
    font-family: "Noto Sans CJK SC", "Noto Sans CJK", "WenQuanYi Micro Hei", sans-serif;
    color: #10243e;
    line-height: 1.4;
    text-align: left;
}
h1 {
    font-size: 15pt;
    margin: 1.1em 0 0.6em 0;
    padding-bottom: 0.3em;
    border-bottom: 2pt solid #10243e;
    break-after: avoid;
}
h1.no-break { break-before: auto; }
h2 {
    font-size: 12pt;
    margin: 1em 0 0.4em 0;
    padding-left: 0.45em;
    border-left: 3.5pt solid #2f6fb5;
    break-after: avoid;
}
h3 {
    font-size: 10.2pt;
    margin: 0.9em 0 0.3em 0;
    break-after: avoid;
}
h4 { font-size: 9.6pt; margin: 0.8em 0 0.25em 0; break-after: avoid; }
p { margin: 0 0 0.45em 0; text-indent: 2em; }
li p, blockquote p, td p, th p, figcaption p { text-indent: 0; }
ul, ol { margin: 0 0 0.5em 0; padding-left: 1.4em; }
li { margin: 0.12em 0; }
li > ul, li > ol { margin-bottom: 0; }
a { color: #2f6fb5; text-decoration: none; }
strong { color: #0d2a4a; }
code {
    font-family: "Noto Sans Mono", "DejaVu Sans Mono", monospace;
    font-size: 7.9pt;
    background: #f0f3f7;
    border: 0.5pt solid #dbe2ea;
    border-radius: 2pt;
    padding: 0.02em 0.25em;
    color: #b03a48;
    word-break: break-word;
}
pre {
    background: #f7f9fb;
    border: 0.5pt solid #d9e0e8;
    border-left: 2.5pt solid #7fa8d4;
    border-radius: 3pt;
    padding: 0.45em 0.6em;
    margin: 0.55em 0;
    overflow: hidden;
    white-space: pre-wrap;
    word-break: break-word;
    line-height: 1.4;
}
pre code {
    background: none; border: none; padding: 0;
    font-size: 7.5pt; color: #22303d;
}
table {
    width: 100%;
    border-collapse: collapse;
    margin: 0.6em 0 0.8em 0;
    font-size: 8pt;
    font-family: "Noto Sans CJK SC", sans-serif;
    break-inside: avoid;
}
th, td { border: 0.5pt solid #c3ccd6; padding: 0.24em 0.4em; text-align: left; }
th { background: #e8eef5; font-weight: 600; }
tbody tr:nth-child(even) { background: #fafbfd; }
blockquote {
    margin: 0.6em 0;
    padding: 0.4em 0.8em;
    background: #fbf7ec;
    border-left: 3pt solid #d9a441;
    color: #4a3c1f;
    font-size: 8.5pt;
}
blockquote p:last-child { margin-bottom: 0; }
hr {
    border: none; border-top: 0.6pt solid #ccd4dd;
    margin: 1em 0;
}
figure {
    margin: 0.6em 0;
    text-align: center;
    break-inside: avoid;
}
figure svg { max-width: 84%; height: auto; }
figcaption {
    font-family: "Noto Sans CJK SC", sans-serif;
    font-size: 7.8pt;
    color: #5c6a78;
    margin-top: 0.3em;
    text-align: center;
}
/* ---------- 封面 ---------- */
.cover {
    text-align: center;
    padding-top: 18mm;
}
.cover .kicker {
    font-family: "Noto Sans CJK SC", sans-serif;
    font-size: 9pt; letter-spacing: 0.5em; color: #2f6fb5;
    margin-bottom: 8mm;
}
.cover h1.title {
    font-size: 27pt; border: none; margin: 0 0 5mm 0; padding: 0;
    break-before: auto; text-align: center; line-height: 1.25;
}
.cover .subtitle { font-size: 11.5pt; color: #40506a; margin-bottom: 10mm; }
.cover .rule { width: 36mm; height: 2.5pt; background: #2f6fb5; margin: 0 auto 10mm auto; }
.cover .author { font-size: 9.5pt; color: #55636f; line-height: 1.8; }
.cover .logo { margin-top: 8mm; }
.cover .logo svg { width: 150px; height: 82px; }
/* ---------- 目录 ---------- */
.toc-page h1 { break-before: auto; margin-top: 8mm; }
/* ---------- 篇分隔 ---------- */
.partmark {
    text-align: center;
    margin: 2.4em 0 1.2em 0;
    padding-top: 1.4em;
    border-top: 3pt solid #2f6fb5;
    break-inside: avoid;
}
.partmark .partno {
    font-family: "Noto Sans CJK SC", sans-serif;
    font-size: 10pt; letter-spacing: 0.45em; color: #2f6fb5;
}
.partmark .parttitle {
    font-family: "Noto Sans CJK SC", sans-serif;
    font-size: 19pt; color: #10243e; margin-top: 4mm; line-height: 1.35;
}
.partmark .partdesc {
    font-size: 9.4pt; color: #55636f; line-height: 1.9;
    max-width: 120mm; margin: 5mm auto 0 auto; text-align: left;
}
/* ---------- 第二篇：排版密度略高（Web 端内容以代码与表格为主） ---------- */
.part2 { font-size: 8.35pt; line-height: 1.42; }
.part2 h1 { font-size: 13.5pt; margin: 0.9em 0 0.5em 0; }
.part2 h2 { font-size: 10.8pt; margin: 0.8em 0 0.35em 0; }
.part2 h3 { font-size: 9.7pt; }
.part2 p { margin-bottom: 0.4em; }
.part2 ul, .part2 ol { margin-bottom: 0.45em; }
.part2 pre { margin: 0.45em 0; padding: 0.4em 0.55em; }
.part2 pre code { font-size: 6.9pt; }
.part2 code { font-size: 7.3pt; }
.part2 table { font-size: 7.3pt; margin: 0.5em 0 0.7em 0; }
.part2 th, .part2 td { padding: 0.18em 0.32em; }
.part2 blockquote { font-size: 8pt; margin: 0.5em 0; padding: 0.35em 0.7em; }
.toc ul { list-style: none; padding-left: 0; margin: 0; }
.toc > ul > li { margin: 0.2em 0; }
.toc > ul > li > a {
    font-family: "Noto Sans CJK SC", sans-serif;
    font-size: 9.6pt; font-weight: 600; color: #10243e;
}
.toc > ul > li > ul { padding-left: 1.4em; }
.toc > ul > li > ul > li { margin: 0.06em 0; }
.toc a { color: #33414f; font-size: 8.6pt; }
.toc .pagenum { float: right; color: #7b8896; font-size: 8.4pt; }
/* ---------- 小构件 ---------- */
/* 用于定位章节起始页的不可见标记：白字、极小，不影响版面 */
.chmark { font-size: 1px; color: #ffffff; font-weight: normal; }
.kv { font-family: "Noto Sans CJK SC", sans-serif; }
.tag {
    display: inline-block; font-size: 8pt; padding: 0.05em 0.45em;
    border-radius: 2pt; background: #e8eef5; color: #2f6fb5;
    font-family: "Noto Sans CJK SC", sans-serif;
}
"""

COVER = """
<div class="cover">
  <div class="kicker">C I M B A R</div>
  <h1 class="title">{title}</h1>
  <div class="subtitle">{subtitle}</div>
  <div class="rule"></div>
  <div class="author">
    {author}<br/>
    面向源码的中文讲解书 · 共 {chapters} 章
  </div>
  <div class="logo">
    <svg width="220" height="120" viewBox="0 0 220 120" xmlns="http://www.w3.org/2000/svg">
      <rect x="6" y="6" width="208" height="108" rx="6" fill="none" stroke="#2f6fb5" stroke-width="2"/>
      <g>
        <rect x="18" y="18" width="22" height="22" fill="#00ff00"/>
        <rect x="46" y="18" width="22" height="22" fill="#ffff00"/>
        <rect x="74" y="18" width="22" height="22" fill="#00ffff"/>
        <rect x="102" y="18" width="22" height="22" fill="#ff00ff"/>
        <rect x="130" y="18" width="22" height="22" fill="#00ff00"/>
        <rect x="158" y="18" width="22" height="22" fill="#ffff00"/>
        <rect x="18" y="46" width="22" height="22" fill="#00ffff"/>
        <rect x="46" y="46" width="22" height="22" fill="#ff00ff"/>
        <rect x="74" y="46" width="22" height="22" fill="#101010"/>
        <rect x="102" y="46" width="22" height="22" fill="#ffffff"/>
        <rect x="130" y="46" width="22" height="22" fill="#00ff00"/>
        <rect x="158" y="46" width="22" height="22" fill="#ffff00"/>
        <rect x="18" y="74" width="22" height="22" fill="#ff00ff"/>
        <rect x="46" y="74" width="22" height="22" fill="#00ffff"/>
        <rect x="74" y="74" width="22" height="22" fill="#ffff00"/>
        <rect x="102" y="74" width="22" height="22" fill="#00ff00"/>
        <rect x="130" y="74" width="22" height="22" fill="#00ffff"/>
        <rect x="158" y="74" width="22" height="22" fill="#ff00ff"/>
      </g>
      <rect x="186" y="18" width="16" height="16" fill="#101010"/>
      <rect x="186" y="86" width="16" height="16" fill="#101010"/>
    </svg>
  </div>
</div>
"""





def slugify_cjk(value, separator):
    """默认 slugify 会丢弃全部中文字符，两篇各自从 _1 开始编号会撞车。
    这里保留汉字，保证锚点稳定且唯一。"""
    value = unicodedata.normalize("NFKC", value)
    value = re.sub(r"[^\w]+", separator, value).strip(separator)
    return value.lower() or "_"


def render_md(text):
    md = markdown.Markdown(
        extensions=["tables", "fenced_code", "toc", "attr_list", "sane_lists", "md_in_html"],
        extension_configs={
            "toc": {
                "toc_depth": "1",
                "anchorlink": False,
                "permalink": False,
                "slugify": slugify_cjk,
            }
        },
    )
    body = md.convert(text)
    return body, md.toc


# 每章一个不可见标记（白字、1px），用于在 PDF 里精确定位章节起始页
MARKERS = [f"ZCH{i:02d}Z" for i in range(len(PART1) + len(PART2))]


def read_part(names, offset):
    parts = []
    for i, name in enumerate(names):
        path = os.path.join(HERE, "chapters", name)
        with open(path, encoding="utf-8") as fh:
            text = fh.read().rstrip() + "\n"
        marker = MARKERS[offset + i]
        lines = text.split("\n", 1)
        lines[0] = f'{lines[0]}<span class="chmark">{marker}</span>'
        parts.append("\n".join(lines).strip() + "\n")
    return "\n".join(parts)


def merge_toc(toc1, toc2):
    def inner(t):
        m = re.search(r"<ul>.*</ul>", t, re.S)
        return m.group(0) if m else ""

    return f'<div class="toc">{inner(toc1)}{inner(toc2)}</div>'


def render_html(toc_pages=None):
    body1, toc1 = render_md(read_part(PART1, 0))
    body2, toc2 = render_md(read_part(PART2, len(PART1)))
    body = body1 + f'<div class="part2">{PART2_COVER}</div>' + f'<div class="part2">{body2}</div>'
    toc = merge_toc(toc1, toc2)

    # 目录里不出现章节标记（toc 里标签会被剥掉，只剩纯文本，故直接按文本剔除）
    toc = re.sub(r'ZCH\d{2}Z', "", toc)
    toc = re.sub(r'<span class="chmark">\s*</span>', "", toc)

    if toc_pages is not None:
        # 页码按章节顺序依次填进目录项（toc_depth=1，一级项与章节一一对应）
        def add_slot(m):
            return f'<a href="#{m.group(1)}">{m.group(2)}</a><span class="pagenum slot"></span>'

        toc = re.sub(r'<a href="#([^"]+)">([^<]+)</a>', add_slot, toc)
        pages = iter(toc_pages)

        def fill_slot(_m):
            page = next(pages, None)
            return f'<span class="pagenum">{page}</span>' if page else ""

        toc = re.sub(r'<span class="pagenum slot"></span>', fill_slot, toc)

    cover = COVER.format(
        title=TITLE,
        subtitle=SUBTITLE,
        author=AUTHOR,
        chapters=len(PART1) + len(PART2),
    )
    return f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>{TITLE}</title>
<style>{CSS}</style></head>
<body>
{cover}
<div class="toc-page">
<h1 class="no-break">目 录</h1>
<div class="toc">{toc}</div>
</div>
{body}
</body></html>"""


def print_pdf(html_path, pdf_path):
    cmd = [
        "google-chrome",
        "--headless=new",
        "--no-sandbox",
        "--disable-gpu",
        "--no-pdf-header-footer",
        "--run-all-compositor-stages-before-draw",
        "--virtual-time-budget=8000",
        f"--print-to-pdf={pdf_path}",
        f"file://{html_path}",
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def normalize(text):
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", text))


def match_key(text):
    """用于在 PDF 文本里定位标题：只保留汉字/字母/数字，避开标点与引号的差异。"""
    return re.sub(r"[^\w]", "", unicodedata.normalize("NFKC", text))


def find_marker_pages(pdf_path):
    """按每章的不可见标记定位起始页（标记是纯 ASCII，不受中文提取乱码影响）。"""
    from pypdf import PdfReader

    pages = [p.extract_text() or "" for p in PdfReader(pdf_path).pages]
    result = []
    for marker in MARKERS:
        result.append(next((i + 1 for i, t in enumerate(pages) if marker in t), None))
    return result


def stamp_page_numbers(src, dst):
    from pypdf import PdfReader, PdfWriter
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfgen import canvas

    reader = PdfReader(src)
    writer = PdfWriter()
    total = len(reader.pages)
    tmp = os.path.join(tempfile.gettempdir(), "_cfc_pagenum.pdf")

    for i in range(total):
        if i == 0:
            writer.add_page(reader.pages[i])
            continue
        c = canvas.Canvas(tmp, pagesize=A4)
        c.setFont("Helvetica", 8.5)
        c.setFillColorRGB(0.42, 0.47, 0.53)
        c.drawCentredString(A4[0] / 2, 13.5 * 72 / 25.4, str(i + 1))
        c.save()
        with open(tmp, "rb") as fh:
            from pypdf import PdfReader as _R

            stamp = _R(fh).pages[0]
            page = reader.pages[i]
            page.merge_page(stamp)
            writer.add_page(page)

    with open(dst, "wb") as fh:
        writer.write(fh)


def main():
    os.makedirs(HERE, exist_ok=True)
    tmpdir = tempfile.mkdtemp(prefix="cfcbook")
    html1 = os.path.join(tmpdir, "book-pass1.html")
    pdf1 = os.path.join(tmpdir, "book-pass1.pdf")
    html2 = os.path.join(tmpdir, "book-pass2.html")
    pdf2 = os.path.join(tmpdir, "book-pass2.pdf")

    with open(html1, "w", encoding="utf-8") as fh:
        fh.write(render_html())
    print("[1/4] 第一遍打印，用于计算目录页码 ...")
    print_pdf(html1, pdf1)

    print("[2/4] 扫描章节起始页 ...")
    pages = find_marker_pages(pdf1)
    print(f"      命中 {sum(1 for p in pages if p)}/{len(pages)} 章")

    for name, page in zip(PART1 + PART2, pages):
        path = os.path.join(HERE, "chapters", name)
        with open(path, encoding="utf-8") as fh:
            first = fh.readline().strip().lstrip("# ")
        print(f"      {name:<22} → 第 {page if page else '?'} 页　{first}")

    with open(html2, "w", encoding="utf-8") as fh:
        fh.write(render_html(pages))
    print("[3/4] 第二遍打印 ...")
    print_pdf(html2, pdf2)

    print("[4/4] 叠加页码 ...")
    stamp_page_numbers(pdf2, OUTPUT)

    from pypdf import PdfReader

    n = len(PdfReader(OUTPUT).pages)
    size = os.path.getsize(OUTPUT) / 1024 / 1024
    print(f"完成：{OUTPUT}\n      共 {n} 页，{size:.2f} MB")


if __name__ == "__main__":
    main()
