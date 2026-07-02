# 环境日志

## 节点信息

| 节点 | 平台 | GPU | 状态 |
|------|------|-----|------|
| gpu-node-01 | AutoDL | RTX 3090 24GB × 1 | 运行中 |
| gpu-node-02 | — | — | 待租用（模块 7 需要） |

## 初始环境 (2026-06-29)

| 组件 | 版本 | 来源 |
|------|------|------|
| OS | Ubuntu 22.04 LTS | AutoDL 基础镜像 |
| 驱动 | 550.144.01 | 镜像自带 |
| CUDA Toolkit | 12.4 (nvcc) | 镜像自带 |
| PyTorch | 2.7.1+cu124 | pip 安装（清华镜像） |
| NCCL | 2.21.5 | pip 安装 |
| cuDNN | 9.1.1 | PyTorch 自带 |

## 安装记录

| 日期 | 操作 | 结果 |
|------|------|------|
| 06-29 | `pip3 install torch torchvision torchaudio -i https://pypi.tuna.tsinghua.edu.cn/simple` | ✅ PyTorch 2.7.1 |
| 06-29 | `pip3 install nvidia-nccl-cu12 -i https://pypi.tuna.tsinghua.edu.cn/simple` | ✅ NCCL 2.21.5 |
| 06-29 | hello_cuda.cu 编译运行 | ✅ nvcc 编译通过，kernel 执行正常 |

## 踩坑记录

| 日期 | 问题 | 原因 | 解决方法 |
|------|------|------|----------|
| 06-29 | pip install torch 太慢 | 默认走国外源 | 用清华镜像 `-i https://pypi.tuna.tsinghua.edu.cn/simple` |
| 06-29 | `hostnamectl set-hostname` 失败 | AutoDL 是容器，无 systemd | 用 `sudo hostname gpu01` 替代；终端提示符改 PS1 |
| 06-29 | PCIe 显示 Gen1 不升 Gen4 | AutoDL 容器隔离，宿主机接管 PCIe 电源管理 | 不影响使用，物理机上无此问题 |
