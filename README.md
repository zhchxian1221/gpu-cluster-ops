# GPU 集群运维项目

> 从零搭建 GPU 算力集群的完整实战记录 —— 面向算力运维/GPU SRE 岗位。

## 项目概述

独立完成 GPU 集群的全栈部署与运维，涵盖硬件选型、驱动/CUDA 工具链、容器化、K8s 调度、RDMA 网络、监控体系。

```
硬件层        GPU 服务器选型 · PCIe 拓扑 · BIOS 配置 · 上架布线
   │
软件栈        NVIDIA 驱动 · CUDA Toolkit · cuDNN · NCCL · TensorRT
   │
容器化        Docker · NVIDIA Container Toolkit · GPU 资源隔离
   │
编排调度       K8s + GPU Operator · Volcano · Slurm · 优先级/队列
   │
网络          RDMA · InfiniBand · RoCE v2 · NCCL 通信拓扑
   │
存储          Lustre · 并行文件系统 · 数据流水线
   │
监控          DCGM · Prometheus · Grafana · 告警规则
   │
平台          Kubeflow · PyTorchJob · vLLM 推理服务
```

## 技能矩阵

| 技能领域 | 具体能力 | 证明 |
|---------|---------|------|
| GPU 硬件 | A100/H100/3090/4090 选型、MIG 切分、PCIe 拓扑分析 | [截图](screenshots/) · [文档](docs/01-hardware.md) |
| 驱动 & CUDA | 驱动安装、CUDA/cuDNN/NCCL 版本对齐、多版本共存 | [截图](screenshots/) · [文档](docs/02-software-stack.md) |
| 监控诊断 | DCGM 部署、健康检查、XID/ECC 故障排查、GPU Burn 压力测试 | [截图](screenshots/) · [脚本](scripts/health-check.sh) |
| 容器化 | Docker GPU 容器、NVIDIA Container Toolkit 配置 | [文档](docs/04-containerization.md) |
| K8s GPU | GPU Operator 部署、MIG 资源申请、Pod 调度 | [文档](docs/05-kubernetes-gpu.md) |
| 调度系统 | Volcano Queue/Priority、Slurm 分区/QoS、共享 GPU | [文档](docs/06-scheduling.md) |
| 高性能网络 | RDMA 原理、NCCL AllReduce 调优、RoCE 配置 | [文档](docs/07-networking.md) |
| 自动化运维 | GPU 节点一键部署、健康巡检脚本、Grafana Dashboard | [脚本](scripts/) · [Dashboard](dashboards/) |

## 实验环境

| 项 | 配置 |
|----|------|
| 云平台 | [AutoDL](https://www.autodl.com) |
| GPU | NVIDIA RTX 3090 24GB × 2 |
| OS | Ubuntu 22.04 LTS |
| 驱动 | 550.144.01 |
| CUDA | 12.4 |
| 容器运行时 | Docker + NVIDIA Container Toolkit |
| K8s | K3s（轻量发行版） |
| 监控 | DCGM + Prometheus + Grafana |

## 目录结构

```
gpu-cluster-ops/
├── README.md                  ← 本文件
├── screenshots/               ← 实验截图（每一步的证明）
│   ├── 01-nvidia-smi.png
│   ├── 02-cuda-version.png
│   ├── 03-dcgm-health.png
│   └── ...
├── scripts/                   ← 运维脚本
│   ├── health-check.sh        ← GPU 健康巡检
│   ├── deploy-gpu-node.sh     ← 一键部署 GPU 节点
│   └── burn-test.sh           ← 压力测试
├── dashboards/                ← Grafana 面板 JSON
├── docs/                      ← 技术文档
├── benchmarks/                ← 性能测试数据
└── notes/                     ← 踩坑记录
```

## 快速开始

```bash
# GPU 健康巡检
bash scripts/health-check.sh

# GPU 压力测试（10分钟）
bash scripts/burn-test.sh 600
```

---

> 本项目作为学习过程的完整记录，所有截图和脚本均来自真实实验环境。
>
> 🤖 学习指导：[Claude Code](https://claude.com/claude-code)
