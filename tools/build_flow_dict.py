#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build sound-only (音码) dictionaries for a 键道「流」schema.

数据源
------
* 方案 ``layout.py``（``--layout`` 指定）：布局表（拼音转换、声母/韵母表、键位映射）
  与构建元信息；
* 方案数据（``SOURCE``）：``Lambda/ZiDB`` 单字表，提供键道 rank、笔画与读音
  （读音后面那个数是短码长度）—— 单字码、形码、原版首选全部由它推；
  以及上游 ``Lambda/Static/补充.txt`` 的纯形码段（部件不在 ZiDB 里）；
* 标准拼音词库：``词\t拼音\t权重``，构建时把拼音转成键道音码。
  默认 ``pinyin_simp.dict.yaml``（Rime 自带）；
  可用 ``--rime-ice DIR`` 引入 rime-ice 的 ``base`` / ``ext`` / ``others``；
* 纯权重词库：``词\t权重``（如 rime-ice ``tencent``），
  用单字表读音自动注音（``--rime-ice-tencent`` 启用）。

方案参数
--------
输出前缀、标题、数据目录、输出目录、纯形码段名来自
``--layout`` 指定的方案 ``layout.py``（``NAME`` / ``TITLE`` / ``SOURCE`` /
``OUT`` / ``SHAPE_SECTION``；相对路径按该文件所在目录解析）；
``source`` / ``out`` 可用命令行覆盖。

生成规则
--------
* 单字：全码（声母+韵母，2 键），ZiDB 短码长度为 1 的再加 1 键声母码；
* 词组（键道原版编码）：
  * 2 字：音音全码（如 我们 = ``wu mk``）；
  * 3 字：三个首字母（如 为什么 = ``w u m``）；
  * 4 字：四个首字母（如 万里长城 = ``w l y y``）；
  * 5 字以上：前三首 + 末一首（如 吃一堑长一智 = ``y f q ;``）。

码表里的 code 用**空格分隔音节**（每个字的全码/声母码是一个音节），
这样 prism 的音节表只有几百项，整词由音节序列组成；
不要写成无空格的长串，否则每个词都是独立音节，大数据量时 prism 会爆炸。

不再读取键道 CiDB：形码只做运行时筛选，词库使用标准拼音词库即可。

Use ``--help`` for options.
"""

import argparse
import os
import re
import sys

import flow_dict_lib as lib

# ---------------------------------------------------------------------------
# 布局表与方案参数：从方案仓库的 layout.py 读入（本脚本不读上游仓库）
#
# 布局表结构与拼音→音码编码在 flow_dict_lib 里（与 keytao 的转换器共用一份）。
# ---------------------------------------------------------------------------

LAYOUT = None
PY_TRANSFORM = {}
PY_SHENG = {}
PY_YUN = {}
JD_S2K = {}
JD_Y2K = {}
JD_B = {}
JD_S2K_YUN = {}
SHAPE_KEYS = ''


def load_layout(path):
    """读方案 ``layout.py``，布局表放进本模块全局名，返回构建元信息。

    ``SOURCE`` / ``OUT`` 若是相对路径，按 layout.py 所在目录解析。
    """
    global LAYOUT
    LAYOUT = lib.load_layout(path)
    for key in lib.LAYOUT_TABLES + lib.LAYOUT_OPTIONAL:
        globals()[key] = getattr(LAYOUT, key)
    globals()['SHAPE_KEYS'] = LAYOUT.SHAPE_KEYS
    return LAYOUT.meta


def transform_py(pinyin):
    return LAYOUT.transform_py(pinyin)


def normalize_py(pinyin):
    """拼音归一化（去声调、统一 ü 拼写），用于按读音对齐权重。"""
    return LAYOUT.normalize_py(pinyin)


def sheng(py):
    return LAYOUT.sheng(py)


def yun(py):
    return LAYOUT.yun(py)


def sheng_keys(s, y):
    return LAYOUT.sheng_keys(s, y)


def yun_keys(y):
    return LAYOUT.yun_keys(y)


def syllable_readings(py):
    """全拼 -> [(全码, 声母码)]；飞键给多条。"""
    return LAYOUT.syllable_readings(py)


def pinyin2sy(py):
    """全拼 -> 键道音码（双拼两码）的第一条，无法映射时返回 None。"""
    return LAYOUT.pinyin2sy(py)


def syllable_reading(py):
    """全拼 -> (全码, 声母码) 的第一条，无法映射时返回 None。"""
    return LAYOUT.syllable_reading(py)


def static_sound_code(code_str):
    """把静态码（如 ``<sh><i>k<e><丿><丶>``）中的音码部分提取出来。"""
    return LAYOUT.static_sound_code(code_str)


# 词库读写小工具（与 keytao 转换器共用）
parse_weight = lib.parse_weight
format_weight = lib.format_weight
iter_dict_rows = lib.iter_dict_rows


# ---------------------------------------------------------------------------
# 数据读取
# ---------------------------------------------------------------------------

def replace_tokens(code):
    """展开 ``<token>``：与上游 Lambda/JDTools.py 的 replace_static 同序
    （先笔画 JD_B，再韵母 JD_Y2K，再声母 JD_S2K）。"""
    for table in (JD_B, JD_Y2K, JD_S2K):
        for token, key in table.items():
            code = code.replace('<%s>' % token, key[0])
    return code


def is_private_use(char):
    """上游数据里的私用区字符（U+E000–U+F8FF 等）。

    键道自己的字库把这些码位映射到字形，别处（Rime / 网页 / 系统字体）只会显示成
    豆腐块。上游 ``补充.txt`` 里曾有一个 U+E818（「补充提示」段里首笔为折的那个
    部件，旁边是乛 / 氵 / 氺 / 乚），已经从 ``data/Lambda/Static/补充.txt`` 里删掉；
    这里保留过滤，是防以后重新导入上游数据又把它带回来。
    """
    cp = ord(char)
    return (0xE000 <= cp <= 0xF8FF or 0xF0000 <= cp <= 0xFFFFD or
            0x100000 <= cp <= 0x10FFFD)


def load_shape_entries(path, shape_section):
    """从上游 ``Lambda/Static/补充.txt`` 提取纯形码（笔形）条目：
    展开 ``<token>`` 后 code 全部是笔形键（上游 JD_B 的值）。

    包括上游纯形码段（配置 shape_section）、「补充提示」「部首偏旁」；该段里每个码
    只保留第一条（本体，如 又a）——多出来的（如 识o）原来排在
    shape.dict 的 2 号位，现在交给次简表（flow_secondary.lua）管。
    私用区元素（见 ``is_private_use``）直接丢掉：码表里的「元素 → 键位」只有在
    某个字的笔顺里出现那个元素时才会被查到，而 ZiDB 笔顺表里没有任何字引用它们
    （上游 补充.txt 的 U+E818 就是这种死条目）。
    返回 (entries, extras)，extras 只用于打印。
    """
    entries = []
    extras = []
    seen = set()
    first_of_code = set()
    section = ''
    in_header = False
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line:
                continue
            if line.startswith('#'):
                section = line.lstrip('#').strip()
                continue
            if line == '---':
                in_header = True
                continue
            if line == '...':
                in_header = False
                continue
            if in_header:
                continue
            row = line.split('\t')
            if len(row) < 2 or not row[0] or not row[1]:
                continue
            if any(is_private_use(c) for c in row[0]):
                continue
            code = replace_tokens(row[1].strip())
            if not code or not re.fullmatch('[%s]+' % re.escape(SHAPE_KEYS), code):
                continue
            if section == shape_section:
                if code in first_of_code:
                    extras.append((row[0], code))
                    continue
                first_of_code.add(code)
            key = (row[0], code)
            if key in seen:
                continue
            seen.add(key)
            entries.append((row[0], code))
    return entries, extras


# 上游 Lambda/PinyinConsts.py 的常用字范围（「原版首选」只在这些字里挑）
COMMON_RANGE = [
    (0x30, 0x40),      # Digits
    (0x41, 0x5B),      # Upper letters
    (0x61, 0x7B),      # Lower letters
    (0x2E80, 0x2EF4),  # Radical
    (0x3000, 0x3040),  # Punct
    (0x3100, 0x312E),  # Bopomofo
    (0x31C0, 0x31E4),  # Stroke
    (0x3400, 0x4DB6),  # CJK-A
    (0x4E00, 0x9FD1),  # CJK
    (0xF900, 0xFACF),  # CJK-Compat
    (0xFF00, 0xFFEF),  # Full-width
]


def is_common(char):
    """常用字判定：与上游 Lambda/PinyinConsts.py 的 COMMON_RANGE 一致。"""
    code = ord(char)
    return any(lo <= code < hi for lo, hi in COMMON_RANGE)


def first_choice(zidb, shapes):
    """原版首选：和上游 Lambda/JDTools.py 的 zi2codes 等价。

    每个字的每个读音出一条码：短码 = 全码[:读音长度]（读音长度是 ZiDB 里
    那个数，只有小于全码长度时才出短码），全码本身 ≥3 键、与这里的
    1/2 键首选无关。把所有条目按 (码, rank) 排完，同一个码里第一个
    **常用字**就是上游 danzi.dict.yaml 在该码上的首选 —— 实测 405 个
    1/2 键码全部一致，所以构建不需要读上游那份 danzi（它本来就是
    ZiDB 排出来的），也不需要在 data/ 里放一份。

    返回 {码: 首选字}。
    """
    entries = []
    for char, rank, pinyins in zidb:
        shape = shapes.get(char, '')
        if not shape:
            continue
        by_sy = {}
        for py, length in pinyins:
            if length <= 0:          # 键道标记的无理读音
                continue
            r = syllable_reading(py)
            if not r:
                continue
            sy, _init = r
            if sy not in by_sy or length < by_sy[sy]:
                by_sy[sy] = length
        for sy, length in by_sy.items():
            full = sy + shape
            if length < len(full):
                entries.append((full[:length], rank, char))

    entries.sort(key=lambda e: (e[0], e[1]))       # 与上游同序（稳定排序）
    first = {}
    for code, _rank, char in entries:
        if len(code) not in (1, 2) or not is_common(char):
            continue
        first.setdefault(code, char)
    return first


def load_dict(path, default_weight=1.0):
    """读取标准拼音词库。

    返回 ``(char_w, char_reading_w, words, vocab, stats)``：
      * char_w[char] = 字频（取各读音最大）
      * char_reading_w[(char, 拼音)] = 按读音的字频（取各来源最大）
      * words = [(word, [pinyin...], weight)]  （带拼音）
      * vocab = [(word, weight)]               （无拼音，靠单字表自动注音）
    """
    char_w = {}
    char_reading_w = {}
    words = []
    vocab = []
    stats = {'rows': 0, 'chars': 0, 'words': 0, 'vocab': 0, 'skipped': 0}
    for row in iter_dict_rows(path):
        if not row or not row[0]:
            continue
        text = row[0]
        pinyin = None
        weight = None
        if len(row) >= 3:
            if row[1]:
                pinyin = row[1]
            if row[2]:
                weight = parse_weight(row[2])
        elif len(row) == 2:
            if row[1]:
                w = parse_weight(row[1])
                if w is not None:
                    weight = w
                else:
                    pinyin = row[1]
        stats['rows'] += 1
        if len(text) == 1:
            w = weight if weight is not None else default_weight
            if pinyin:
                syllables = pinyin.split()
                if len(syllables) == 1:
                    char_w[text] = max(char_w.get(text, 0.0), w)
                    key = (text, normalize_py(syllables[0]))
                    char_reading_w[key] = max(
                        char_reading_w.get(key, 0.0), w)
            else:
                char_w[text] = max(char_w.get(text, 0.0), w)
            stats['chars'] += 1
            continue
        if pinyin:
            syllables = pinyin.split()
            if len(syllables) != len(text):
                stats['skipped'] += 1
                continue
            words.append(
                (text, syllables, weight if weight is not None else default_weight))
            stats['words'] += 1
        else:
            vocab.append(
                (text, weight if weight is not None else default_weight))
            stats['vocab'] += 1
    return char_w, char_reading_w, words, vocab, stats


def load_zidb(path):
    """读取 ZiDB/通常.txt：单字、rank 与读音（含键道短码长度）。"""
    chars = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            row = line.rstrip('\n').split('\t')
            if len(row) < 5:
                continue
            char = row[0]
            rank = int(row[1])
            pinyins = []
            for i in range(3, len(row) - 1, 2):
                pinyins.append((row[i], int(row[i + 1])))
            chars.append((char, rank, pinyins))
    return chars


def load_zidb_shapes(path):
    """char -> 键道形码（ZiDB 第 3 列的 4 个笔画映射成笔形键）。"""
    shapes = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            row = line.rstrip('\n').split('\t')
            if len(row) < 5:
                continue
            code = ''.join(JD_B.get(s, '') for s in row[2])
            if code:
                shapes[row[0]] = code
    return shapes


def load_zidb_static(path):
    entries = []
    if not os.path.exists(path):
        return entries
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            row = line.split('\t')
            if len(row) != 2:
                continue
            code = static_sound_code(row[1])
            if code:
                entries.append((row[0], code))
    return entries


# ---------------------------------------------------------------------------
# 音码生成
# ---------------------------------------------------------------------------

# 单字最长原码（音码 2 + 形码 4）——权重分层的层数
MAX_CHAR_CODE = 6


def build_char_codes(zidb, zidb_static, char_w, char_reading_w, default_weight,
                     shapes=None):
    """char -> [(全码, 声母码, 权重, 短码长度)]，含 static 音码与多音字。

    权重 = 原版短码长度分层（短码恒大于长码）：

        weight = MAX_CHAR_CODE + 1 - 短码长度

    短码长度是 ZiDB 读音后那个数（原版 danzi 给该读音的简码长度）。原版同一
    音码下「码短的在前面」（碘 dmv 排在 玷 dmvv、靛 dmvvo 前面），所以短码
    长度小的层恒大于大的；同一层内不再按字频重排——这个单字表就是照本方案
    布局生成的，层内保持原样即可。

    层内唯一要调的是**重码**：音码 + 形码完全一样的字（如 咒/呪），按 ZiDB
    的 rank 排（rank 小的在前）；微调量 < 0.5，不会跨层。
    """
    shapes = shapes or {}
    raw = {}
    dup_frac = {}
    by_full = {}
    for char, rank, pinyins in zidb:
        shape = shapes.get(char, '')
        if not shape:
            continue
        for py, jd_w in pinyins:
            if jd_w <= 0:
                continue
            for full, _init in syllable_readings(py):
                by_full.setdefault(full + shape, []).append((rank, char))
    for code, items in by_full.items():
        if len(items) < 2:
            continue
        items.sort()
        n = len(items)
        for i, (_rank, char) in enumerate(items):
            dup_frac[(code, char)] = 0.5 * (n - i) / (n + 1)

    for char, _rank, pinyins in zidb:
        shape = shapes.get(char, '')
        for py, jd_w in pinyins:
            if jd_w <= 0:  # 键道标记的无理读音
                continue
            variants = syllable_readings(py)
            if not variants:
                continue
            layer = MAX_CHAR_CODE + 1 - min(jd_w, MAX_CHAR_CODE)
            for full, init in variants:
                weight = layer + dup_frac.get((full + shape, char), 0.0)
                raw.setdefault(char, []).append((full, init, weight, jd_w))
    for char, code in zidb_static:
        raw.setdefault(char, []).append((code, code[0], default_weight, None))

    result = {}
    for char, options in raw.items():
        best = {}
        for full, init, weight, jd_w in options:
            key = (full, init)
            if weight > best.get(key, (0.0, None))[0]:
                best[key] = (weight, jd_w)
        result[char] = [(full, init, weight, jd_w)
                        for (full, init), (weight, jd_w) in best.items()]
    return result


def word_code(reading, abbrev_weight, length_weight=1.0):
    """reading = [(全码, 声母码)...] -> (码, 权重系数) 或 None（见 flow_dict_lib）。"""
    return lib.word_code(reading, abbrev_weight, length_weight)


def word_codes(reading, abbrev_weight, length_weight=1.0):
    """reading = 每个字一个变体列表 -> [(码, 系数)]（飞键全组合）。"""
    return LAYOUT.word_codes(reading, abbrev_weight, length_weight)


def syllables_reading(syllables):
    """每个音节的可选读音列表（飞键会多选）。"""
    return lib.syllables_reading(LAYOUT, syllables)


def auto_reading(word, char_codes):
    """无拼音词：逐字取最高频读音（同频取先出现的那条）。"""
    reading = []
    for ch in word:
        options = char_codes.get(ch)
        if not options:
            return None
        full, init = max(options, key=lambda o: o[2])[:2]
        reading.append([(full, init)])
    return reading


# ---------------------------------------------------------------------------
# 码表生成
# ---------------------------------------------------------------------------

def build_danzi(char_codes):
    """单字表：每个读音出全码；短码长度为 1 的读音再加一条 1 键声母码。"""
    entries = {}
    for char, options in char_codes.items():
        for full, init, weight, jd_w in options:
            key = (char, full)
            entries[key] = max(entries.get(key, 0.0), weight)
            if init and jd_w == 1:
                key = (char, init)
                entries[key] = max(entries.get(key, 0.0), weight)
    return entries


def align_original_first(danzi, first):
    """把原版 1 键/2 键首选字的权重抬到同码第一（其余顺序不动）。

    返回 (调整数, 缺字数)；缺字指原版首选在 ZiDB 读音里对不上。
    """
    per_code = {}
    for (text, code), weight in danzi.items():
        per_code.setdefault(code, []).append((text, weight))
    changed = 0
    missing = 0
    for code, char in first.items():
        entries = per_code.get(code)
        if not entries:
            missing += 1
            continue
        weights = dict(entries)
        if char not in weights:
            missing += 1
            continue
        others = max((w for t, w in entries if t != char), default=0.0)
        if weights[char] <= others:
            danzi[(char, code)] = others + 1.0
            changed += 1
    return changed, missing


def build_cizu(word_entries, vocab_entries, char_codes,
               abbrev_weight, default_weight, length_weight=1.0):
    entries = {}
    skipped = {'pinyin': 0, 'vocab': 0}

    def add(word, code, weight):
        if not code:
            return
        key = (word, code)
        if weight > entries.get(key, 0.0):
            entries[key] = weight

    def add_reading(word, reading, weight):
        for code, scale in word_codes(reading, abbrev_weight, length_weight):
            add(word, code, weight * scale)

    for word, syllables, weight in word_entries:
        weight = weight or default_weight
        reading = syllables_reading(syllables)
        if not reading:
            skipped['pinyin'] += 1
            continue
        add_reading(word, reading, weight)

    for word, weight in vocab_entries:
        weight = weight or default_weight
        reading = auto_reading(word, char_codes)
        if not reading:
            skipped['vocab'] += 1
            continue
        add_reading(word, reading, weight)

    return entries, skipped


# ---------------------------------------------------------------------------
# 写出
# ---------------------------------------------------------------------------

def danzi_header(name, title):
    return (
        '# %s 单字码表（音码全码；短码长度 1 的附 1 键声母码）\n'
        '# 由 tools/build_flow_dict.py 自动生成，请勿手工修改\n'
        '---\n'
        'name: %s.danzi\n'
        'version: "1.1"\n'
        'sort: by_weight\n'
        'use_preset_vocabulary: false\n'
        '...\n' % (title, name))


def shape_dict_header(name, title, shape_section, shape_keys):
    return (
        '# %s 纯形码表（shape，%s）\n'
        '# 由 tools/build_flow_dict.py 从上游 补充.txt「%s/补充提示/部首偏旁」提取\n'
        '---\n'
        'name: %s.shape\n'
        'version: "1.0"\n'
        'sort: original\n'
        'use_preset_vocabulary: false\n'
        '...\n' % (title, shape_keys, shape_section, name))


def variant_header(name, title, variant, note):
    return (
        '# %s 词库（%s）\n'
        '# 由 tools/build_flow_dict.py 自动生成，请勿手工修改\n'
        '# 2 字：音音全码；3/4 字：首字母；5 字以上：前三首 + 末一首\n'
        '---\n'
        'name: %s.%s\n'
        'version: "1.2"\n'
        'sort: by_weight\n'
        'use_preset_vocabulary: false\n'
        'import_tables:\n'
        '  - %s.danzi\n'
        '  - %s.shape\n'
        '...\n' % (title, note, name, variant, name, name))


def write_dict(path, header, entries, scale=1.0):
    ordered = sorted(entries.items(), key=lambda kv: (kv[0][1], -kv[1], kv[0][0]))
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(header)
        for (text, code), weight in ordered:
            f.write('%s\t%s\t%s\n' % (text, code, format_weight(weight * scale)))
    return len(ordered)


# ---------------------------------------------------------------------------
# 主流程
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
    return {
        'char': os.path.join(cn, '8105.dict.yaml'),
        'words': [
            os.path.join(cn, 'base.dict.yaml'),
            os.path.join(cn, 'ext.dict.yaml'),
            os.path.join(cn, 'others.dict.yaml'),
        ],
        'tencent': os.path.join(cn, 'tencent.dict.yaml'),
    }


def main():
    home = os.path.expanduser('~')

    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--layout', required=True, metavar='FILE',
                        help='方案 layout.py（布局表与构建元信息），相对路径按其所在目录解析')
    parser.add_argument('--source', default=None,
                        help='数据快照路径（默认取 layout.py 的 SOURCE）')
    parser.add_argument('--pinyin-simp', default=None,
                        help='pinyin_simp.dict.yaml 路径')
    parser.add_argument('--no-pinyin-simp-words', action='store_true',
                        help='（已废弃，忽略）')
    parser.add_argument('--words', action='append', default=[],
                        metavar='PATH',
                        help='额外标准拼音词库（词/拼音/权重），可重复')
    parser.add_argument('--rime-ice', default='/tmp/rime-ice', metavar='DIR',
                        help='rime-ice 仓库路径（默认 %(default)s；不存在则只生成 simp）')
    parser.add_argument('--rime-ice-tencent', action='store_true',
                        help='同时引入 rime-ice tencent（无拼音，自动注音）')
    parser.add_argument('--no-align-original', action='store_true',
                        help='不按原版 1 键/2 键首选调整单字权重')
    parser.add_argument('--out', default=None,
                        help='输出目录（默认取 layout.py 的 OUT）')
    parser.add_argument('--weight-scale', type=float, default=1.0,
                        help='全局词频缩放（默认 %(default)s）')
    parser.add_argument('--abbrev-weight', type=float, default=1.0,
                        help='简码（3 字以上首字母）词频系数（默认 %(default)s）')
    parser.add_argument('--length-weight', type=float, default=0.35,
                        help='词组按字数降权底数：每多 1 字乘一次（默认 %(default)s，1 = 不降权）')
    parser.add_argument('--default-weight', type=float, default=1.0,
                        help='无权重条目的默认词频（默认 %(default)s）')
    args = parser.parse_args()
    meta = load_layout(args.layout)
    source = args.source or meta['source']
    out = args.out or meta['out']
    name = meta['name']
    title = meta['title']

    pinyin_simp = args.pinyin_simp or find_pinyin_simp(home)
    if not pinyin_simp or not os.path.exists(pinyin_simp):
        sys.exit('找不到 pinyin_simp.dict.yaml，请用 --pinyin-simp 指定')

    # ---------------- 数据源 ----------------
    # 字频/读音权重来自所有来源（danzi 两个变体共用）；词条按变体分开：
    #   simp = pinyin_simp 词（+ --words）
    #   ice  = rime-ice base/ext/others（+ tencent、+ --words）
    char_w = {}
    char_reading_w = {}

    def read_source(path):
        cw, crw, words, vocab, stats = load_dict(path, args.default_weight)
        for ch, w in cw.items():
            char_w[ch] = max(char_w.get(ch, 0.0), w)
        for key, w in crw.items():
            char_reading_w[key] = max(char_reading_w.get(key, 0.0), w)
        print('  %s  (%d 行, 词 %d, 无拼音 %d, 跳过 %d)'
              % (path, stats['rows'], stats['words'],
                 stats['vocab'], stats['skipped']))
        return words, vocab

    print('数据源：')
    simp_words, simp_vocab = read_source(pinyin_simp)

    extra_words, extra_vocab = [], []
    for path in args.words:
        if not os.path.exists(path):
            sys.exit('找不到词库：%s' % path)
        w, v = read_source(path)
        extra_words.extend(w)
        extra_vocab.extend(v)

    ice_words, ice_vocab = [], []
    if args.rime_ice and os.path.isdir(args.rime_ice):
        ice = rime_ice_files(args.rime_ice)
        if os.path.exists(ice['char']):
            read_source(ice['char'])  # 只取字频
        for path in ice['words']:
            if os.path.exists(path):
                w, v = read_source(path)
                ice_words.extend(w)
                ice_vocab.extend(v)
        if args.rime_ice_tencent and os.path.exists(ice['tencent']):
            w, v = read_source(ice['tencent'])
            ice_words.extend(w)
            ice_vocab.extend(v)
    ice_ready = bool(ice_words)
    if not ice_ready:
        print('  未找到 rime-ice 词库（%s），只生成 simp 词库' % args.rime_ice)

    # --words 追加词库两个变体都加
    simp_words.extend(extra_words)
    simp_vocab.extend(extra_vocab)
    ice_words.extend(extra_words)
    ice_vocab.extend(extra_vocab)

    print('  字频 %d 字' % len(char_w))

    zidb_path = os.path.join(source, 'Lambda', 'ZiDB', '通常.txt')
    zidb = load_zidb(zidb_path)
    shapes = load_zidb_shapes(zidb_path)
    zidb_static = load_zidb_static(
        os.path.join(source, 'Lambda', 'ZiDB', '静态.txt'))

    char_codes = build_char_codes(zidb, zidb_static, char_w,
                                  char_reading_w, args.default_weight, shapes)
    danzi = build_danzi(char_codes)
    if args.no_align_original:
        print('原版首选对齐：已关闭')
    else:
        first = first_choice(zidb, shapes)
        changed, missing = align_original_first(danzi, first)
        print('原版首选对齐：%d 个码（调整 %d，缺字 %d）'
              % (len(first), changed, missing))
    shape_dict, shape_extras = load_shape_entries(
        os.path.join(source, 'Lambda', 'Static', '补充.txt'),
        meta['shape_section'])
    if shape_extras:
        print('%s段多出来的条目（交给次简表 flow_secondary.lua）：%s'
              % (meta['shape_section'],
                 ' '.join(t + c for t, c in shape_extras)))

    os.makedirs(out, exist_ok=True)
    scale = args.weight_scale
    print('词频缩放系数 %.6g；节奏码 ×%.6g；按字数降权 ×%.6g/字'
          % (scale, args.abbrev_weight, args.length_weight))

    n1 = write_dict(os.path.join(out, '%s.danzi.dict.yaml' % name),
                    danzi_header(name, title), danzi, scale)
    shape_path = os.path.join(out, '%s.shape.txt' % name)
    with open(shape_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# %s 期望形码表（ZiDB 前 4 笔画 -> %s）\n'
                % (title, SHAPE_KEYS))
        for char, code in sorted(shapes.items()):
            f.write('%s\t%s\n' % (char, code))

    # 纯形码表（shape）：上游 补充.txt 的纯形码条目，保持原顺序
    shape_dict_path = os.path.join(out, '%s.shape.dict.yaml' % name)
    with open(shape_dict_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(shape_dict_header(name, title, meta['shape_section'],
                                  SHAPE_KEYS))
        for text, code in shape_dict:
            f.write('%s\t%s\t1\n' % (text, code))

    # 旧版生成物（cizu / 单一主码表）清理掉，避免混淆
    for stale in ('%s.cizu.dict.yaml' % name, '%s.dict.yaml' % name):
        p = os.path.join(out, stale)
        if os.path.exists(p):
            os.remove(p)

    variants = [('simp', 'pinyin_simp', simp_words, simp_vocab)]
    if ice_ready:
        variants.append(('ice', 'rime-ice', ice_words, ice_vocab))
    for variant, note, words, vocab in variants:
        cizu, skipped = build_cizu(words, vocab, char_codes,
                                   args.abbrev_weight, args.default_weight,
                                   args.length_weight)
        path = os.path.join(out, '%s.%s.dict.yaml' % (name, variant))
        n = write_dict(path, variant_header(name, title, variant, note),
                       cizu, scale)
        print('词库 %s：%d 条（无法注音：拼音词 %d，自动注音 %d）'
              % (variant, n, skipped['pinyin'], skipped['vocab']))

    print('单字 %d 条，纯形码 %d 条，期望形码 %d 字' % (n1, len(shape_dict), len(shapes)))


if __name__ == '__main__':
    main()
