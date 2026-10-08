#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""方案布局图生成器：把 ``layout.py`` 的键位表画成键盘图（docs/layout.png）。

图上每个键显示：

* 左上角灰色大写：物理键位字母（按 ``--keyboard`` 的键盘排列放）；
* 右上角红色大写：**声母**（含 ``JD_S2K_YUN`` 的飞键/拼合规则，如 zh 在 q/f
  两键）；与键名相同的声母不重复画（键名本身就是它）；
* 下方蓝色小写：**韵母**（``JD_Y2K``，一个键多个韵母就都列出来；ü 显示为 ü）；
* 绿色：**笔形**（``JD_B`` 的五个笔画）与**形简/字根**（``--shape-dict`` 给的
  纯形码表里的部件，深绿是部件、浅绿是码的剩余字母，如 ``贝o`` = 先按 A 再按 O）。

用法::

    layout_image.py --layout layout.py --out docs/layout.png
    layout_image.py --layout layout.py --keyboard colemak \\
        --shape-dict rime/xkjd27c_flow.shape.dict.yaml --out docs/layout.png
    layout_image.py --layout layout.py --shape-dict rime/x.shape.dict.yaml \\
        --json web/data/layout.json

``--keyboard`` 支持 ``qwerty`` / ``colemak``，也可以直接给三行字母
（如 ``qwfpgjluy;|arstdhneio|zxcvbkm``）。``--json`` 导出同一份键位表给网页用
（只算一次，图和网页不会各算一遍）。
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

# 配色：黑键名 / 红声母 / 蓝韵母 / 绿笔形与字根
COLOR_KEY = (0, 0, 0)          # 键帽字：黑
COLOR_SHENG = (200, 40, 40)
COLOR_YUN = (40, 100, 200)
COLOR_SHAPE = (30, 140, 60)
COLOR_SHAPE_REST = (130, 195, 150)
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


def draw_shape_item(d, x, y, text, rest, f_item, f_rest):
    """画一个部件：深绿的部件 + 浅绿的剩余码。返回总宽度。"""
    d.text((x, y), text, font=f_item, fill=COLOR_SHAPE)
    w = d.textlength(text, font=f_item)
    if rest:
        d.text((x + w, y), rest, font=f_rest, fill=COLOR_SHAPE_REST)
        w += d.textlength(rest, font=f_rest)
    return w


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--layout', required=True, help='方案 layout.py')
    ap.add_argument('--out', default=None, help='输出 PNG 路径（--json 时可省）')
    ap.add_argument('--json', default=None,
                    help='另存一份键位表 JSON（网页用），给了就不画图')
    ap.add_argument('--keyboard', default='qwerty',
                    help='键盘排列：qwerty / colemak / 三行字母（| 分隔）')
    ap.add_argument('--shape-dict', default=None,
                    help='纯形码表（<name>.shape.dict.yaml），用来画形简/字根')
    ap.add_argument('--font', default=FONT_DEFAULT)
    ap.add_argument('--font-bold', default=FONT_BOLD_DEFAULT)
    ap.add_argument('--max-items', type=int, default=4,
                    help='每个键最多画几个字根（默认 %(default)s）')
    ap.add_argument('--scale', type=float, default=1.0, help='整体缩放')
    args = ap.parse_args()

    layout = lib.load_layout(args.layout)
    rows = (args.keyboard.split('|') if '|' in args.keyboard
            else KEYBOARDS.get(args.keyboard, KEYBOARDS['qwerty']))

    # ---- 键位表 ----
    sheng = {}                                  # 键 -> [声母...]（去掉与键名相同的）
    for s, keys in layout.JD_S2K.items():
        if s in layout.JD_S2K_YUN:              # 有规则的声母单独处理
            continue
        for k in keys:
            if s != k:                          # 键名本身就是它，不重复画
                sheng.setdefault(k, []).append(s)
    for s, rules in layout.JD_S2K_YUN.items():
        for keys, _yuns in rules:
            for k in keys:
                if s != k and s not in sheng.get(k, []):
                    sheng.setdefault(k, []).append(s)
    yun = {}                                    # 键 -> [韵母...]
    for y, keys in layout.JD_Y2K.items():
        for k in keys:
            yun.setdefault(k, []).append('ü' if y == 'v' else y)
    stroke = {}                                 # 键 -> [笔画...]
    for b, k in layout.JD_B.items():
        stroke.setdefault(k, []).append(b)
    shape = load_shape_items(args.shape_dict, layout)

    # ---- 给网页用的 JSON（同一次计算，图和网页不会各算一遍） ----
    if args.json:
        import json
        keys = {}
        all_keys = set(sheng) | set(yun) | set(stroke) | set(shape)
        for k in sorted(all_keys):
            keys[k] = {
                'sheng': sheng.get(k, []),
                'yun': yun.get(k, []),
                'stroke': stroke.get(k, []),
                'shape': [[t, r] for t, r in shape.get(k, [])],
            }
        # 引擎认的键位字母表（网页体验模式要按它决定「这一键给不给 librime」）
        sound_keys = set()
        for s_, ks in layout.JD_S2K.items():
            if s_ in layout.JD_S2K_YUN:
                continue
            sound_keys.update(ks if isinstance(ks, str) else [ks])
        for s_, rules in layout.JD_S2K_YUN.items():
            for keys_, _yuns in rules:
                sound_keys.update(keys_)
        shape_keys = set(layout.JD_B.values())

        data = {
            'name': getattr(layout, 'NAME', ''),
            'title': getattr(layout, 'TITLE', ''),
            'keyboard': args.keyboard,
            'rows': rows,
            'keys': keys,
            'soundKeys': ''.join(sorted(sound_keys)),
            'shapeKeys': ''.join(sorted(shape_keys)),
        }
        with open(args.json, 'w', encoding='utf-8') as fh:
            json.dump(data, fh, ensure_ascii=False, sort_keys=True, indent=1)
        print('写出 %s（%d 个键）' % (args.json, len(keys)))
        return

    if not args.out:
        ap.error('要么给 --out（画图），要么给 --json（导出键位表）')

    # ---- 画布几何 ----
    s = args.scale
    key_w, key_h, gap = 160 * s, 160 * s, 14 * s
    margin = 26 * s
    stagger = (key_w + gap) / 2
    width = int(margin * 2 + max(len(r) for r in rows) * (key_w + gap) - gap)
    height = int(margin * 2 + len(rows) * (key_h + gap) - gap)
    img = Image.new('RGB', (width, height), COLOR_BG)
    d = ImageDraw.Draw(img)
    f_key = ImageFont.truetype(args.font, int(34 * s))
    f_sheng = ImageFont.truetype(args.font_bold, int(30 * s))
    f_stroke = ImageFont.truetype(args.font, int(30 * s))
    f_yun = ImageFont.truetype(args.font, int(36 * s))
    f_item = ImageFont.truetype(args.font, int(30 * s))
    f_rest = ImageFont.truetype(args.font, int(26 * s))
    pad = 11 * s
    pad_bottom = 20 * s            # 底部两块（韵母 / 字根）离键帽底边的距离
    line_h = 40 * s                # 韵母行高
    item_h = 34 * s                # 字根行高

    def wrap(items, font, limit, sep=' '):
        """按宽度贪心折行（每项之间 sep）。"""
        lines, cur, w = [], [], 0
        for it in items:
            iw = d.textlength(it, font=font)
            add = iw + (d.textlength(sep, font=font) if cur else 0)
            if cur and w + add > limit:
                lines.append(cur)
                cur, w = [it], iw
            else:
                cur.append(it)
                w += add
        if cur:
            lines.append(cur)
        return lines

    for r, row in enumerate(rows):
        x0 = margin + stagger * r
        y0 = margin + (key_h + gap) * r
        for c, letter in enumerate(row):
            x = x0 + (key_w + gap) * c
            box = (x, y0, x + key_w, y0 + key_h)
            if not any(letter in t for t in (sheng, yun, stroke, shape)):
                continue                        # 这个键没内容（如 keytao 的 ;）
            d.rounded_rectangle(box, radius=12 * s, outline=COLOR_BORDER,
                                width=max(1, int(2 * s)), fill=COLOR_BG)
            # 键名（左上，灰大写）
            d.text((x + pad, y0 + pad - 4 * s), letter.upper(), font=f_key,
                   fill=COLOR_KEY)
            # 右上：声母（红大写；zh/ch/sh 小写）+ 基础笔画（绿）
            ty = y0 + pad
            if sheng.get(letter):
                label = ' '.join(t if len(t) > 1 else t.upper()
                                 for t in sheng[letter])
                d.text((x + key_w - pad, ty), label, font=f_sheng,
                       fill=COLOR_SHENG, anchor='ra')
                ty += 32 * s
            if stroke.get(letter):
                d.text((x + key_w - pad, ty), ' '.join(stroke[letter]),
                       font=f_stroke, fill=COLOR_SHAPE, anchor='ra')
            # 下方：韵母（蓝，自动 1~2 行，左对齐）
            if yun.get(letter):
                lines = wrap(yun[letter], f_yun, key_w - 2 * pad)[:2]
                ty = y0 + key_h - pad_bottom - len(lines) * line_h
                for line in lines:
                    d.text((x + pad, ty), ' '.join(line), font=f_yun,
                           fill=COLOR_YUN)
                    ty += line_h
            # 下方：字根（绿，底对齐居中；深绿部件 + 浅绿剩余码）
            elif shape.get(letter):
                items = shape[letter][:args.max_items]
                items = [(t, rest) for t, rest in items
                         if d.textlength(t + rest, font=f_item) <= key_w - 2 * pad]
                lines = wrap([t + rest for t, rest in items], f_item,
                             key_w - 2 * pad, sep='  ')
                ty = y0 + key_h - pad_bottom - len(lines) * item_h
                for line in lines:
                    tw = sum(d.textlength(t + rest, font=f_item)
                             for t, rest in items
                             if t + rest in line) + \
                        (len(line) - 1) * d.textlength('  ', font=f_item)
                    sx = x + (key_w - tw) / 2
                    for t, rest in items:
                        if t + rest not in line:
                            continue
                        draw_shape_item(d, sx, ty, t, rest, f_item, f_rest)
                        sx += d.textlength(t + rest, font=f_item) + \
                            d.textlength('  ', font=f_item)
                    ty += item_h
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    img.save(args.out)
    print('%s -> %s（%dx%d）' % (layout.name or args.layout, args.out,
                                 img.size[0], img.size[1]))


if __name__ == '__main__':
    main()
