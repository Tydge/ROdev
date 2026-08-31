#!/bin/zsh
SCRIPT_DIR="${0:A:h}"
"$SCRIPT_DIR/ro-control.sh" status
result=$?
echo
echo -n "按任意键关闭此窗口……"
read -k 1
echo
exit $result
