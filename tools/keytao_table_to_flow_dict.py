#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""键道・函流：从键道6（KeyTao）原版码表 + 冰/袖珍词库生成词库。

一次生成三套词库（共用同一份单字/形码数据）：

* ``<name>.keytao.dict.yaml``  键道6 原版码表转换（保留原版简码层级与顺序）；
* ``<name>.ice.dict.yaml``     rime-ice（雾凇拼音）词库，按键道6 布局注音；
* ``<name>.simp.dict.yaml``    袖珍简化字（pinyin_simp）词库，按键道6 布局注音。

共享数据（三套词库都 import 它们）：

* ``<name>.danzi.dict.yaml``   单字音码（由 keytao.single 转换）；
* ``<name>.shape.dict.yaml``   纯形码条目（由 keytao.supplement 转换）；
* ``<name>.shape.txt``         每个字的完整形码（运行时筛选/提示用）。

为什么单独一个转换器
--------------------
键道6 的词库是**固定码表**：每条只有「字词 + 原码」，没有拼音也没有词频，
排序全在原表顺序里；这和 27/27C・流的 ``build_flow_dict.py``（从拼音词库造
音码、按词频排）是两条路。不过拼音→音码的编码规则（含飞键）和词库读写
小工具是和 27/27C 共用 ``flow_dict_lib`` 的，没有各写一份。

布局表
------
键位表来自方案仓库的 ``layout.py``（``--layout``，默认 ``layout.py``），
与 27/27C・流 的 layout.py 同构：

* 声母键：sh = ``e``，零声母 = ``x``；zh = ``q``/``f``、ch = ``j``/``w``
  （外侧韵母用 q/j，内侧用 f/w，见 ``JD_S2K_YUN``）；
* 韵母键：见 ``JD_Y2K``（uang 是飞键 ``m``/``x``）；
* 笔形键：``aiouv``（与音码键不相交，所以原码按第一个 aiouv 字母切分即可）。

权重
----
* keytao 变体用 **len-dupe**：``weight = (MAX_CODE + 1 - 原码长) + 重码内按
  原表顺序的降序值``——先按原码码长分层（原版「简码在前」），只有同一个
  生成码里的重码才按「表序 + 行序」排；层间距 1.0、重码差值 < 0.5，不跨层。
  实测：1~2 键样本 top1 还原 100%，分层样本 99.7%。
* ice / simp 变体用词库自己的词频，词组按字数降权（``LENGTH_WEIGHT``，
  与 ``build_flow_dict.py`` 的默认一致）。

用法::

    # 在方案仓库根目录（读 layout.py，默认 KeyTao=/tmp/KeyTao、冰=/tmp/rime-ice）
    keytao_table_to_flow_dict.py --out-dir rime

    # 指定 layout.py / KeyTao / 冰词库 / 袖珍词库
    keytao_table_to_flow_dict.py --layout layout.py --keytao ~/KeyTao \\
        --rime-ice /tmp/rime-ice --pinyin-simp /path/pinyin_simp.dict.yaml \\
        --out-dir rime --name keytao_flow
"""

import argparse
import collections
import os
import subprocess
import sys

import flow_dict_lib as lib

KT_REPO_URL = 'https://github.com/xkinput/KeyTao.git'
KT_TABLES = ('keytao.single', 'keytao.phrase', 'keytao.supplement')
MAX_CODE = 6                    # 单字最长原码（音码 2 + 形码 4）
LENGTH_WEIGHT = 0.35            # 词组按字数降权底数（与 build_flow_dict 默认一致）

LAYOUT = None                   # 方案 layout.py（--layout 载入）
SHAPE_KEYS = ''                 # 形码键集合（由 LAYOUT 填）

# ---------------------------------------------------------------------------
# 键道6 原版码表 -> keytao 变体
# ---------------------------------------------------------------------------

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
    row = 0
    for f in lib.iter_dict_rows(path):
        if len(f) < 2 or not f[0] or not f[1]:
            continue
        yield f[0], f[1], row
        row += 1


def split_code(code):
    """音码 / 形码切分：第一个 aiouv 字母之前是音码。"""
    for i, ch in enumerate(code):
        if ch in SHAPE_KEYS:
            return code[:i], code[i:]
    return code, ''


def build_keytao(repo):
    """读 keytao.single/phrase/supplement，返回 (词组, 单字, 形码, 完整形码)。"""
    tables = []
    for table in KT_TABLES:
        path = os.path.join(repo, 'rime', table + '.dict.yaml')
        if os.path.exists(path):
            tables.append((table, path))
        else:
            print('跳过（不存在）：%s' % path, file=sys.stderr)
    if not tables:
        sys.exit('%s/rime 里没有 keytao.single/phrase/supplement' % repo)

    main_rows = {}      # (词, 音码) -> weight（词组）
    danzi_rows = {}     # (字, 音码) -> weight（单字）
    shape_rows = {}     # (词, 形码) -> weight（纯形码）
    shape_full = {}     # 单字 -> 最长形码（推导 shape.txt）
    meta = {}           # (text, code) -> (原码长, 表序, 行序)

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
            else:
                add(shape_rows, text, shape, len(code), t_idx, row)
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
            final[key] = (MAX_CODE + 1 - m[0]) + 0.5 * (total - rank) / (total + 1)
    for dst in (main_rows, danzi_rows, shape_rows):
        for key in dst:
            dst[key] = final[key]
    print('len-dupe：%d 个生成码，其中重码 %d 个'
          % (len(by_code), sum(1 for v in by_code.values() if len(v) > 1)))
    return main_rows, danzi_rows, shape_rows, shape_full


# ---------------------------------------------------------------------------
# 拼音词库 -> ice / simp 变体（按键道6 布局注音，飞键全展开）
# ---------------------------------------------------------------------------

def find_pinyin_simp(home):
    candidates = [
        '/usr/share/rime-data/pinyin_simp.dict.yaml',
        os.path.join(home, '.config', 'rime', 'pinyin_simp.dict.yaml'),
        os.path.join(home, '.local', 'share', 'fcitx5', 'rime',
                     'pinyin_simp.dict.yaml'),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return None


def rime_ice_files(repo):
    cn = os.path.join(repo, 'cn_dicts')
    return [os.path.join(cn, name) for name in
            ('base.dict.yaml', 'ext.dict.yaml', 'others.dict.yaml')]


def load_words(path):
    """读拼音词库 -> (words, vocab)。

    * ``词 + 拼音 [+ 权重]``：有拼音的词（两列 = 词 + 拼音，权重缺省 1.0）；
    * ``词 [+ 权重]``：没有拼音的词，交给自动注音（rime-ice others 的容错词）；
    * 单字跳过——单字由 danzi 表提供。
    """
    words, vocab = [], []
    for f in lib.iter_dict_rows(path):
        if len(f) < 2 or not f[0] or not f[1]:
            if len(f) == 1 and f and f[0] and len(f[0]) > 1:
                vocab.append((f[0], 1.0))
            continue
        text = f[0]
        if len(text) == 1:
            continue
        pinyin, weight = None, None
        if len(f) >= 3:
            pinyin = f[1] or None
            weight = lib.parse_weight(f[2]) if f[2] else None
        else:                      # 两列：拼音 或 权重
            w = lib.parse_weight(f[1])
            if w is not None:
                weight = w
            else:
                pinyin = f[1]
        if weight is None:
            weight = 1.0
        if pinyin:
            syllables = pinyin.split()
            if len(syllables) != len(text):
                continue
            words.append((text, syllables, weight))
        else:
            vocab.append((text, weight))
    return words, vocab


def build_char_codes(danzi_rows):
    """{字: [(码, 权重)...]}（自动注音用；含 1 键简码与 2 键音码）。"""
    out = {}
    for (ch, code), weight in danzi_rows.items():
        out.setdefault(ch, []).append((code, weight))
    return out


def auto_read(text, char_codes):
    """无拼音词：逐字取原版简码所指的读音。

    原版简码 = 该字最短的码：1 键（声母键）就取以它开头的音码（如 不 的
    简码 ``b`` -> 音码 ``bj``，而不是另一读音 fǒu 的 ``fd``）；最短的就是
    2 键音码时，它本身就是首选读音。
    """
    reading = []
    for ch in text:
        options = char_codes.get(ch)
        if not options:
            return None
        shortest = min(options, key=lambda o: (len(o[0]), -o[1]))[0]
        if len(shortest) == 2:
            full = shortest
        else:
            cands = [(c, w) for c, w in options
                     if len(c) == 2 and c[0] == shortest]
            if not cands:
                return None
            full = max(cands, key=lambda o: o[1])[0]
        reading.append([(full, full[0])])
    return reading


def encode_words(loaded, char_codes):
    """(words, vocab) -> {(词, 码): 权重}（飞键全组合，同码取大）。"""
    out = {}

    def add(text, reading, weight):
        if not reading:
            return
        for code, scale in LAYOUT.word_codes(reading, 1.0, LENGTH_WEIGHT):
            key = (text, code)
            w = weight * scale
            if w > out.get(key, 0.0):
                out[key] = w

    words, vocab = loaded
    for text, syllables, weight in words:
        add(text, lib.syllables_reading(LAYOUT, syllables), weight)
    for text, weight in vocab:
        add(text, auto_read(text, char_codes), weight)
    return out


# ---------------------------------------------------------------------------
# 写出
# ---------------------------------------------------------------------------

def write_dict(path, name, header_comment, rows, import_tables=None):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
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
            f.write('%s\t%s\t%s\n' % (text, code, lib.format_weight(weight)))


def variant_header(name, variant, note):
    return ('# %s 词库（%s）\n'
            '# 由 tools/keytao_table_to_flow_dict.py 自动生成，请勿手工修改\n'
            '# 2 字：音音全码；3/4 字：首字母；5 字以上：前三首 + 末一首\n'
            '---\n'
            'name: %s.%s\n'
            'version: "1.2"\n'
            'sort: by_weight\n'
            'use_preset_vocabulary: false\n'
            'import_tables:\n'
            '  - %s.danzi\n'
            '  - %s.shape\n'
            '...\n' % (LAYOUT.meta['title'], note, name, variant,
                        name, name))


def write_variant(out_dir, name, variant, note, rows):
    path = os.path.join(out_dir, '%s.%s.dict.yaml' % (name, variant))
    ordered = [(t, c, w) for (t, c), w in
               sorted(rows.items(), key=lambda kv: (kv[0][1], -kv[1], kv[0][0]))]
    write_dict(path, '%s.%s' % (name, variant),
               variant_header(name, variant, note), ordered)
    return path, len(rows)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def main():
    home = os.path.expanduser('~')
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--layout', default='layout.py', metavar='FILE',
                    help='方案 layout.py（默认 %(default)s）')
    ap.add_argument('--keytao', default='/tmp/KeyTao', metavar='DIR',
                    help='KeyTao 仓库路径（默认 %(default)s；不在则自动 clone）')
    ap.add_argument('--rime-ice', default='/tmp/rime-ice', metavar='DIR',
                    help='rime-ice 仓库路径（默认 %(default)s；不在则跳过 ice 变体）')
    ap.add_argument('--pinyin-simp', default=None, metavar='FILE',
                    help='pinyin_simp.dict.yaml 路径（默认自动找）')
    ap.add_argument('--out-dir', required=True, metavar='DIR',
                    help='输出目录（方案仓库的 rime/）')
    ap.add_argument('--name', default='keytao_flow',
                    help='输出前缀（默认 %(default)s）')
    args = ap.parse_args()

    global LAYOUT, SHAPE_KEYS
    LAYOUT = lib.load_layout(args.layout)
    SHAPE_KEYS = LAYOUT.SHAPE_KEYS
    name = args.name
    repo = find_keytao(args.keytao)
    print('数据源：')
    print('  KeyTao: %s' % repo)

    print('键道6 原版码表：')
    main_rows, danzi_rows, shape_rows, shape_full = build_keytao(repo)

    os.makedirs(args.out_dir, exist_ok=True)
    write_dict(os.path.join(args.out_dir, name + '.danzi.dict.yaml'),
               name + '.danzi',
               '# %s 单字表 —— 音码 + len-dupe 权重（原码长分层）' % name,
               [(t, c, w) for (t, c), w in
                sorted(danzi_rows.items(),
                       key=lambda kv: (kv[0][1], -kv[1], kv[0][0]))])
    write_dict(os.path.join(args.out_dir, name + '.shape.dict.yaml'),
               name + '.shape',
               '# %s 纯形码表 —— 音码为空的条目（形码 + len-dupe 权重）' % name,
               [(t, c, w) for (t, c), w in
                sorted(shape_rows.items(),
                       key=lambda kv: (kv[0][1], -kv[1], kv[0][0]))])
    with open(os.path.join(args.out_dir, name + '.shape.txt'),
              'w', encoding='utf-8', newline='\n') as f:
        f.write('# %s 期望形码（由单字码的最长形码部分推导）\n' % name)
        for char, shape in sorted(shape_full.items()):
            if shape:
                f.write('%s\t%s\n' % (char, shape))
    print('  单字 %d 条，纯形码 %d 条，期望形码 %d 字'
          % (len(danzi_rows), len(shape_rows),
             sum(1 for v in shape_full.values() if v)))

    # keytao 变体（原版码表）
    path, n = write_variant(args.out_dir, name, 'keytao',
                            'KeyTao 键道6 原版码表，len-dupe',
                            main_rows)
    print('词库 keytao：%d 条 -> %s' % (n, path))

    # ice / simp 变体（拼音词库按键道6 布局注音）
    char_codes = build_char_codes(danzi_rows)
    ice_dir = args.rime_ice
    if ice_dir and os.path.isdir(ice_dir):
        loaded = ([], [])
        for path in rime_ice_files(ice_dir):
            if os.path.exists(path):
                words, vocab = load_words(path)
                print('  %s（%d 词 + %d 无拼音）' % (path, len(words), len(vocab)))
                loaded[0].extend(words)
                loaded[1].extend(vocab)
        rows = encode_words(loaded, char_codes)
        path, n = write_variant(args.out_dir, name, 'ice',
                                'rime-ice 雾凇拼音', rows)
        print('词库 ice：%d 条 -> %s' % (n, path))
    else:
        print('未找到 rime-ice（%s），跳过 ice 变体' % ice_dir)

    simp_path = args.pinyin_simp or find_pinyin_simp(home)
    if simp_path and os.path.exists(simp_path):
        print('  %s' % simp_path)
        rows = encode_words(load_words(simp_path), char_codes)
        path, n = write_variant(args.out_dir, name, 'simp',
                                '袖珍简化字 pinyin_simp', rows)
        print('词库 simp：%d 条 -> %s' % (n, path))
    else:
        print('未找到 pinyin_simp.dict.yaml，跳过 simp 变体（用 --pinyin-simp 指定）')


if __name__ == '__main__':
    main()
