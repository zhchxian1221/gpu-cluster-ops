#!/bin/bash
# ===================================
# gpu-process.sh — GPU 进程查看
# 用法: bash gpu-process.sh
# ===================================
set -e

echo "========== GPU 进程 =========="
echo ""

PROC_OUTPUT=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null)

if [ -z "$PROC_OUTPUT" ]; then
    echo "  当前无进程使用 GPU"
else
    echo "  PID       进程名                        显存占用"
    echo "  --------  ----------------------------  ----------"
    echo "$PROC_OUTPUT" | while IFS=',' read -r pid name mem; do
        printf "  %-10s %-30s %s\n" "$(echo $pid | xargs)" "$(echo $name | xargs)" "$(echo $mem | xargs)"
    done

    # 找僵尸进程（占显存但利用率极低的情况）
    echo ""
    PID_LIST=$(echo "$PROC_OUTPUT" | awk -F',' '{print $1}' | xargs)
    if [ -n "$PID_LIST" ]; then
        echo "  进程总数: $(echo "$PROC_OUTPUT" | wc -l)"
    fi
fi

echo ""
echo "========== 完成 =========="
