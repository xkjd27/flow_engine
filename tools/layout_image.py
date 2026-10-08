#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""方案布局图生成器：把 ``layout.py`` 的键位表画成键盘图（docs/layout.png）。

图上每个键显示：

* 左上角灰色：物理键位字母（按 ``--keyboard`` 的键盘排列放）；
* 右上角红色：**声母**（含 ``JD_S2K_YUN`` 的飞键/拼合规则，如 zh 在 q/f 两键）；
* 下方蓝色：**韵母**（``JD_Y2K``，一个键多个韵母就都列出来）；
* 绿色：**笔形**（``JD_B`` 的五个笔画）与**形简/字根**（``--shape-dict`` 给的
  纯形码表里的部件，显示部件 + 码的剩余字母，如 ``贝o`` = 先按 a 再按 o）。

用法::

    layout_image.py --layout layout.py --out docs/layout.png
    layout_image.py --layout layout.py --keyboard colemak \\
        --shape-dict rime/xkjd27c_flow.shape.dict.yaml --out docs/layout.png

``--keyboard`` 支持 ``qwerty`` / ``colemak``，也可以直接给三行字母
（如 ``qwfpgjluy;|arstdhneio|zxcvbkm``）。
"""

import argparse
import os
import sys

import flow_dict_lib as lib

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:                                # noqa: BLE001
    sys.exit('需要 Pillow：pip install pillow')

# 键盘排列（每行一个字符串；';' 是物理键，方案不用就空着）
KEYBOARDS = {
    'qwerty': ['qwertyuiop', 'asdfghjkl;', 'zxcvbnm'],
    'colemak': ['qwfpgjluy;', 'arstdhneio', 'zxcvbkm'],
}

# 配色（跟另外两个方案的图一致：灰键名 / 红声母 / 蓝韵母 / 绿笔形）
COLOR_KEY = (110, 110, 110)
COLOR_SHENG = (208, 32, 32)
COLOR_YUN = (24, 96, 200)
COLOR_SHAPE = (24, 150, 60)
COLOR_BORDER = (40, 40, 40)
COLOR_BG = (255, 255, 255)

FONT_DEFAULT = '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'
FONT_BOLD_DEFAULT = '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc'


def load_shape_items(path, layout):
    """纯形码表 -> {首字母: [(部件, 码的剩余字母)...]}（笔画不算，另画）。"""
    items = {}
    if not path or not os.path.exists(path):
        return items
    strokes = set(layout.JD_B)
    for f in lib.iter_dict_rows(path):
        if len(f) < 2 or not f[0] or not f[1]:
            continue
        text, code = f[0], f[1]
        if text in strokes or len(code) < 2:
            continue
        items.setdefault(code[0], []).append((text, code[1:]))
    for key in items:
        items[key].sort(key=lambda it: (len(it[1]), it[0]))
    return items


def draw_rounded(draw, box, radius, outline, width, fill):
    draw.rounded_rectangle(box, radius=radius, outline=outline, width=width,
                           fill=fill)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--layout', required=True, help='方案 layout.py')
    ap.add_argument('--out', required=True, help='输出 PNG 路径')
    ap.add_argument('--keyboard', default='qwerty',
                    help='键盘排列：qwerty / colemak / 三行字母（| 分隔）')
    ap.add_argument('--shape-dict', default=None,
                    help='纯形码表（<name>.shape.dict.yaml），用来画形简/字根')
    ap.add_argument('--font', default=FONT_DEFAULT)
    ap.add_argument('--font-bold', default=FONT_BOLD_DEFAULT)
    ap.add_argument('--max-items', type=int, default=6,
                    help='每个键最多画几个形简/字根（默认 %(default)s）')
    ap.add_argument('--scale', type=float, default=1.0, help='整体缩放')
    args = ap.parse_args()

    layout = lib.load_layout(args.layout)
    rows = (args.keyboard.split('|') if '|' in args.keyboard
            else KEYBOARDS.get(args.keyboard, KEYBOARDS['qwerty']))
    if isinstance(rows, str):
        sys.exit('未知键盘：%s（可用 qwerty / colemak 或三行字母）' % args.keyboard)

    # ---- 键位表 ----
    sheng = {}                                  # 键 -> [声母...]
    for s, keys in layout.JD_S2K.items():
        if s in layout.JD_S2K_YUN:              # 有规则的声母单独处理
            continue
        for k in keys:
            sheng.setdefault(k, []).append(s)
    for s, rules in layout.JD_S2K_YUN.items():
        for keys, _yuns in rules:
            for k in keys:
                if s not in sheng.get(k, []):
                    sheng.setdefault(k, []).append(s)
    yun = {}                                    # 键 -> [韵母...]
    for y, keys in layout.JD_Y2K.items():
        for k in keys:
            yun.setdefault(k, []).append('ü' if y == 'v' else y)
    stroke = {}                                 # 键 -> [笔画...]
    for b, k in layout.JD_B.items():
        stroke.setdefault(k, []).append(b)
    shape = load_shape_items(args.shape_dict, layout)

    # ---- 画布几何 ----
    s = args.scale
    key_w, key_h, gap = 150 * s, 140 * s, 12 * s
    margin = 28 * s
    stagger = (key_w + gap) / 2
    width = int(margin * 2 + max(len(r) for r in rows) * (key_w + gap) - gap)
    height = int(margin * 2 + len(rows) * (key_h + gap) - gap)
    img = Image.new('RGB', (width, height), COLOR_BG)
    d = ImageDraw.Draw(img)
    f_key = ImageFont.truetype(args.font, int(24 * s))
    f_sheng = ImageFont.truetype(args.font_bold, int(26 * s))
    f_yun = ImageFont.truetype(args.font, int(21 * s))
    f_shape = ImageFont.truetype(args.font, int(18 * s))

    for r, row in enumerate(rows):
        x0 = margin + stagger * r
        y0 = margin + (key_h + gap) * r
        for c, letter in enumerate(row):
            x = x0 + (key_w + gap) * c
            box = (x, y0, x + key_w, y0 + key_h)
            has_content = any(letter in t for t in
                              (sheng, yun, stroke, shape))
            if not has_content:
                continue
            draw_rounded(d, box, 12 * s, COLOR_BORDER, max(1, int(2 * s)),
                         COLOR_BG)
            pad = 10 * s
            # 键名（左上）
            d.text((x + pad, y0 + pad), letter, font=f_key, fill=COLOR_KEY)
            # 声母（右上）
            if sheng.get(letter):
                d.text((x + key_w - pad, y0 + pad), ' '.join(sheng[letter]),
                       font=f_sheng, fill=COLOR_SHENG, anchor='ra')
            # 韵母（下方，左对齐换行）
            lines = []
            cur = ''
            for y in yun.get(letter, []):
                cand = (cur + ' ' + y).strip()
                if cur and d.textlength(cand, font=f_yun) > key_w - 2 * pad:
                    lines.append(cur)
                    cur = y
                else:
                    cur = cand
            if cur:
                lines.append(cur)
            ty = y0 + key_h - pad - len(lines) * (24 * s)
            for line in lines:
                d.text((x + pad, ty), line, font=f_yun, fill=COLOR_YUN)
                ty += 24 * s
            # 笔形 + 形简/字根（中上部，绿色）
            items = list(stroke.get(letter, []))
            items += ['%s%s' % (t, rest) for t, rest in
                      shape.get(letter, [])[:args.max_items]]
            limit = x + key_w - pad
            line_h = 22 * s
            bottom = y0 + key_h - pad - len(lines) * 24 * s - line_h
            sx, sy = x + pad, y0 + 44 * s
            for it in items:
                if d.textlength(it, font=f_shape) > key_w - 2 * pad:
                    continue                     # 太长的部件跳过，别溢出去
                w = d.textlength(it + ' ', font=f_shape)
                if sx + w > limit:
                    sx, sy = x + pad, sy + line_h
                if sy > bottom:
                    break
                d.text((sx, sy), it, font=f_shape, fill=COLOR_SHAPE)
                sx += w
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    img.save(args.out)
    print('%s -> %s（%dx%d）' % (layout.name or args.layout, args.out,
                                 img.size[0], img.size[1]))


if __name__ == '__main__':
    main()
