#!/bin/bash
# ===================================
# gpu-version.sh — GPU 软件栈版本检查
# 用法: bash gpu-version.sh
# ===================================
set -e

echo "========== GPU 软件栈版本 =========="
echo ""

# 驱动
DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
echo "  驱动              : ${DRIVER:-未安装}"

# 驱动支持的 CUDA 上限
CUDA_MAX=$(nvidia-smi 2>/dev/null | grep "CUDA Version" | awk '{print $9}')
echo "  CUDA 上限(驱动)   : ${CUDA_MAX:-未知}"

# CUDA Toolkit
NVCC=$(nvcc --version 2>/dev/null | grep "release" | awk '{print $6}' | tr -d ',')
echo "  CUDA Toolkit      : ${NVCC:-未安装}"

# PyTorch
TORCH_VER=$(python3 -c "import torch; print(torch.__version__)" 2>/dev/null || echo "")
TORCH_CUDA=$(python3 -c "import torch; print(torch.version.cuda)" 2>/dev/null || echo "")
if [ -n "$TORCH_VER" ]; then
    echo "  PyTorch           : $TORCH_VER (自带 CUDA $TORCH_CUDA)"
else
    echo "  PyTorch           : 未安装"
fi

# cuDNN
CUDNN=$(python3 -c "import torch; print(torch.backends.cudnn.version())" 2>/dev/null || echo "")
if [ -n "$CUDNN" ]; then
    MAJOR=$((CUDNN / 1000))
    MINOR=$(((CUDNN % 1000) / 100))
    PATCH=$((CUDNN % 100))
    echo "  cuDNN             : ${MAJOR}.${MINOR}.${PATCH} (PyTorch 自带)"
else
    echo "  cuDNN             : 未检测到"
fi

# NCCL
NCCL=$(python3 -c "import torch; print(torch.cuda.nccl.version())" 2>/dev/null || echo "")
if [ -n "$NCCL" ]; then
    echo "  NCCL              : $NCCL"
else
    echo "  NCCL              : 未安装"
fi

# GPU 数量
GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
echo "  GPU 数量          : $GPU_COUNT"

echo ""
echo "========== 版本兼容判断 =========="
echo ""

if [ -n "$NVCC" ] && [ -n "$CUDA_MAX" ]; then
    # 简单比较主版本号
    NVCC_MAJOR=$(echo "$NVCC" | cut -d'.' -f1)
    CUDA_MAX_MAJOR=$(echo "$CUDA_MAX" | cut -d'.' -f1)
    if [ "$NVCC_MAJOR" -le "$CUDA_MAX_MAJOR" ]; then
        echo "  ✓ CUDA Toolkit ($NVCC) ≤ 驱动上限 ($CUDA_MAX) — 兼容"
    else
        echo "  ✗ CUDA Toolkit ($NVCC) > 驱动上限 ($CUDA_MAX) — 不兼容！"
    fi
else
    echo "  (无法判断，缺少 nvcc 或驱动信息)"
fi

if [ -n "$TORCH_CUDA" ] && [ -n "$CUDA_MAX" ]; then
    TORCH_MAJOR=$(echo "$TORCH_CUDA" | cut -d'.' -f1)
    CUDA_MAX_MAJOR=$(echo "$CUDA_MAX" | cut -d'.' -f1)
    if [ "$TORCH_MAJOR" -le "$CUDA_MAX_MAJOR" ]; then
        echo "  ✓ PyTorch CUDA ($TORCH_CUDA) ≤ 驱动上限 ($CUDA_MAX) — 兼容"
    else
        echo "  ✗ PyTorch CUDA ($TORCH_CUDA) > 驱动上限 ($CUDA_MAX) — 不兼容！"
    fi
fi

echo ""
echo "========== 完成 =========="
