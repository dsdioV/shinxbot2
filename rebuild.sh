#!/bin/bash
# ==============================================================================
# shinxbot2 部署重建工具
#   位置: /opt/projects/shinxbot2/rebuild.sh
#   归属: 由框架仓的部署分支(origin/test)跟踪
#
# 设计要点：
#   1. 拉取前校验「当前分支 == 配置分支」，一律 --ff-only；
#      已跟踪文件有未提交改动时直接拒绝执行
#   2. 重编前把线上 .so 备份到 /opt/projects/shinxbot2-backups/so/<时间戳>/
#   3. 构建缓存的清理在【容器内】执行 —— build/ 由容器内 root 创建，宿主
#      用户删不动，旧版在宿主侧 rm -rf 一直静默失败（因此一直在吃陈旧缓存）
#   4. 逐插件判定编译结果，不再依赖 make_all.sh —— 它的 compile_cmake() 最后
#      一句是 `cd ../..`，该命令成功会吞掉 make 的失败，整体退出码恒为 0
#   5. 部署语义（避免"编译失败反而把线上能用的删掉"）：
#        · 编译成功        -> 覆盖框架里的 .so
#        · 编译失败        -> 保留框架里现有的旧 .so
#        · 插件已不在仓库  -> 删掉框架里对应的 .so
#   6. 支持非交互: bash rebuild.sh 1|2|3
#
# 构建资源：插件编译走独立的 docker run（compose run 不支持 --memory）。
#   容器内存上限默认 2G、并行度 2。注意框架服务的 mem_limit 是 1G：早期用
#   1G + 4 路并行编 random_color 会 OOM（cc1plus: Killed），故构建容器单独
#   放宽，不改动服务本身的限额。
#
# 注意: 本插件仓已按需裁剪（保留清单见 bot 的 config/core/module_load.json），
#       不再跟随上游全量功能集；上游改动按文件取用，不做整体 merge。
# ==============================================================================

set -e

# ==================== 配置区 ====================
FRAMEWORK_DIR="/opt/projects/shinxbot2"
FRAMEWORK_REMOTE="origin"
FRAMEWORK_BRANCH="test"

PLUGINS_DIR="/opt/projects/shinxbot2-plugins"
PLUGINS_REMOTE="origin"
PLUGINS_BRANCH="test"

BACKUP_ROOT="/opt/projects/shinxbot2-backups"
BACKUP_KEEP=10

BUILD_JOBS=2          # 并行编译的插件数
BUILD_MEM="2g"        # 构建容器内存上限（独立于框架服务的 1G 限额）
# ===============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_dirs() {
    [ -d "$FRAMEWORK_DIR" ] || { echo -e "${RED}错误: 框架目录不存在 $FRAMEWORK_DIR${NC}"; exit 1; }
    [ -d "$PLUGINS_DIR" ]   || { echo -e "${RED}错误: 插件目录不存在 $PLUGINS_DIR${NC}"; exit 1; }
    echo -e "${GREEN}目录检查通过${NC}"
}

# 当前分支
repo_branch() { git -C "$1" rev-parse --abbrev-ref HEAD; }

# 分支必须与配置一致，否则拒绝拉取（防止跨分支合并制造历史债）
require_branch() {
    local cur
    cur="$(repo_branch "$1")"
    if [ "$cur" != "$2" ]; then
        echo -e "${RED}错误: $3 当前在分支 '$cur'，配置要求 '$2'${NC}"
        echo -e "${YELLOW}先手动切到正确分支，或修改本脚本配置区。${NC}"
        exit 1
    fi
}

# 只检查已跟踪文件的改动；未跟踪杂物不算
require_clean() {
    local dirty
    dirty="$(git -C "$1" status --porcelain --untracked-files=no)"
    if [ -n "$dirty" ]; then
        echo -e "${RED}错误: $2 工作区有未提交改动，拒绝自动拉取${NC}"
        echo "$dirty"
        echo -e "${YELLOW}先提交或 stash，然后重跑。${NC}"
        exit 1
    fi
}

pull_repo() {  # dir remote branch name
    require_branch "$1" "$3" "$4"
    require_clean  "$1" "$4"
    echo -e "${YELLOW}>>> 拉取 $4 ($2/$3)...${NC}"
    git -C "$1" fetch "$2"
    git -C "$1" merge --ff-only "$2/$3"
    echo -e "${GREEN}$4 已更新: $(git -C "$1" log --oneline -1)${NC}"
}

# 重编前备份线上 .so，给「重建把线上跑着的东西换掉」留一个回滚点
backup_libs() {
    local stamp dest
    stamp="$(date +%Y%m%d-%H%M%S)"
    dest="$BACKUP_ROOT/so/$stamp"
    mkdir -p "$dest/functions" "$dest/events"
    cp -a "$FRAMEWORK_DIR"/lib/functions/*.so "$dest/functions/" 2>/dev/null || true
    cp -a "$FRAMEWORK_DIR"/lib/events/*.so    "$dest/events/"    2>/dev/null || true
    echo -e "${GREEN}线上 .so 已备份: $dest${NC}"
    ls -1dt "$BACKUP_ROOT"/so/*/ 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -rf
    echo -e "${YELLOW}回滚: cp -a $dest/functions/*.so $FRAMEWORK_DIR/lib/functions/${NC}"
}

image_name() {
    local img
    img="$(docker compose config --images 2>/dev/null | head -1)"
    [ -n "$img" ] || img="shinxbot2-shinx-bot"
    echo "$img"
}

build_plugins() {
    local img
    img="$(image_name)"
    echo -e "${YELLOW}>>> 编译插件 (镜像=$img, 并行度=$BUILD_JOBS, 内存上限=$BUILD_MEM)...${NC}"

    docker run --rm \
        --memory="$BUILD_MEM" \
        -e BUILD_JOBS="$BUILD_JOBS" \
        -v "$FRAMEWORK_DIR":/workspace-framework \
        -v "$PLUGINS_DIR":/workspace-plugins \
        -w /workspace-plugins \
        "$img" bash -c '
            set -uo pipefail    # 故意不用 -e：逐插件收集失败，最后统一处理

            FAIL=/tmp/build_failures.txt
            LOGDIR=/workspace-framework/log/build
            : > "$FAIL"
            mkdir -p "$LOGDIR"

            # 1) 清理上一轮缓存与产物。必须在容器内做：build/ 是容器内 root
            #    建的，宿主用户 rm 会 Permission denied（旧版就是这样静默失败的）。
            rm -rf /workspace-plugins/functions/*/build /workspace-plugins/events/*/build
            rm -f  /workspace-plugins/lib/functions/*.so /workspace-plugins/lib/events/*.so
            echo "已清理构建缓存与旧产物"

            # 2) generate_cmake.py 生成的 CMakeLists 用的是相对 include
            #    ../../lib/shinxbot2-api/include；本机插件 checkout 的 submodule
            #    是空的，所以补三行指向框架目录的绝对 include。
            inject_includes() {
                for cmake_file in $(find . -name CMakeLists.txt); do
                    sed -i "1i include_directories(/workspace-framework/src)\ninclude_directories(/workspace-framework/lib/shinxbot2-api/include)\ninclude_directories(/workspace-framework/lib/cpp-httplib)" "$cmake_file"
                done
            }

            # 3) 单插件编译；失败记入 $FAIL，绝不静默通过
            build_one() {
                local d="$1" name rc
                name=$(basename "$d")
                (
                    cd "$d" && mkdir -p build && cd build &&
                    cmake -DCMAKE_BUILD_TYPE=Release .. >/dev/null 2>&1 &&
                    make -j1
                ) >"$LOGDIR/$name.log" 2>&1
                rc=$?
                if [ "$rc" -ne 0 ]; then
                    echo "$name" >> "$FAIL"
                    echo "  失败: $name"
                else
                    echo "  成功: $name"
                fi
            }
            export -f build_one
            export FAIL LOGDIR

            for kind in functions events; do
                cd "/workspace-plugins/$kind" || exit 1
                python3 generate_cmake.py >/dev/null
                inject_includes
                echo "--- 编译 $kind ---"
                find . -mindepth 1 -maxdepth 1 -type d -exec test -f {}/CMakeLists.txt \; -print \
                    | xargs -I{} -P "$BUILD_JOBS" bash -c "build_one \"\$@\"" _ {}
                cd /workspace-plugins || exit 1
            done

            # 4) 部署。三种情形分开处理，避免"编译失败反而把线上能用的删掉"
            sync_libs() {  # $1=kind  $2=仓库产物目录  $3=框架目录
                local kind="$1" src="$2" dst="$3" b name n_ok=0 n_kept=0 n_rm=0 f
                mkdir -p "$dst"
                for f in "$src"/*.so; do
                    [ -e "$f" ] || continue
                    cp -f "$f" "$dst"/ && n_ok=$((n_ok + 1))
                done
                for f in "$dst"/*.so; do
                    [ -e "$f" ] || continue
                    b=$(basename "$f"); name=${b#lib}; name=${name%.so}
                    if [ ! -d "/workspace-plugins/$kind/$name" ]; then
                        rm -f "$f"; echo "  移除（已不在仓库）: $b"; n_rm=$((n_rm + 1))
                    elif [ ! -e "$src/$b" ]; then
                        echo "  保留旧版（本次编译失败）: $b"; n_kept=$((n_kept + 1))
                    fi
                done
                echo "  $kind: 更新 $n_ok 个, 保留旧版 $n_kept 个, 移除 $n_rm 个"
            }
            sync_libs functions /workspace-plugins/lib/functions /workspace-framework/lib/functions
            sync_libs events    /workspace-plugins/lib/events    /workspace-framework/lib/events

            # 5) 失败汇总（构建日志留在框架 log/build/ 供排查）
            if [ -s "$FAIL" ]; then
                echo ""
                echo "==================== 警告 ===================="
                echo "以下插件本次编译失败，已保留线上旧版本 .so，未做任何替换："
                while read -r n; do
                    [ -n "$n" ] || continue
                    echo "  - $n   (日志: log/build/$n.log)"
                    tail -n 3 "$LOGDIR/$n.log" 2>/dev/null | sed "s/^/      /"
                done < "$FAIL"
                echo "其余插件已正常更新。"
                echo "=============================================="
            else
                echo "全部插件编译成功"
            fi
        '
    echo -e "${GREEN}插件编译完成${NC}"
}

build_framework() {
    echo -e "${YELLOW}>>> 编译框架...${NC}"

    docker compose run --rm shinx-bot bash -lc '
        set -e
        cd /workspace

        # build/ 同样是容器内 root 创建的，只能在容器内清理。
        # 但 build/shinxbot 正是线上运行的那个可执行文件，所以先暂存一份：
        # 编译失败就放回去，避免"编崩了连容器都起不来"。
        if [ -f ./build/shinxbot ]; then
            cp -a ./build/shinxbot /tmp/shinxbot.prev
            echo "已暂存当前二进制 -> /tmp/shinxbot.prev"
        fi

        rm -rf ./build

        if ! bash ./build.sh main; then
            echo "框架编译失败" >&2
            if [ -f /tmp/shinxbot.prev ]; then
                mkdir -p ./build
                cp -a /tmp/shinxbot.prev ./build/shinxbot
                echo "已恢复上一版二进制，服务仍可正常启动" >&2
            fi
            exit 1
        fi

        [ -x ./build/shinxbot ] || { echo "错误: 未生成 ./build/shinxbot" >&2; exit 1; }
    '
    echo -e "${GREEN}框架编译完成${NC}"
}

restart_container() {
    echo -e "${YELLOW}>>> 重启容器...${NC}"
    docker compose up -d --force-recreate
    echo -e "${GREEN}容器已重启${NC}"
}

show_menu() {
    echo ""
    echo "===================================="
    echo "      shinxbot2 重建工具"
    echo "===================================="
    echo "框架: $FRAMEWORK_REMOTE/$FRAMEWORK_BRANCH  ($(repo_branch "$FRAMEWORK_DIR"))"
    echo "插件: $PLUGINS_REMOTE/$PLUGINS_BRANCH  ($(repo_branch "$PLUGINS_DIR"))"
    echo "===================================="
    echo "1. 仅更新插件（拉取代码 + 编译 + 重启）"
    echo "2. 仅更新框架（拉取代码 + 编译 + 重启）"
    echo "3. 全量重编（拉取两者 + 编译两者 + 重启）"
    echo "0. 退出"
    echo "===================================="
    echo -n "请选择 [0-3]: "
}

run_action() {
    case "$1" in
        1)
            echo -e "${YELLOW}执行: 仅更新插件${NC}"
            pull_repo "$PLUGINS_DIR" "$PLUGINS_REMOTE" "$PLUGINS_BRANCH" "插件"
            backup_libs
            build_plugins
            restart_container
            echo -e "${GREEN}插件更新完成！${NC}"
            ;;
        2)
            echo -e "${YELLOW}执行: 仅更新框架${NC}"
            pull_repo "$FRAMEWORK_DIR" "$FRAMEWORK_REMOTE" "$FRAMEWORK_BRANCH" "框架"
            backup_libs
            build_framework
            restart_container
            echo -e "${GREEN}框架更新完成！${NC}"
            ;;
        3)
            echo -e "${YELLOW}执行: 全量重编${NC}"
            pull_repo "$FRAMEWORK_DIR" "$FRAMEWORK_REMOTE" "$FRAMEWORK_BRANCH" "框架"
            pull_repo "$PLUGINS_DIR" "$PLUGINS_REMOTE" "$PLUGINS_BRANCH" "插件"
            backup_libs
            build_plugins
            build_framework
            restart_container
            echo -e "${GREEN}全量重编完成！${NC}"
            ;;
        0)
            echo "退出"
            exit 0
            ;;
        *)
            echo -e "${RED}无效输入，请输入 0-3${NC}"
            return 1
            ;;
    esac
}

main() {
    check_dirs

    # 非交互模式: bash rebuild.sh 1|2|3
    if [ "$#" -gt 0 ]; then
        run_action "$1"
        exit 0
    fi

    while true; do
        show_menu
        read -r choice || exit 0
        run_action "$choice" || true
    done
}

main "$@"
