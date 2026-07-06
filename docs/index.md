# 文档索引

> 面试版精简文档。完整教程见 `d:\claude\gpu-ops-tutorial\`

## 文档列表

| 文档 | 内容 | 状态 |
|------|------|:---:|
| [01 GPU 硬件](01-hardware.md) | GPU 架构、选型、MIG、PCIe 拓扑、nvidia-smi | ✅ |
| [02 GPU 软件栈](02-software-stack.md) | 驱动/CUDA/cuDNN/NCCL 版本对齐、安装、验证 | ✅ |
| [03 GPU 监控](03-monitoring.md) | DCGM 部署、XID/ECC 诊断、压力测试、告警阈值 | ✅ |
| [04 容器化 GPU](04-containerization.md) | NVIDIA Container Toolkit、Dockerfile、docker-compose | ✅ |
| [05 K8s GPU](05-kubernetes-gpu.md) | GPU Operator、节点标签、PyTorchJob、资源配额 | ✅ |
| [06 GPU 调度](06-scheduling.md) | Volcano/Slurm/Kueue、Gang Scheduling、GPU 共享 | ✅ |
| [命令速查表](gpu-commands-cheatsheet.md) | 覆盖日常 90% 场景的 GPU 命令 | ✅ |
