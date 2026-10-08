#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把键道6（KeyTao）原版固定码表转成「流」方案能用的词库。

为什么单独一个转换器
--------------------
键道6 的词库是**固定码表**：每条只有「字词 + 原码」，没有拼音、没有词频，
排序也全在原表顺序里。这和 27/27C・流的 ``build_flow_dict.py``（从拼音词库
造音码、按词频排）是两条路，所以 keytao 方案用这个专用转换器。

转换规则
--------
原码 = 音码 + 形码。键道6 的形码键是 ``aiouv``，音码键是其余 21 键，两套
不相交，所以按「第一个 aiouv 字母」切分即可：
``音码 = 码[:第一个形码键]``、``形码 = 码[第一个形码键:]``。
（纯形码条目切出来的音码为空，进纯形码表。）

「流」的 translator 只吃音码（形码由 flow_shape 处理器收集、flow_shapes 按
``<词库>.shape.txt`` 在运行时筛选），所以生成三份数据：

* ``<name>.dict.yaml``       主词库：只放词组，头部 import 下面两份；
* ``<name>.danzi.dict.yaml`` 单字表：所有单字条目（音码）；
* ``<name>.shape.dict.yaml`` 纯形码表：音码为空的条目（code = 形码）；
* ``<name>.shape.txt``       每个字的完整形码（由单字码的最长形码部分推导），
                             运行时形码筛选与提示用。

权重：len-dupe（实测还原度最高，见下）
--------------------------------------
::

    weight = (MAXLEN + 1 - 原码长) + 重码内按原表顺序的降序值

* 先按**原码码长**分层：原码越短权重越高（原版就是「简码在前」）；
* 只有**同一个生成码**里的多个候选（重码）才做次级排序，顺序取
  「来源表序 + 表内行序」= 原版顺序；层间距 1.0、重码内差值 < 0.5，不跨层；
* 不同码、同层 → 权重相同。

实测（489 个 1~2 键样本码，原版 vs flow 同按键）：top1 一致 100%；
1998 个分层样本码 top1 一致 99.7%。其它策略（len-ice / rank / len-then-rank…）
都更差，所以只保留 len-dupe。

用法::

    # 默认读 /tmp/KeyTao（不在就 git clone），生成到指定目录
    keytao_table_to_flow_dict.py --out-dir /path/to/rime_keytao_flow/rime

    # 指定 KeyTao 仓库 / 输出名
    keytao_table_to_flow_dict.py --keytao ~/KeyTao --out-dir ./rime \\
        --name keytao_orig
"""

import argparse
import collections
import os
import subprocess
import sys

KT_REPO_URL = 'https://github.com/xkinput/KeyTao.git'
KT_TABLES = ('keytao.single', 'keytao.phrase', 'keytao.supplement')
SHAPE_KEYS = set('aiouv')       # 键道6 形码键（音码键与它不相交）
MAX_CODE = 6                    # 单字最长原码（音码 2 + 形码 4）


def find_keytao(path, url=KT_REPO_URL):
    """找 KeyTao 仓库；目录不在就 git clone 一份（自动拉取）。"""
    if os.path.isdir(os.path.join(path, 'rime')):
        return path
    print('KeyTao 数据源：%s 不在，尝试 git clone %s' % (path, url))
    try:
        subprocess.run(['git', 'clone', '--depth', '1', '-q', url, path],
                       check=True)
    except Exception as err:                       # noqa: BLE001
        sys.exit('clone 失败（%s）；用 --keytao 指定已有的 KeyTao 仓库' % err)
    if not os.path.isdir(os.path.join(path, 'rime')):
        sys.exit('%s 里没有 rime/，不是 KeyTao 仓库' % path)
    return path


def iter_entries(path):
    """产出码表条目 (text, code, row)；row 是表内数据行序（0 起）。"""
    in_header = False
    row = 0
    with open(path, encoding='utf-8') as f:
        for line in f:
            s = line.rstrip('\n')
            if not s or s.startswith('#'):
                continue
            if s == '---':
                in_header = True
                continue
            if s == '...':
                in_header = False
                continue
            if in_header:
                continue
            f2 = s.split('\t')
            if len(f2) < 2 or not f2[0] or not f2[1]:
                continue
            yield f2[0], f2[1], row
            row += 1


def split_code(code):
    """音码 / 形码切分：第一个 aiouv 字母之前是音码。"""
    for i, ch in enumerate(code):
        if ch in SHAPE_KEYS:
            return code[:i], code[i:]
    return code, ''


def fmt_weight(w):
    if w == int(w):
        return str(int(w))
    return ('%.8f' % w).rstrip('0').rstrip('.')


def write_dict(path, name, header_comment, rows, import_tables=None):
    with open(path, 'w', encoding='utf-8') as f:
        f.write(header_comment)
        if not header_comment.endswith('\n'):
            f.write('\n')
        f.write('---\n')
        f.write('name: %s\n' % name)
        f.write('version: "1.0"\n')
        f.write('sort: by_weight\n')
        f.write('use_preset_vocabulary: false\n')
        if import_tables:
            f.write('import_tables:\n')
            for t in import_tables:
                f.write('  - %s\n' % t)
        f.write('...\n')
        for text, code, weight in rows:
            f.write('%s\t%s\t%s\n' % (text, code, fmt_weight(weight)))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--keytao', default='/tmp/KeyTao', metavar='DIR',
                    help='KeyTao 仓库路径（默认 %(default)s；不在则自动 clone）')
    ap.add_argument('--out-dir', required=True, metavar='DIR',
                    help='输出目录（方案仓库的 rime/）')
    ap.add_argument('--name', default='keytao_orig',
                    help='生成的词库基础名（默认 %(default)s）')
    args = ap.parse_args()

    repo = find_keytao(args.keytao)
    tables = []
    for table in KT_TABLES:
        path = os.path.join(repo, 'rime', table + '.dict.yaml')
        if os.path.exists(path):
            tables.append((table, path))
        else:
            print('跳过（不存在）：%s' % path, file=sys.stderr)
    if not tables:
        sys.exit('%s/rime 里没有 keytao.single/phrase/supplement' % repo)

    main_rows = {}      # (text, code) -> weight（词组）
    danzi_rows = {}     # (char, sound) -> weight（单字）
    shape_rows = {}     # (text, shape) -> weight（纯形码）
    shape_full = {}     # 单字 -> 最长形码（推导 shape.txt）
    meta = {}           # (text, code) -> (原码长, 表序, 行序)，len-dupe 排序用
    stats = collections.Counter()

    def add(dst, text, code, code_len, t_idx, row):
        """同 (text, code) 只留原码最短的一条（层最高）。"""
        key = (text, code)
        cur = meta.get(key)
        if cur is not None and (code_len > cur[0] or
                                (code_len == cur[0] and
                                 (t_idx, row) >= cur[1:])):
            return False
        meta[key] = (code_len, t_idx, row)
        dst[key] = float(MAX_CODE + 1 - code_len)   # 占位，重码排序后统一覆盖
        return True

    for t_idx, (table, path) in enumerate(tables):
        n = 0
        for text, code, row in iter_entries(path):
            sound, shape = split_code(code)
            single = (len(text) == 1)
            if sound:
                if single:
                    add(danzi_rows, text, sound, len(code), t_idx, row)
                    if len(shape) > len(shape_full.get(text, '')):
                        shape_full[text] = shape
                else:
                    add(main_rows, text, sound, len(code), t_idx, row)
                stats['sound'] += 1
            else:
                add(shape_rows, text, shape, len(code), t_idx, row)
                stats['shape'] += 1
            n += 1
        print('  %-20s %6d 条' % (table, n))

    # len-dupe：同一个生成码内按「表序 + 行序」排，层内差值 < 0.5
    by_code = collections.defaultdict(list)
    for key, m in meta.items():
        by_code[key[1]].append((key, m))
    final = {}
    for code, items in by_code.items():
        items.sort(key=lambda it: it[1][1:])        # 表序 + 行序
        total = len(items)
        for rank, (key, m) in enumerate(items):
            final[key] = m[0] and (MAX_CODE + 1 - m[0]) or 0
            final[key] += 0.5 * (total - rank) / (total + 1)
    for dst in (main_rows, danzi_rows, shape_rows):
        for key in dst:
            dst[key] = final[key]
    dupe = sum(1 for v in by_code.values() if len(v) > 1)
    print('len-dupe：%d 个生成码，其中重码 %d 个' % (len(by_code), dupe))

    os.makedirs(args.out_dir, exist_ok=True)
    name = args.name
    main_path = os.path.join(args.out_dir, name + '.dict.yaml')
    danzi_path = os.path.join(args.out_dir, name + '.danzi.dict.yaml')
    shape_path = os.path.join(args.out_dir, name + '.shape.dict.yaml')
    shape_txt = os.path.join(args.out_dir, name + '.shape.txt')

    write_dict(main_path, name,
               '# %s —— 由 KeyTao（键道6）原版码表生成（词组；单字/形码见同名'
               ' danzi/shape 表，由 import_tables 引入）' % name,
               [(t, c, w) for (t, c), w in main_rows.items()],
               import_tables=[name + '.danzi', name + '.shape'])
    write_dict(danzi_path, name + '.danzi',
               '# %s 单字表 —— 音码 + len-dupe 权重（原码长分层）' % name,
               [(t, c, w) for (t, c), w in danzi_rows.items()])
    write_dict(shape_path, name + '.shape',
               '# %s 纯形码表 —— 音码为空的条目（形码 + len-dupe 权重）' % name,
               [(t, c, w) for (t, c), w in shape_rows.items()])
    with open(shape_txt, 'w', encoding='utf-8') as f:
        f.write('# %s 期望形码（由单字码的最长形码部分推导）\n' % name)
        for char, shape in shape_full.items():
            if shape:
                f.write('%s\t%s\n' % (char, shape))

    print('生成：')
    print('  %s  (%d 条)' % (main_path, len(main_rows)))
    print('  %s  (%d 条)' % (danzi_path, len(danzi_rows)))
    print('  %s  (%d 条)' % (shape_path, len(shape_rows)))
    print('  %s  (%d 字)' % (shape_txt,
                             sum(1 for v in shape_full.values() if v)))
    lens = collections.Counter(len(c) for _, c in main_rows)
    print('  主库音码长度分布:', dict(sorted(lens.items())))


if __name__ == '__main__':
    main()
