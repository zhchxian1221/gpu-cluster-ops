#!/bin/bash
# ===================================
# gpu-info.sh — GPU 基本信息概览
# 用法: bash gpu-info.sh
# ===================================
set -e

echo "========== GPU 基本信息 =========="

# 驱动
echo ""
echo "--- 驱动 ---"
nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1

# CUDA 上限
echo ""
echo "--- 驱动支持的 CUDA 上限 ---"
nvidia-smi | grep "CUDA Version" | awk '{print $9}'

# GPU 清单
echo ""
echo "--- GPU 清单 ---"
nvidia-smi --query-gpu=index,name,memory.total --format=csv

# GPU 数量
COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
echo ""
echo "GPU 数量: $COUNT"

echo ""
echo "========== 完成 =========="
