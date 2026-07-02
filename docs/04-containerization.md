# 模块 04：容器化 GPU

> GPU 容器化的完整理论与配置参考。

---

## 📖 概念

### 为什么 GPU 要走容器？

```
┌──────────────────────────────────────────────────────┐
│  问题：一台 GPU 服务器，10 个人要用                   │
│                                                      │
│  ❌ 裸金属方式：每人 SSH 上去装自己的环境              │
│     → CUDA 11.8 / 12.1 版本冲突                       │
│     → PyTorch 2.0 / 2.5 版本冲突                        │
│     → "谁把我装的 cuDNN 删了？"                        │
│     → 一个人 OOM，整台机器 GPU 不可用                   │
│                                                      │
│  ✅ 容器方式：每人一个镜像，隔离运行                    │
│     → 镜像内含 CUDA + PyTorch + 依赖，互不干扰          │
│     → 共享宿主机驱动（不在容器里装驱动）                 │
│     → 资源可限制：这个容器只能用 GPU 0，那个用 GPU 1    │
│     → OOM 只影响自己的容器                             │
└──────────────────────────────────────────────────────┘
```

### 架构：GPU 怎么透传到容器

```
┌─────────────────────────────────────────────┐
│  宿主机 (Ubuntu 22.04)                       │
│                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ 容器 A    │  │ 容器 B    │  │ 容器 C    │   │
│  │ CUDA 11.8 │  │ CUDA 12.1 │  │ CUDA 12.4 │   │
│  │ PyTorch   │  │ TF + NCCL │  │ vLLM      │   │
│  │ 2.0       │  │ 2.3       │  │ 0.6       │   │
│  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘   │
│        │              │              │          │
│        └──────────────┬┴──────────────┘          │
│                       │                          │
│       ┌───────────────┴──────────────────┐       │
│       │  nvidia-container-runtime        │       │
│       │  (OCI runtime 钩子)              │       │
│       │  容器启动时：                     │       │
│       │   1. 注入 /dev/nvidia* 设备节点   │       │
│       │   2. 注入 nvidia 相关 .so 库      │       │
│       │   3. 设置 CUDA_VISIBLE_DEVICES    │       │
│       └───────────────┬──────────────────┘       │
│                       │                          │
│       ┌───────────────┴──────────────────┐       │
│       │  nvidia.ko (内核驱动)            │       │
│       │  唯一，共享，不在容器里           │       │
│       └───────────────┬──────────────────┘       │
│                       │                          │
│       ┌───────────────┴──────────────────┐       │
│       │  GPU 0      GPU 1      GPU N     │       │
│       │  A100        A100       A100     │       │
│       └──────────────────────────────────┘       │
└──────────────────────────────────────────────────┘
```

**关键理解**：

- 驱动在内核层，所有容器共享。**容器里不需要装驱动**。
- `nvidia-container-runtime` 是 OCI 运行时的一个钩子（hook），容器启动时自动把 GPU 设备映射进去。
- 容器里的 CUDA 库版本和宿主机的驱动版本**必须兼容**：容器的 CUDA 版本 ≤ 驱动支持的最高 CUDA 版本。

### 三个关键组件

| 组件 | 包名 | 作用 |
|------|------|------|
| **nvidia-container-toolkit** | `nvidia-container-toolkit` | 主要包，包含运行时和 CLI 工具 |
| **nvidia-container-runtime** | 包含在上面的包里 | OCI 运行时，Docker 启动 GPU 容器时调用它 |
| **nvidia-container-toolkit-base** | `nvidia-container-toolkit-base` | 基础库，libnvidia-container |

---

## 🛠️ 配置参考

### 第一步：安装 NVIDIA Container Toolkit

```bash
# ===== 添加 NVIDIA 仓库（如果之前装 CUDA 时已经加过，跳过）=====
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
# curl 下载 GPG 密钥 → gpg 转换成二进制格式 → 保存到 keyrings 目录

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
# 下载源配置文件 → 插入签名信息 → 写入 apt 源目录

# ===== 安装 =====
sudo apt update
sudo apt install -y nvidia-container-toolkit
# 这个包会装：
#   /usr/bin/nvidia-container-runtime       ← OCI 运行时
#   /usr/bin/nvidia-container-runtime-hook  ← 容器启动钩子
#   /usr/bin/nvidia-container-toolkit       ← CLI 工具
#   /usr/bin/nvidia-ctk                     ← 配置工具

# ===== 配置 Docker 使用 nvidia-container-runtime =====
sudo nvidia-ctk runtime configure --runtime=docker
# nvidia-ctk runtime configure 做的事：
#   1. 修改 /etc/docker/daemon.json，注册 nvidia runtime
#   2. 让 Docker 知道存在一个叫 "nvidia" 的运行时选项

# ===== 重启 Docker 让配置生效 =====
sudo systemctl restart docker
```

### 第二步：验证配置

```bash
# Docker daemon.json 里应该有 nvidia runtime 配置
cat /etc/docker/daemon.json
```

生成的配置看起来是这样：

```json
{
    "runtimes": {
        "nvidia": {
            "args": [],
            "path": "nvidia-container-runtime"
        }
    }
}
```

```
解读：
  "runtimes"         → Docker 支持多运行时
  "nvidia"           → 新增了一个叫 "nvidia" 的运行时
  "path"             → 这个运行时的可执行文件路径
  "args": []         → 额外参数（空，默认行为即可）

当你 docker run --runtime=nvidia 时：
  Docker → 调用 nvidia-container-runtime → 注入 GPU 设备 → 启动容器
```

### 第三步：跑一个 GPU 容器验证

```bash
# 最简验证：跑 nvidia-smi 容器
docker run --rm --runtime=nvidia \
    nvidia/cuda:12.2-base-ubuntu22.04 \
    nvidia-smi

# 参数解读：
# docker run             → 创建并启动一个容器
# --rm                   → 容器退出后自动删除（不留垃圾）
# --runtime=nvidia       → 使用 NVIDIA 运行时（关键！不加这行看不到 GPU）
# nvidia/cuda:12.2-base  → NVIDIA 官方的 CUDA 基础镜像
#   - 12.2 = CUDA 12.2 版本
#   - base = 最小体积（不含 cuDNN/开发工具）
#   - ubuntu22.04 = 操作系统
#   - 完整标签还有：runtime（含cuDNN）、devel（含编译工具）
# nvidia-smi             → 容器启动后执行的命令
```

### 第四步：指定 GPU 分配

```bash
# 方式 1：用所有 GPU
docker run --rm --gpus all nvidia/cuda:12.2-base-ubuntu22.04 nvidia-smi

# 方式 2：只用 GPU 0
docker run --rm --gpus '"device=0"' nvidia/cuda:12.2-base-ubuntu22.04 nvidia-smi

# 方式 3：用 GPU 0 和 GPU 1（多卡任务）
docker run --rm --gpus '"device=0,1"' nvidia/cuda:12.2-base-ubuntu22.04 nvidia-smi

# 方式 4：限制可见 GPU + 显存
docker run --rm --gpus '"device=0"' \
    --memory=32g \
    --shm-size=8g \
    nvidia/cuda:12.2-base-ubuntu22.04 nvidia-smi
# --memory=32g    → 限制容器总 RAM（CPU内存）为 32GB
# --shm-size=8g   → 共享内存 8GB（PyTorch DataLoader 多进程共享数据用）
#                   ⚠️ Docker 默认 /dev/shm 只有 64MB，AI 训练必调大！
```

### 第五步：MIG 实例分配（A100/H100 才有）

```bash
# 前提：宿主机已经用 nvidia-smi -mig 1 启用了 MIG 并创建了实例

# 查看 MIG 实例
nvidia-smi -L
# 输出示例：
# GPU 0: NVIDIA A100-SXM4-80GB (UUID: GPU-xxx)
#   MIG 3g.40gb Device 0: (UUID: MIG-xxx-0)
#   MIG 3g.40gb Device 1: (UUID: MIG-xxx-1)

# 把容器绑定到特定的 MIG 实例
docker run --rm --gpus '"device=MIG-xxx-0"' \
    nvidia/cuda:12.2-base-ubuntu22.04 \
    nvidia-smi
# 容器里只能看到这个 MIG 实例
```

---

## 📁 项目文件

### 实战 Dockerfile：GPU 训练镜像

```dockerfile
# ============================================
# GPU 训练镜像 Dockerfile
# 用于 PyTorch 分布式训练任务
# 构建：docker build -t gpu-train:latest .
# 运行：docker run --gpus all gpu-train:latest
# ============================================

# ===== 基础镜像 =====
FROM nvidia/cuda:12.4-cudnn-devel-ubuntu22.04
# 标签解读：
#   12.4 = CUDA 12.4
#   cudnn = 包含 cuDNN
#   devel = 包含 nvcc 编译工具（需要编译 CUDA 扩展时用 devel）
#   ubuntu22.04 = 操作系统
# 镜像大小对比：
#   base:   ~250 MB（只有 CUDA 运行时）
#   runtime: ~600 MB（CUDA + cuDNN）
#   devel:  ~2.5 GB（CUDA + cuDNN + nvcc + 头文件 + 编译工具）

# ===== 设置工作目录 =====
WORKDIR /workspace
# 容器启动后默认进入这个目录

# ===== 安装系统依赖 =====
RUN apt update && apt install -y \
    python3.10 \
    python3-pip \
    git \
    wget \
    htop \
    vim \
    && rm -rf /var/lib/apt/lists/*
# rm -rf /var/lib/apt/lists/* → 清理 apt 缓存，减小镜像体积

# ===== 安装 Python 包 =====
RUN pip3 install --no-cache-dir \
    torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124 \
    transformers \
    datasets \
    wandb \
    tensorboard
# --no-cache-dir = 不缓存下载包，减小镜像体积

# ===== 设置环境变量 =====
ENV PYTHONUNBUFFERED=1 \
    NCCL_DEBUG=INFO \
    CUDA_HOME=/usr/local/cuda
# PYTHONUNBUFFERED=1 → Python 输出不缓冲，实时看到日志
# NCCL_DEBUG=INFO     → NCCL 输出信息级日志（排查通信问题用）
# CUDA_HOME           → 告诉编译工具 CUDA 装在哪

# ===== 默认入口 =====
CMD ["/bin/bash"]
# 如果没有指定命令，默认进入 bash
```

### 实战 docker-compose.yml：多卡训练编排

```yaml
version: '3.8'

# ============================================
# 多 GPU 训练任务编排
# 用法：docker compose up -d
# ============================================

services:
  train-gpu0:
    image: gpu-train:latest
    container_name: train-node0
    runtime: nvidia              # ← 指定 NVIDIA 运行时
    environment:
      - NVIDIA_VISIBLE_DEVICES=0 # ← 只能用 GPU 0
      - CUDA_VISIBLE_DEVICES=0   # ← CUDA 层面也只能看到这一张
    volumes:
      - /data/training:/data     # ← 训练数据挂载
      - /logs:/logs              # ← 日志挂载
    shm_size: '16gb'             # ← 共享内存 16GB（DataLoader 需要）
    command: >
      torchrun
        --nnodes=2
        --nproc_per_node=1
        --rdzv_endpoint=train-node0:29500
        train.py

  train-gpu1:
    image: gpu-train:latest
    container_name: train-node1
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=1
      - CUDA_VISIBLE_DEVICES=1
    shm_size: '16gb'
    command: >
      torchrun
        --nnodes=2
        --nproc_per_node=1
        --rdzv_endpoint=train-node0:29500
        train.py
```

---

## ⚠️ 关键注意事项

### `--shm-size` 必须够大

```
PyTorch 的 DataLoader 用多进程并发加载数据，进程间通过 /dev/shm 共享数据。
Docker 默认 /dev/shm = 64MB，AI 场景远远不够。

症状：DataLoader 加载极慢，或报 "No space left on device"
解决：docker run --shm-size=16g ...
经验值：batch_size × 每组样本大小 × num_workers × 2
```

### 版本兼容性检查

```bash
# 在宿主机确认驱动支持的 CUDA 版本上限
nvidia-smi | grep "CUDA Version"
# 容器的 CUDA 镜像版本必须 ≤ 这个值

# 例如：宿主机驱动显示 CUDA Version: 12.4
#   ✅ nvidia/cuda:12.4-base-ubuntu22.04
#   ✅ nvidia/cuda:12.1-base-ubuntu22.04
#   ❌ nvidia/cuda:12.6-base-ubuntu22.04  ← CUDA 12.6 需要更新的驱动
```

### 容器里不要装驱动

```
常见误区：在 Dockerfile 里放 nvidia-driver-535
正确做法：驱动在宿主机装一次，所有容器共享

容器里需要的是：
✅ CUDA Toolkit（通过基础镜像 nvidia/cuda 提供）
✅ cuDNN（通过 nvidia/cuda:*-cudnn-* 镜像提供）
❌ NVIDIA 驱动（不需要！）
```

---

## 📝 面试要点

1. **GPU 容器化的核心原理**：`nvidia-container-runtime` 作为 OCI 钩子，在容器启动时注入 GPU 设备节点和库文件

2. **为什么 --shm-size 重要**：PyTorch DataLoader 多进程共享数据依赖 `/dev/shm`

3. **驱动与 CUDA 容器的兼容规则**：容器 CUDA 版本 ≤ 宿主机驱动支持的版本

4. **MIG + 容器的组合**：一张 A100 切多份，每个容器独占一份，提升 GPU 利用率

5. **常用基础镜像选择**：`base`（最小）、`runtime`（含cuDNN）、`devel`（含编译工具）
