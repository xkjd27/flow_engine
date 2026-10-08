#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""「流」方案词库构建的公共部分：布局表、拼音→音码编码、词库读写小工具。

两个构建脚本共用这里，避免各写一份重复逻辑：

* ``build_flow_dict.py``           27/27C・流：从拼音词库造音码、按词频排；
* ``keytao_table_to_flow_dict.py`` 键道・函流：键道6 原版码表 + 冰/袖珍词库。

布局表
------
布局表是一个 ``Layout`` 对象，字段与方案仓库的 ``layout.py`` 一一对应：

* 必需：``PY_TRANSFORM``（拼音特例归一化）、``PY_SHENG``（零声母判定）、
  ``PY_YUN``（韵母归一化）、``JD_S2K``（声母→键位）、``JD_Y2K``（韵母→键位）、
  ``JD_B``（笔画→笔形键）；
* 可选：``JD_S2K_YUN``（声母随韵母换键 + 飞键，键道6 的 zh/ch 用）：
  ``{声母: [(键位, '韵母 列表'), ...]}``，键位串写多个字母 = 这些韵母下
  多个键位都可以（飞键）。

``JD_S2K`` / ``JD_Y2K`` 的值是**键位串**：单键就是普通键位，多键就是飞键
（如键道6 的 ``'uang': 'mx'``）。

音码编码
--------
``Layout.syllable_readings(py)`` 把全拼变成 ``[(全码, 声母码)]``（飞键给多条）；
``Layout.word_codes(reading)`` 按键道词组规则把每个字的读音组合成词码：

* 2 字：音音全码（如 我们 = ``wu mk``）；
* 3/4 字：各字首键；
* 5 字以上：前三首 + 末一首。
"""

import importlib.util
import os
import re
import sys

LAYOUT_TABLES = ('PY_TRANSFORM', 'PY_SHENG', 'PY_YUN',
                 'JD_S2K', 'JD_Y2K', 'JD_B')
LAYOUT_OPTIONAL = ('JD_S2K_YUN',)
LAYOUT_META = ('NAME', 'TITLE', 'SHAPE_SECTION', 'SOURCE', 'OUT')


class Layout:
    """一套布局：拼音归一化表 + 声母/韵母/笔形键位表（+ 可选飞键规则）。"""

    def __init__(self, tables, meta=None, name=''):
        self.name = name
        self.meta = meta or {}
        for key in LAYOUT_TABLES:
            setattr(self, key, tables[key])
        for key in LAYOUT_OPTIONAL:
            setattr(self, key, tables.get(key) or {})
        # 笔形键集合（去重保序）：纯形码条目/输入按它判定
        self.SHAPE_KEYS = ''.join(dict.fromkeys(self.JD_B.values()))

    # ---- 拼音归一化 ----

    def transform_py(self, pinyin):
        pinyin = pinyin.strip().lower()
        return self.PY_TRANSFORM.get(pinyin, pinyin)

    def normalize_py(self, pinyin):
        """拼音归一化（去声调、统一 ü 拼写），用于按读音对齐权重。"""
        pinyin = re.sub(r'\d+', '', pinyin.strip().lower())
        pinyin = pinyin.replace('ü', 'v').replace('u:', 'v')
        return self.transform_py(pinyin)

    def sheng(self, py):
        if py in self.PY_SHENG:
            return self.PY_SHENG[py]
        if py.startswith('zh'):
            return 'zh'
        if py.startswith('ch'):
            return 'ch'
        if py.startswith('sh'):
            return 'sh'
        return py[0] if py else ''

    def yun(self, py):
        if py in self.PY_YUN:
            return self.PY_YUN[py]
        if py.startswith(('zh', 'ch', 'sh')):
            return py[2:]
        return py[1:]

    # ---- 键位 ----

    def sheng_keys(self, s, y):
        """声母 s 与韵母 y 组合时的键位列表（可多个 = 飞键）。"""
        rules = self.JD_S2K_YUN.get(s)
        if rules:
            for keys, yuns in rules:
                if y in yuns.split():
                    return list(keys)
            return []                  # 规则表里没有的组合 = 不能拼
        key = self.JD_S2K.get(s)
        return list(key) if key else []

    def yun_keys(self, y):
        """韵母键位列表（值写多个字母 = 飞键）。"""
        return list(self.JD_Y2K.get(y, ''))

    # ---- 音码 ----

    def syllable_readings(self, py, fly=True):
        """全拼 -> [(全码, 声母码)]；飞键给多条（``fly=False`` 只留第一条）。

        全码 = 声母键 + 韵母键（每个可用键位都出一条）；声母码 = 声母键，
        词组简码（3 字以上首字母）用。无法映射时返回 []。
        """
        py = self.transform_py(py)
        if not py:
            return []
        s, y = self.sheng(py), self.yun(py)
        out = []
        for sk in self.sheng_keys(s, y):
            for yk in self.yun_keys(y):
                item = (sk + yk, sk)
                if item not in out:
                    out.append(item)
        return out if fly else out[:1]

    def pinyin2sy(self, py, fly=True):
        """全拼 -> 键道音码（双拼两码）的第一条，无法映射时返回 None。"""
        out = self.syllable_readings(py, fly)
        return out[0][0] if out else None

    def syllable_reading(self, py, fly=True):
        """全拼 -> (全码, 声母码) 的第一条，无法映射时返回 None。"""
        out = self.syllable_readings(py, fly)
        return out[0] if out else None

    def static_sound_code(self, code_str):
        """把静态码（如 ``<sh><i>k<e><丿><丶>``）中的音码部分提取出来。"""
        tokens = re.findall(r'<[^>]+>|[^<>]', code_str)
        out = []
        for token in tokens:
            if token.startswith('<'):
                name = token[1:-1]
                if name in self.JD_S2K:
                    out.append(self.JD_S2K[name][0])
                elif name in self.JD_Y2K:
                    out.append(self.JD_Y2K[name][0])
                else:              # 笔画等形码，音码部分结束
                    break
            else:
                if token in self.JD_S2K:
                    out.append(self.JD_S2K[token][0])
                elif token in self.JD_Y2K:
                    out.append(self.JD_Y2K[token][0])
                else:
                    break
        return ''.join(out) or None

    # ---- 词组 ----

    def word_codes(self, reading, abbrev_weight, length_weight=1.0, fly=True):
        """reading = 每个字一个 [(全码, 声母码)...] 变体列表 -> [(码, 系数)]。

        飞键会给一个字多个变体，这里把每个字的变体全组合都出出来（同码合并）。
        """
        combos = [()]
        for variants in reading:
            variants = variants if fly else variants[:1]
            if not variants:
                return []
            combos = [c + (v,) for c in combos for v in variants]
        out = {}
        for combo in combos:
            r = word_code(list(combo), abbrev_weight, length_weight)
            if r:
                out[r[0]] = max(out.get(r[0], 0.0), r[1])
        return sorted(out.items())


def from_tables(tables, name='', meta=None):
    """用一组表直接建 Layout（脚本内置布局用，如键道6）。"""
    return Layout(tables, meta=meta, name=name)


def load_layout(path):
    """读方案仓库的 ``layout.py``，返回 Layout（``meta`` 里是构建元信息）。

    ``SOURCE`` / ``OUT`` 若是相对路径，按 layout.py 所在目录解析。
    """
    path = os.path.abspath(path)
    if not os.path.exists(path):
        sys.exit('找不到布局表：%s（用 --layout 指定方案 layout.py）' % path)
    spec = importlib.util.spec_from_file_location('flow_layout', path)
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as err:
        sys.exit('布局表 %s 载入失败：%s' % (path, err))
    missing = [key for key in LAYOUT_TABLES + LAYOUT_META
               if not hasattr(module, key)]
    if missing:
        sys.exit('布局表 %s 缺少：%s' % (path, ' '.join(missing)))
    tables = {}
    for key in LAYOUT_TABLES:
        tables[key] = getattr(module, key)
    for key in LAYOUT_OPTIONAL:
        tables[key] = getattr(module, key, {})
    for name, table in (('JD_S2K', tables['JD_S2K']),
                        ('JD_Y2K', tables['JD_Y2K'])):
        for token, keys in table.items():
            if not isinstance(keys, str) or not keys:
                sys.exit('布局表 %s 的 %s[%r] 应为非空键位串'
                         % (path, name, token))

    base = os.path.dirname(path)
    meta = {}
    for key in LAYOUT_META:
        value = getattr(module, key)
        if not isinstance(value, str) or not value.strip():
            sys.exit('布局表 %s 的 %s 应为非空字符串' % (path, key))
        value = value.strip()
        if key in ('SOURCE', 'OUT') and not os.path.isabs(value):
            value = os.path.normpath(os.path.join(base, value))
        meta[key.lower()] = value
    return Layout(tables, meta=meta, name=meta.get('name', ''))


# ---------------------------------------------------------------------------
# 词组编码 / 词库读写小工具（不依赖具体布局）
# ---------------------------------------------------------------------------

def word_code(reading, abbrev_weight, length_weight=1.0):
    """reading = [(全码, 声母码)...] -> (码, 权重系数) 或 None。

    键道原版词组编码：
      n == 2  音音全码（如 我们 = wumk）
      n == 3  3 个首字母（如 为什么 = wum）
      n == 4  4 个首字母（如 万里长城 = wlyy）
      n >= 5  前 3 个首字母 + 末字首字母（如 吃一堑长一智 = yfq;）

    length_weight：词组按字数降权，每多 1 字乘一次（n=2 为基准）。
    """
    n = len(reading)
    if n == 2:
        return (''.join(f for f, _ in reading), 1.0)
    scale = abbrev_weight * length_weight ** (n - 2)
    if n in (3, 4):
        initials = [i for _, i in reading]
        if not all(initials):
            return None
        return (''.join(initials), scale)
    if n >= 5:
        head = [i for _, i in reading[:3]]
        tail = reading[-1][1]
        if not all(head) or not tail:
            return None
        return (''.join(head + [tail]), scale)
    return None


def syllables_reading(layout, syllables, fly=True):
    """每个音节的可选读音列表（飞键会多选）。"""
    reading = []
    for py in syllables:
        variants = layout.syllable_readings(py, fly)
        if not variants:
            return None
        reading.append(variants)
    return reading


def parse_weight(text):
    try:
        w = float(text)
    except ValueError:
        return None
    return w if w > 0 else 1.0


def format_weight(weight):
    if weight == int(weight):
        return str(int(weight))
    return ('%.6f' % weight).rstrip('0').rstrip('.')


def iter_dict_rows(path):
    """按行产出 Rime 词典条目（跳过 YAML 头与注释）。"""
    in_header = False
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            if line == '---':
                in_header = True
                continue
            if line == '...':
                in_header = False
                continue
            if in_header:
                continue
            yield line.split('\t')
