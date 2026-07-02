# GPU 运维命令速查表

> 覆盖日常 90% 场景。每条命令可直接复制使用。

---

## 一、基础信息

```bash
# GPU 型号、驱动、CUDA 版本
nvidia-smi

# GPU 数量
nvidia-smi -L | wc -l

# 每张 GPU 详细信息
nvidia-smi -q
```

---

## 二、健康巡检（最常用，直接跑）

```bash
# 一句话：核心指标一览
nvidia-smi --query-gpu=index,name,temperature.gpu,power.draw,power.limit,utilization.gpu,memory.used,memory.total --format=csv

# GPU 温度（>85°C 告警）
nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader

# 功耗（接近 limit 说明满载）
nvidia-smi --query-gpu=power.draw,power.limit --format=csv,noheader

# 显存使用
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader

# 谁在用 GPU
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
```

---

## 三、硬件状态排查

```bash
# PCIe 链路——看有没有降速
nvidia-smi --query-gpu=index,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv
# current < max → 降速了，检查物理连接/BIOS

# ECC 错误——看显存有没有翻车
nvidia-smi --query-gpu=index,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,retired_pages.single_bit_ecc.count,retired_pages.double_bit.count --format=csv
# uncorrected > 0 → 严重，考虑 RMA
# 3090/4090 无 ECC，显示 [N/A]

# 降频原因——看性能为什么低
nvidia-smi --query-gpu=index,clocks_throttle_reasons.active --format=csv,noheader
# 非零 = 有降频
# 常见值：0x4=功耗上限 0x400=软件过热 0x800=硬件过热

# 退役显存页——永久性损坏
nvidia-smi -q -d RETIRED_PAGES
# >0 说明显存有永久坏块，不可逆

# GPU 拓扑——多卡通信路径
nvidia-smi topo -m
```

---

## 四、XID 错误——GPU 的"蓝屏"代码

```bash
# 查最近的 XID 错误
dmesg | grep -i "NVRM.*Xid"

# 常见 XID：
# 13  = 图形引擎异常（硬件可能损坏）
# 31  = 显存页错误
# 48  = 双 bit ECC 错误（显存硬件问题）
# 74  = NVLink 错误
# 79  = GPU fell off the bus（PCIe 掉卡，检查电源/散热）
# 92  = 高频双 bit ECC
# 119 = 温度超限
```

---

## 五、实时监控

```bash
# 每秒刷新（看实时变化）
nvidia-smi dmon -s pucvmet -d 1
# p=功耗 u=利用率 c=频率 v=ECC m=显存 e=温度 t=PCIe吞吐

# 记录到文件（事后分析）
nvidia-smi dmon -s pucvmet -d 10 -o TD > /tmp/gpu_dmon.csv &

# watch 方式（最简单，但信息少）
watch -n 1 nvidia-smi
```

---

## 六、GPU 进程管理

```bash
# 谁在用哪些 GPU
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

# 查特定 PID 的详情
nvidia-smi --query-compute-apps=pid,process_name,used_gpu_memory --format=csv | grep 12345

# 找出占用 GPU 但不干活的僵尸进程
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv | awk -F',' '$3 ~ /^ 0 /'

# 强制杀掉占 GPU 的进程（⚠️ 慎用）
kill -9 $(nvidia-smi --query-compute-apps=pid --format=csv,noheader | head -1)

# 杀所有 GPU 进程（⚠️ 非常慎用）
nvidia-smi --query-compute-apps=pid --format=csv,noheader | xargs -r kill -9
```

---

## 七、压力测试

```bash
# === 方式 1：PyTorch 就地压测（不需要下载任何工具）===
python3 -c "
import torch, time
size = 5000
a = torch.randn(size, size, device='cuda')
b = torch.randn(size, size, device='cuda')
print('Burning...')
start = time.time()
while time.time() - start < 60:
    torch.mm(a, b)
print('Done, no errors')
"

# === 方式 2：全卡同时压测 ===
python3 -c "
import torch, time
n = torch.cuda.device_count()
print(f'Burning {n} GPUs for 60s...')
tensors = [torch.randn(5000,5000,device=f'cuda:{i}') for i in range(n)]
start = time.time()
while time.time() - start < 60:
    for i in range(n):
        torch.mm(tensors[i], tensors[i])
print('Done')
"
```

---

## 八、CUDA/cuDNN/NCCL 版本速查

```bash
# 驱动版本（决定 CUDA 上限）
nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1

# 驱动支持的 CUDA 版本上限
nvidia-smi | grep "CUDA Version"

# 系统 CUDA Toolkit 版本
nvcc --version 2>/dev/null | grep release || echo "nvcc 未安装"

# PyTorch 自带的 CUDA 版本
python3 -c "import torch; print(torch.version.cuda)" 2>/dev/null || echo "PyTorch 未安装"

# cuDNN 版本
python3 -c "import torch; print(torch.backends.cudnn.version())" 2>/dev/null || echo "PyTorch 未安装"

# NCCL 版本
python3 -c "import torch; print(torch.cuda.nccl.version())" 2>/dev/null || echo "检查失败"

# GPU 是否可用（最基础验证）
python3 -c "import torch; print(f'GPU: {torch.cuda.is_available()}, Count: {torch.cuda.device_count()}')"
```

---

## 九、持久模式与计算模式

```bash
# 开持久模式（GPU 不休眠，必开）
sudo nvidia-smi -pm 1

# 关持久模式
sudo nvidia-smi -pm 0

# 查看持久模式状态
nvidia-smi -q -d PERFORMANCE | grep Persistence

# 计算模式
# 0=Default(多进程共享) 3=Exclusive_Process(单进程独占)
nvidia-smi -c 0   # 容器场景用 Default
```

---

## 十、DCGM（已装环境用）

```bash
# GPU 发现
dcgmi discovery -l

# 监控指定指标
dcgmi dmon -e 1001,1002,155,1009 -d 1
# 1001=SM利用率 1002=显存利用率 155=温度 1009=功耗

# 列出所有指标
dcgmi dmon --list
```

---

## 一键巡检脚本

```bash
#!/bin/bash
# 保存为 check-gpu.sh，每到一个 GPU 节点就跑一遍
echo "=== GPU 健康巡检 $(date) ==="
echo ""
echo "--- 设备信息 ---"
nvidia-smi --query-gpu=index,name,driver_version --format=csv
echo ""
echo "--- 温度/功耗/利用率 ---"
nvidia-smi --query-gpu=index,temperature.gpu,power.draw,power.limit,utilization.gpu,memory.used,memory.total --format=csv
echo ""
echo "--- PCIe 链路 ---"
nvidia-smi --query-gpu=index,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv
echo ""
echo "--- ECC 错误 ---"
nvidia-smi --query-gpu=index,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total --format=csv
echo ""
echo "--- XID 错误 ---"
dmesg 2>/dev/null | grep -i "NVRM.*Xid" | tail -5 || echo "  无 XID 错误"
echo ""
echo "--- GPU 进程 ---"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
echo ""
echo "=== 巡检完成 ==="
```
