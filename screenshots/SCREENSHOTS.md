# 截图日志

> 每完成一个实验步骤的截图，记录在这里。面试时按时间线展示。

| 日期 | 文件 | 内容 | 来源 |
|------|------|------|------|
| 2026-06-29 | `01-initial-nvidia-smi.png` | 初始环境：nvidia-smi + nvcc --version | 教程模块 2 · 实验 0 |
| | | 驱动 550.144.01 · CUDA 12.4 · RTX 3090 | |

## 待截图清单

> 从教程中提取的关键截图节点，每完成一个就填上。

- [ ] `02-pytorch-gpu-verified.png` — PyTorch 安装完成，`torch.cuda.is_available() == True`
- [ ] `03-hello-cuda.png` — 编译运行 hello_cuda.cu 的输出
- [ ] `04-cudnn-version.png` — `cat /usr/local/cuda/include/cudnn_version.h` 的输出
- [ ] `05-nccl-test.png` — NCCL `all_reduce_perf` 的带宽输出
- [ ] `06-dcgm-discover.png` — `dcgmi discover -l` 的输出
- [ ] `07-dcgm-diag-l2.png` — `dcgmi diag -r 2` 的诊断结果 PASS
- [ ] `08-gpu-burn.png` — `gpu_burn 60` 运行中的 nvidia-smi 截图
- [ ] `09-gpu-topo.png` — `nvidia-smi topo -m` 的拓扑矩阵
- [ ] `10-oom-diagnosis.png` — OOM 模拟实验的关键输出
- [ ] `11-dcgm-dmon.png` — `dcgmi dmon` 连续监控输出
- [ ] `12-grafana-dashboard.png` — Grafana GPU 监控面板（后面模块）
- [ ] `13-training-job.png` — 分布式训练 Job 运行中（后面模块）
