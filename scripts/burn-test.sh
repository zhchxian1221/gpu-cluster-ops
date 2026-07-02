#!/bin/bash
# GPU 压力测试脚本
# 用法: bash burn-test.sh [持续时间秒数] [GPU数量]
# 示例: bash burn-test.sh 300     # 跑 5 分钟，用所有 GPU
#       bash burn-test.sh 120 2   # 跑 2 分钟，只用前 2 张 GPU

DURATION=${1:-300}      # 默认 5 分钟
GPU_COUNT=${2:-$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)}

echo "========================================"
echo "  GPU Burn 压力测试"
echo "  持续时间: ${DURATION} 秒"
echo "  GPU 数量: ${GPU_COUNT}"
echo "  开始时间: $(date)"
echo "========================================"
echo ""
echo "⚠️  测试期间 GPU 将满载，预期温度 70-85°C"
echo "   在另一个终端执行: watch -n 1 nvidia-smi"
echo ""

# 检查 gpu_burn 是否存在
if [ ! -f "./gpu_burn" ]; then
    echo "gpu_burn 未找到，正在编译..."
    cd /tmp
    git clone https://github.com/wilicc/gpu-burn.git 2>/dev/null
    cd gpu-burn
    make -j$(nproc)
    echo "编译完成"
    cd "$OLDPWD"
    cp /tmp/gpu-burn/gpu_burn ./gpu_burn
fi

# 运行压力测试
CUDA_VISIBLE_DEVICES=$(seq -s ',' 0 $((GPU_COUNT - 1))) ./gpu_burn "$DURATION"

EXIT_CODE=$?
echo ""
echo "========================================"
echo "  测试结束: $(date)"
if [ $EXIT_CODE -eq 0 ]; then
    echo "  结果: PASS (无错误)"
else
    echo "  结果: FAIL (错误码: $EXIT_CODE)"
fi
echo "========================================"
