#!/bin/bash
# ===================================
# gpu-pcie.sh — PCIe 链路状态检查
# 用法: bash gpu-pcie.sh
# ===================================
set -e

echo "========== PCIe 链路检查 =========="
echo ""

nvidia-smi --query-gpu=index,name,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv | \
while IFS=',' read -r idx name gen width gen_max width_max; do
    # 去掉空格
    gen=$(echo "$gen" | xargs)
    width=$(echo "$width" | xargs)
    gen_max=$(echo "$gen_max" | xargs)
    width_max=$(echo "$width_max" | xargs)

    # 跳过标题行
    if [ "$idx" = "index" ]; then
        echo "  GPU  | 当前速率        | 最大支持        | 状态"
        echo "  -----|-----------------|-----------------|------"
        continue
    fi

    if [ "$gen" != "$gen_max" ] || [ "$width" != "$width_max" ]; then
        STATUS="⚠ 降速！"
    else
        STATUS="✓ 正常"
    fi

    printf "  GPU%-2s | Gen%-2s x%-2s        | Gen%-2s x%-2s        | %s\n" \
        "$idx" "$gen" "$width" "$gen_max" "$width_max" "$STATUS"
done

echo ""
echo "========== 完成 =========="
