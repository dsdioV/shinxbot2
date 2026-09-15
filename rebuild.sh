#!/bin/bash
# ==============================================================================
# shinxbot2 部署重建工具
#   位置: /opt/projects/shinxbot2/rebuild.sh
#   归属: 由框架仓的部署分支(origin/test)跟踪
#
# 与旧版的差异（旧版是服务器上的未跟踪文件，改动无从回溯，且会把
# PLUGINS_REMOTE/test 合进一个叫 main 的分支）:
#   1. 拉取前校验「当前分支 == 配置分支」，不再把别的分支合进当前分支
#   2. 拉取一律 --ff-only；工作区有未提交改动时直接拒绝执行
#   3. 重编前把线上 .so 备份到 /opt/projects/shinxbot2-backups/so/<时间戳>/
#   4. 支持非交互: bash rebuild.sh 1|2|3  （无参数才进菜单）
#
# 注意: 插件仓的部署分支是 origin/test。wordle 的图片渲染改动目前在 fork 的
#       wordle 分支上（尚未并入 test），所以在并入之前，跑「更新插件」会把
#       线上 wordle 的图片功能换回旧版。
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

clean_cmake_cache() {
    local target_dir="$1"
    echo -e "${YELLOW}>>> 清理 CMake 缓存: ${target_dir}...${NC}"
    find "$target_dir" -type d -name build -exec rm -rf {} + 2>/dev/null || true
    find "$target_dir" -name CMakeCache.txt -delete 2>/dev/null || true
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

    clean_cmake_cache "$PLUGINS_DIR/functions"
    clean_cmake_cache "$PLUGINS_DIR/events"

    docker compose run --rm \
        -v "$FRAMEWORK_DIR":/workspace-framework \
        -v "$PLUGINS_DIR":/workspace-plugins \
        shinx-bot bash -c '
            # generate_cmake.py 生成的 CMakeLists 用的是相对 include
            # ../../lib/shinxbot2-api/include；本机插件 checkout 的 submodule
            # 是空的，所以这里补三行指向框架目录的绝对 include。
            # （全新 clone --recurse-submodules 的话不需要这三行。）
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

            mkdir -p /workspace-framework/lib/functions /workspace-framework/lib/events
            cp /workspace-plugins/lib/functions/*.so /workspace-framework/lib/functions/ 2>/dev/null || true
            cp /workspace-plugins/lib/events/*.so /workspace-framework/lib/events/ 2>/dev/null || true
        '
    echo -e "${GREEN}插件编译完成${NC}"
}

build_framework() {
    echo -e "${YELLOW}>>> 清理框架 build 缓存...${NC}"
    clean_cmake_cache "$FRAMEWORK_DIR"

    echo -e "${YELLOW}>>> 编译框架...${NC}"
    docker compose run --rm shinx-bot bash -lc 'cd /workspace && bash ./build.sh main'
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
