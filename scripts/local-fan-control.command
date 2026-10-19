#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
# 打包到 Contents/Resources；动态参数只通过位置参数传入固定的 root 引导脚本。
app_root="$(cd "$(dirname "$0")/../.." && pwd)"
helper="$app_root/Contents/MacOS/ErmiFanHelper"
# 密码输入前固定指纹；root 只运行经系统 codesign 核对的私有副本。
plan="$("$helper" --local-plan "$app_root")"
read -r client_hash helper_hash <<< "$plan"
IFS= read -r -d '' bootstrap <<'BOOTSTRAP' || true
set -eu
source=$1
hash=$2
mode=$3
app=$4
client=$5
user_id=$6
case "$hash" in *[!0-9a-f]*|'') exit 65;; esac
[ "${#hash}" -eq 40 ] || exit 65
stage=$(/usr/bin/mktemp -d /private/var/root/ermi-install.XXXXXX)
trap '/bin/rm -r "$stage"' EXIT
/bin/cp -X "$source" "$stage/ErmiFanHelper"
/bin/chmod -N "$stage/ErmiFanHelper"
/bin/chmod 700 "$stage/ErmiFanHelper"
# codesign 的 -R 默认读取文件；等号前缀明确表示内联规则，缺失时会误作路径。
/usr/bin/codesign --verify --strict -R "=identifier \"app.ermi.fan-helper\" and cdhash H\"$hash\"" "$stage/ErmiFanHelper"
if [ "$mode" = install ]; then
    "$stage/ErmiFanHelper" --install-local "$app" "$client" "$hash" "$user_id"
else
    "$stage/ErmiFanHelper" --uninstall-local
fi
BOOTSTRAP
mode=install
[[ "$(basename "$0")" != "UninstallLocalFanControl.command" ]] || mode=uninstall
user_id="$(/usr/bin/id -u)"
if [[ "${1:-}" == --gui ]]; then
    # osascript 只执行固定脚本，所有路径与引导脚本均作为 argv 并用 quoted form 转义。
    # 管理员密码由系统验证窗口接收，Ermi 不读取、不保存。
    set +e
    /usr/bin/osascript -e 'on run argv
        set commandText to "/bin/sh -c " & quoted form of item 1 of argv & " sh"
        repeat with i from 2 to count of argv
            set commandText to commandText & " " & quoted form of item i of argv
        end repeat
        try
            do shell script commandText with administrator privileges
        on error errorText number errorNumber
            if errorNumber is -128 then return "ERMI_AUTH_CANCELLED"
            error errorText number errorNumber
        end try
    end run' "$bootstrap" "$helper" "$helper_hash" "$mode" "$app_root" "$client_hash" "$user_id"
    exit $?
fi
# 保留开发者手动入口；App 始终走上面的图形化授权分支。
if [[ "$mode" == uninstall ]]; then
    echo '将停止并卸载 Ermi 本机风扇服务；预设保留。'
    read -r -p '输入 UNINSTALL 确认，或直接回车取消：' answer
    [[ "$answer" == UNINSTALL ]] || exit 0
else
    echo '将安装 Ermi 本机风扇服务；安装不会应用预设。'
    read -r -p '输入 INSTALL 确认，或直接回车取消：' answer
    [[ "$answer" == INSTALL ]] || exit 0
fi
/usr/bin/sudo /bin/sh -c "$bootstrap" sh "$helper" "$helper_hash" "$mode" "$app_root" "$client_hash" "$user_id"
