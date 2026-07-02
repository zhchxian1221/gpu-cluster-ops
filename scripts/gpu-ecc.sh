#!/bin/bash
# ===================================
# gpu-ecc.sh — ECC 错误和退役显存页检查
# 用法: bash gpu-ecc.sh
# 注意: RTX 3090/4090 无 ECC，输出 [N/A]
# ===================================
set -e

echo "========== ECC 错误检查 =========="
echo ""

# ECC 错误
nvidia-smi --query-gpu=index,name,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total --format=csv | \
while IFS=',' read -r idx name corrected uncorrected; do
    corrected=$(echo "$corrected" | xargs)
    uncorrected=$(echo "$uncorrected" | xargs)

    if [ "$idx" = "index" ]; then
        echo "  GPU  | 可纠正错误 | 不可纠正错误 | 判断"
        echo "  -----|-----------|-------------|------"
        continue
    fi

    if [ "$uncorrected" = "[N/A]" ]; then
        JUDGE="无 ECC (消费卡)"
    elif [ "$uncorrected" != "0" ] && [ -n "$uncorrected" ]; then
        JUDGE="❌ 不可纠正错误! RMA!"
    elif [ "$corrected" != "0" ] && [ "$corrected" != "[N/A]" ]; then
        JUDGE="⚠ 有可纠正错误，观察趋势"
    else
        JUDGE="✓ 正常"
    fi

    printf "  GPU%-2s | %-10s | %-12s | %s\n" "$idx" "$corrected" "$uncorrected" "$JUDGE"
done

# 退役显存页
echo ""
echo "--- 退役显存页 ---"
nvidia-smi --query-gpu=index,retired_pages.single_bit_ecc.count,retired_pages.double_bit.count --format=csv | \
while IFS=',' read -r idx single double; do
    single=$(echo "$single" | xargs)
    double=$(echo "$double" | xargs)

    if [ "$idx" = "index" ]; then continue; fi

    if [ "$single" = "[N/A]" ]; then
        echo "  GPU$idx: 无 ECC，不适用"
    elif [ "$single" = "0" ] && [ "$double" = "0" ]; then
        echo "  GPU$idx: 无退役页 ✓"
    else
        echo "  GPU$idx: 单bit=$single 双bit=$double ← ⚠ 有退役页!"
    fi
done

echo ""
echo "========== 完成 =========="
