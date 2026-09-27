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
#   3. 所有构建缓存的清理都在【容器内】执行 —— build/ 由容器内 root 创建，
#      宿主用户删不动，旧版在宿主侧 rm -rf 一直静默失败（因此每次都在吃
#      陈旧缓存）
#   4. 部署 .so 采用「镜像」语义：插件仓是唯一事实来源，框架里多出来的旧
#      .so 会被清掉，否则删掉的插件会以陈旧 .so 的形式残留在框架里
#   5. 编译失败绝不部署：容器脚本带 set -e，且有产物数量自检
#   6. 支持非交互: bash rebuild.sh 1|2|3  （无参数才进菜单）
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

build_plugins() {
    echo -e "${YELLOW}>>> 编译插件...${NC}"

    docker compose run --rm \
        -v "$FRAMEWORK_DIR":/workspace-framework \
        -v "$PLUGINS_DIR":/workspace-plugins \
        shinx-bot bash -c '
            set -euo pipefail

            # 1) 清理上一轮缓存与产物。必须在容器内做：build/ 是容器内 root
            #    建的，宿主用户 rm 会 Permission denied（旧版就是这样静默失败的）。
            rm -rf /workspace-plugins/functions/*/build /workspace-plugins/events/*/build
            rm -f  /workspace-plugins/lib/functions/*.so /workspace-plugins/lib/events/*.so
            echo "已清理构建缓存与旧产物"

            # 2) generate_cmake.py 生成的 CMakeLists 用的是相对 include
            #    ../../lib/shinxbot2-api/include；本机插件 checkout 的 submodule
            #    是空的，所以补三行指向框架目录的绝对 include。
            #    （全新 clone --recurse-submodules 的话不需要这三行。）
            inject_includes() {
                for cmake_file in $(find . -name CMakeLists.txt); do
                    sed -i "1i include_directories(/workspace-framework/src)\ninclude_directories(/workspace-framework/lib/shinxbot2-api/include)\ninclude_directories(/workspace-framework/lib/cpp-httplib)" "$cmake_file"
                done
            }

            cd /workspace-plugins/functions
            python3 generate_cmake.py
            inject_includes
            bash ./make_all.sh

            cd /workspace-plugins/events
            python3 generate_cmake.py
            inject_includes
            bash ./make_all.sh

            # 3) 产物自检：某一类一个 .so 都没编出来就中止，
            #    绝不能把框架里现有的 .so 清空。
            for kind in functions events; do
                n=$(ls -1 /workspace-plugins/lib/$kind/*.so 2>/dev/null | wc -l)
                echo "编译产物 $kind: $n 个"
                [ "$n" -gt 0 ] || { echo "错误: $kind 没有产出任何 .so，中止部署" >&2; exit 1; }
            done

            # 4) 镜像式部署：先覆盖拷贝，再删掉框架里已无对应源的旧 .so
            sync_libs() {  # $1=源目录  $2=框架目标目录
                cp -f "$1"/*.so "$2"/
                for f in "$2"/*.so; do
                    [ -e "$f" ] || continue
                    b=$(basename "$f")
                    if [ ! -e "$1/$b" ]; then
                        rm -f "$f"
                        echo "已移除框架中多余的 $b"
                    fi
                done
            }
            mkdir -p /workspace-framework/lib/functions /workspace-framework/lib/events
            sync_libs /workspace-plugins/lib/functions /workspace-framework/lib/functions
            sync_libs /workspace-plugins/lib/events    /workspace-framework/lib/events
            echo "部署完成: functions=$(ls -1 /workspace-framework/lib/functions/*.so | wc -l), events=$(ls -1 /workspace-framework/lib/events/*.so | wc -l)"
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
