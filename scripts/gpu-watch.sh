#!/bin/bash
# ===================================
# gpu-watch.sh — GPU 实时监控
# 用法: bash gpu-watch.sh [刷新间隔秒数]
# 示例: bash gpu-watch.sh 2
# Ctrl+C 退出
# ===================================
INTERVAL=${1:-1}

echo "========== GPU 实时监控 (每 ${INTERVAL}s 刷新, Ctrl+C 退出) =========="
echo ""
echo "  GPU 功耗(W) 温度(°C) SM(%) 显存(%) 编码(%) 解码(%) 核心MHz 显存MHz"
echo "  --- -------- -------- ----- ------- ------- ------- ------- -------"

nvidia-smi dmon -s pucvmet -d "$INTERVAL"
