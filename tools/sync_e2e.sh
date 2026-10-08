#!/bin/bash
# flow_engine 跨机同步 E2E 测试（真实 librime 1.16.1）
#
# 两台"机器" A/B 各有独立 user_data_dir 和 installation_id，共享一个
# sync_dir；用 probe 驱动引擎按键、调用 RimeSyncUserData，检查：
#   * 自有同步文件（<order>.sync.txt）被 backup_config_files 拷进 sync 目录
#   * userdb 快照里不再有我们的记录（不依赖 userdb 通道）
#   * 同步后另一台机器 load 时能合并（pin / 次简）
#   * 冲突按时间取新、移动/删除（墓碑）会传播
#   * 坏行不会崩、不破坏状态；远端文件只读；文件有界
#
# 用法：
#   1) 先编译 probe：
#      cc tools/rime_probe.c -I<librime>/src -o /tmp/rime_sync_probe \
#         /usr/lib64/librime.so.1 -Wl,-rpath,/usr/lib64
#   2) 准备一个已经部署好的 jd27c 用户目录（含 build/、词库文件、lua/），
#      默认 /tmp/rime_flow_test（TEST_USER_DIR 可覆盖）；
#   3) tools/sync_e2e.sh
# 可用环境变量：PROBE / TEST_USER_DIR / ENGINE_LUA / BASE_DIR / SCHEMA
# 注意：按键序列和候选词是 jd27c 的（`wu-` `we-` `w=` 等）。

set -u
E=${BASE_DIR:-/tmp/flow_sync_e2e}
P=${PROBE:-/tmp/rime_sync_probe}
ENGINE=${ENGINE_LUA:-$(cd "$(dirname "$0")/../lua" && pwd)}
SCHEMA=${SCHEMA:-xkjd27c_flow}
DB=$SCHEMA.order
PASS=0
FAIL=0

ck() { # ck <说明> <shell 条件>
    if eval "$2"; then
        PASS=$((PASS + 1)); echo "  ok   $1"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL $1"
    fi
}

probe() { local m=$1; shift; "$P" "$E/$m" "$@" 2>/dev/null; }
first() { probe "$1" "$2" | awk '/^ *1\. /{print $2; exit}'; }
commit_of() { probe "$1" "$2" | awk '/commit:/{print $2; exit}'; }
local_sync() { ls "$E/$1"/*.sync.txt 2>/dev/null | head -1; }
remote_sync() { ls "$E/shared/e2e-$1"/*.sync.txt 2>/dev/null | head -1; }
records() { grep -c "^v1" "$1" 2>/dev/null || echo 0; }
snaprecord() { # 快照文件里还有没有 fsync 记录（应该永远 0）
    grep -l "^fsync " "$E/shared/e2e-$1"/*.userdb.txt >/dev/null 2>&1 && echo 1 || echo 0
}

setup() {
    rm -rf "$E"
    mkdir -p "$E/shared"
    for m in A B; do
        mkdir -p "$E/$m"
        cp -r "${TEST_USER_DIR:-/tmp/rime_flow_test}"/* "$E/$m/" 2>/dev/null
        rm -rf "$E/$m/sync" "$E/$m"/*.userdb "$E/$m"/*.sync.txt \
               "$E/$m"/*.order.txt
        cp "$ENGINE"/*.lua "$E/$m/lua/"
        cat > "$E/$m/installation.yaml" <<EOF
distribution_code_name: rime_probe
distribution_name: Rime
distribution_version: 1.16.1
installation_id: "e2e-$m"
sync_dir: "$E/shared"
rime_version: 1.16.1
EOF
    done
}

setup
echo "== 0. 部署 + 基线"
probe A 'w' >/dev/null
probe B 'w' >/dev/null
ck "A 基线 w 第一是「我」" '[ "$(first A w)" = "我" ]'
ck "B 基线 w 第一是「我」" '[ "$(first B w)" = "我" ]'

echo "== 1. A 编辑：pin（wu-）+ 次简（wumk Tab）"
probe A 'wu-' >/dev/null
ck "A pin 后 w 第一是「握」" '[ "$(first A w)" = "握" ]'
ck "A 次简 Tab 上屏「我们」" '[ "$(commit_of A "wumk\t")" = "我们" ]'
ck "A 本地有同步文件" '[ -n "$(local_sync A)" ]'
ck "A 同步文件里有 pin 记录" '[ "$(records "$(local_sync A)")" -ge 2 ]'

echo "== 2. A 同步：自有文件进 sync 目录、userdb 快照干净"
probe A --sync | grep -q SYNC_OK
ck "sync 目录里有 A 的同步文件" '[ -n "$(remote_sync A)" ]'
ck "远端文件内容 = 本地文件" \
   'cmp -s "$(local_sync A)" "$(remote_sync A)"'
ck "userdb 快照里没有 fsync 记录" '[ "$(snaprecord A)" = 0 ]'

echo "== 3. B 同步 + load：pin / 次简都过来，A 的远端文件没被动"
HASH_A=$(md5sum "$(remote_sync A)" | awk '{print $1}')
probe B --sync | grep -q SYNC_OK
ck "B 合并后 w 第一是「握」" '[ "$(first B w)" = "握" ]'
ck "B 合并后 Tab 次简上屏「我们」" '[ "$(commit_of B "w\t")" = "我们" ]'
ck "B 没有改 A 的远端文件" \
   '[ "$(md5sum "$(remote_sync A)" | awk "{print \$1}")" = "$HASH_A" ]'

echo "== 4. 墓碑：A 删掉 pin，B 同步后也回到「我」"
probe A '\`w^=' >/dev/null
ck "A 删除后 w 第一回到「我」" '[ "$(first A w)" = "我" ]'
probe A --sync | grep -q SYNC_OK
ck "A 同步文件里有 unpin 记录" 'grep -q "unpin" "$(local_sync A)"'
probe B --sync | grep -q SYNC_OK
ck "B 同步后 w 第一也回到「我」" '[ "$(first B w)" = "我" ]'
ck "B 本地文件里也有 unpin 记录" 'grep -q "unpin" "$(local_sync B)"'

echo "== 5. 冲突：A 重新 pin，B 把它移到更深级别，A 同步后跟过去"
probe A 'wu-' >/dev/null
probe A --sync | grep -q SYNC_OK
probe B --sync | grep -q SYNC_OK
ck "B 重新拿到 pin：w 第一是「握」" '[ "$(first B w)" = "握" ]'
probe B 'w=' >/dev/null                       # 移到 wu|
probe B --sync | grep -q SYNC_OK
ck "B 移动后 wu 第一是「握」" '[ "$(first B wu)" = "握" ]'
probe A --sync | grep -q SYNC_OK
ck "A 同步后 w 第一不再是「握」" '[ "$(first A w)" != "握" ]'
ck "A 同步后 wu 第一是「握」" '[ "$(first A wu)" = "握" ]'

echo "== 6. 幂等：没有新编辑，再同步/load 文件不变"
F1=$(cat "$(local_sync A)")
probe A --sync | grep -q SYNC_OK
probe A 'w' >/dev/null
F2=$(cat "$(local_sync A)")
ck "同步 + load 后本地文件不变" '[ "$F1" = "$F2" ]'
ck "userdb 快照仍然干净" '[ "$(snaprecord A)" = 0 ]'

echo "== 7. 损坏：远端同步文件里塞坏行，B 同步 + load 不崩、好记录仍生效"
R=$(remote_sync A)
{
    printf '\n'
    printf '完全不是记录\n'
    printf 'v9\x1fpin\x1f词\x1fwumk|\x1f1\x1f\x1f1\x1fm\x1f1\n'
    printf 'v1\x1funknown\x1f词\x1f1\x1fm\x1f1\n'
    printf 'v1\x1fpin\x1f\x1fwumk|\x1f1\x1f\x1f1\x1fm\x1f1\n'
    printf 'v1\x1fpin\x1f词\x1f~recent\x1f1\x1f\x1f1\x1fm\x1f1\n'
    printf 'v1\x1fpin\x1f词\x1fnovert\x1f1\x1f\x1f1\x1fm\x1f1\n'
    printf 'v1\x1fpin\x1f词\x1fwumk|\x1fx\x1f\x1f1\x1fm\x1f1\n'
    printf 'v1\x1fpin\x1f词\x1fwumk|\x1f1\x1f\x1f1\x1fm\n'
} >> "$R"
probe B --sync | grep -q SYNC_OK
OUT=$(probe B 'w')
ck "带坏行同步/load 不崩（还能出候选）" 'echo "$OUT" | grep -q "1\. "'
ck "坏行之后有效记录仍生效：wu 第一是「握」" '[ "$(first B wu)" = "握" ]'
ck "坏 pin key（~recent）没进最近造词" '! echo "$OUT" | grep -q "~recent"'

echo "== 8. 有界：多轮同步/load 后文件行数不涨"
N1=$(records "$(local_sync B)")
probe B --sync | grep -q SYNC_OK
probe B 'w' >/dev/null
probe B --sync | grep -q SYNC_OK
N2=$(records "$(local_sync B)")
ck "B 本地文件行数不变（$N1 -> $N2）" '[ "$N1" = "$N2" ]'

echo "== 9. 升级 bootstrap：同步关着编辑的老数据，开启后第一次同步带出去"
ck "开始前 B 的 w 第一是「我」" '[ "$(first B w)" = "我" ]'
cat > "$E/A/$SCHEMA.custom.yaml" <<YAML
patch:
  flow_order/sync: false
YAML
probe A 'we-' >/dev/null          # pin 我的@w|，此时不写同步记录
rm -f "$E/A/$SCHEMA.custom.yaml"
ck "关同步时 pin 仍然生效（A 的 w 第一是「我的」）" \
   '[ "$(first A w)" = "我的" ]'
probe A --sync | grep -q SYNC_OK  # load 时 bootstrap 出记录，再同步
probe B --sync | grep -q SYNC_OK
ck "bootstrap 同步后 B 的 w 第一也是「我的」" '[ "$(first B w)" = "我的" ]'
ck "B 本地文件里出现 bootstrap 的 pin 记录" \
   'grep -q "pin" "$(local_sync B)"'

echo
echo "共 $((PASS + FAIL)) 项，$FAIL 项失败"
[ "$FAIL" = 0 ]
