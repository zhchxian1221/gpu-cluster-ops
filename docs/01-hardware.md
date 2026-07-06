# 模块 01：GPU 硬件与驱动

> GPU 架构、选型、驱动安装、nvidia-smi 深度解读、MIG、拓扑分析。

---

## GPU 架构核心概念

| 概念 | 解释 | 运维要点 |
|------|------|----------|
| CUDA Core | GPU 基本计算单元 | 决定 FP32 算力 |
| Tensor Core | 矩阵运算加速硬件 | AI 训练/推理真正的算力来源 |
| 显存 (VRAM) | GPU 板载高速内存 | 决定能装多大的模型 |
| 显存带宽 | 每秒读取数据量 | 大模型推理的瓶颈通常是它 |
| NVLink | GPU 间直连通道 | 多卡训练不走 PCIe，延迟更低 |
| MIG | 一张物理 GPU 切成多份 | A100/H100 专有，推理必备 |
| Compute Capability | GPU 架构代号 | 决定了支持哪些 CUDA 特性 |

---

## 主流 GPU 选型速查

| GPU | 显存 | 带宽 | FP16(Tensor) | MIG | 场景 |
|-----|------|------|:---:|:---:|------|
| H100 SXM | 80GB HBM3 | 3.35 TB/s | 989 TFLOPS | ✅ | 大模型训练 |
| A100 SXM | 80GB HBM2e | 2.0 TB/s | 312 TFLOPS | ✅ | 训练+推理 |
| A10 | 24GB GDDR6 | 600 GB/s | 125 TFLOPS | ❌ | 小模型推理 |
| RTX 4090 | 24GB GDDR6X | 1.0 TB/s | 330 TFLOPS | ❌ | 实验 |
| RTX 3090 | 24GB GDDR6X | 936 GB/s | 142 TFLOPS | ❌ | 学习 |

---

## 驱动/CUDA/cuDNN 的关系

```
AI 程序 (PyTorch/TensorFlow/vLLM)
    ↓
cuDNN / NCCL / TensorRT    ← 加速库
    ↓
CUDA Toolkit (nvcc, libcudart) ← 开发工具包
    ↓
NVIDIA Driver (nvidia.ko)  ← 内核驱动
    ↓
GPU 硬件
```

**关键规则**：驱动版本决定了能装什么版本的 CUDA。CUDA Toolkit 版本 ≤ 驱动支持的 CUDA 版本上限。

---

## nvidia-smi 关键字段

| 字段 | 含义 | 关注点 |
|------|------|--------|
| Persistence-M | 持久模式 | AI 服务器必须 On |
| Temp | GPU 核心温度 | >85°C 告警 |
| Perf | 性能状态 P0-P12 | P0=满载, P8=空闲 |
| Pwr:Usage/Cap | 当前/上限功耗 | 接近上限=满载 |
| GPU-Util | SM 利用率 | **不含 Tensor Core** |
| Compute M. | 计算模式 | 容器场景保持 Default |
| MIG M. | MIG 模式 | A100/H100 推理标配 |

---

## 核心运维操作

```bash
# 持久模式
sudo nvidia-smi -pm 1

# GPU 拓扑
nvidia-smi topo -m

# MIG 启用/查看
sudo nvidia-smi -mig 1
nvidia-smi mig -lgip          # 看可用 profile
nvidia-smi mig -cgi 9,9 -C   # 创建 2 个 3g.40gb 实例
sudo nvidia-smi mig -dci && sudo nvidia-smi mig -dgi  # 销毁

# 锁频（避免性能抖动）
sudo nvidia-smi -ac 1215,1410

# PCIe 链路检查
nvidia-smi --query-gpu=index,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max --format=csv

# ECC 错误
nvidia-smi --query-gpu=index,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total --format=csv
```
