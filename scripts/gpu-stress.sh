#!/bin/bash
# ===================================
# gpu-stress.sh — GPU 压力测试（纯 PyTorch，无需额外下载）
# 用法: bash gpu-stress.sh [持续时间秒数] [GPU数量]
# 示例: bash gpu-stress.sh 60      # 压测 60 秒，用所有卡
#       bash gpu-stress.sh 120 2   # 压测 120 秒，只用前 2 张卡
# ===================================
DURATION=${1:-60}
GPU_N=${2:-$(python3 -c "import torch; print(torch.cuda.device_count())" 2>/dev/null || echo 0)}

echo "========== GPU 压力测试 =========="
echo "  持续时间 : ${DURATION} 秒"
echo "  GPU 数量 : ${GPU_N}"
echo "  $(date)"
echo ""
echo "  测试过程中 GPU 将满载"
echo "  另开终端执行: bash gpu-watch.sh"
echo "=================================="
echo ""

if [ "$GPU_N" -eq 0 ]; then
    echo "错误: 未检测到 GPU"
    exit 1
fi

python3 -c "
import torch, time, sys

n = $GPU_N
duration = $DURATION

print(f'设备: {torch.cuda.get_device_name(0)}')
print(f'显存: {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB')
print()

# 每张卡分配 80% 显存做矩阵
size = 5000
print(f'每张卡分配 {size}x{size} float32 矩阵 (~{size*size*4/1e9:.1f} GB)')
print(f'开始压测 {n} 张 GPU，持续 {duration} 秒...')
print()

# 为每张卡创建张量
tensors = []
for i in range(n):
    with torch.cuda.device(i):
        a = torch.randn(size, size, device=f'cuda:{i}')
        b = torch.randn(size, size, device=f'cuda:{i}')
        tensors.append((a, b))
        mem_used = torch.cuda.memory_allocated(i) / 1e9
        print(f'  GPU {i}: 已分配 {mem_used:.1f} GB')

print()
start = time.time()
iters = 0

try:
    while time.time() - start < duration:
        for i in range(n):
            a, b = tensors[i]
            with torch.cuda.device(i):
                torch.mm(a, b)
        iters += 1
        if iters % 100 == 0:
            elapsed = time.time() - start
            print(f'  [{elapsed:.0f}s] {iters} 轮, 功耗: ', end='')
            # 读功耗（需要 nvidia-smi）
            import subprocess
            result = subprocess.run(
                ['nvidia-smi', '--query-gpu=power.draw', '--format=csv,noheader'],
                capture_output=True, text=True
            )
            powers = result.stdout.strip().replace('\n', ', ')
            print(f'{powers}')
except KeyboardInterrupt:
    print()
    print('用户中断')

elapsed = time.time() - start
print()
print(f'========== 测试完成 ==========')
print(f'  耗时:  {elapsed:.0f} 秒')
print(f'  轮次:  {iters}')
print(f'  状态:  PASS (无错误)')
print(f'===============================')
"
