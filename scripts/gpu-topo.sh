#!/bin/bash
# ===================================
# gpu-topo.sh — GPU 拓扑和 NUMA 亲和性
# 用法: bash gpu-topo.sh
# ===================================
set -e

echo "========== GPU 拓扑分析 =========="
echo ""

# GPU 间连接矩阵
echo "--- GPU/NIC 互联矩阵 ---"
nvidia-smi topo -m

echo ""
echo "--- 连接类型说明 ---"
echo "  NV12 = NVLink x12 (600+ GB/s)  最快"
echo "  NODE = 同 NUMA 节点 (~100 GB/s)"
echo "  SYS  = 跨 NUMA 节点 (~100 GB/s，更高延迟)"
echo "  PXB  = PCIe Switch 桥接        较慢"
echo "  PIX  = 同 PCIe Switch 下        最慢"
echo ""

# NUMA 亲和性
echo "--- NUMA 亲和性 ---"
nvidia-smi --query-gpu=index,name,numa.memory_affinity --format=csv | \
while IFS=',' read -r idx name numa; do
    if [ "$idx" = "index" ]; then continue; fi
    echo "  GPU$idx ($name) → NUMA 节点: $(echo $numa | xargs)"
done

echo ""
echo "========== 完成 =========="
