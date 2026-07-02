# 模块 05：Kubernetes GPU Operator

> 在 K8s 集群中管理 GPU 工作负载的完整参考。

---

## 📖 概念

### 为什么需要 K8s 管理 GPU？

单台 GPU 服务器你一个人管没问题。但一个 32 台 GPU 服务器的集群，30 个人同时提交训练任务，每个人要 2-8 张卡——这就不能手动分配了。

```
规模对比：

1 台服务器 → 手动分配，SSH 上去看谁在用 → 勉强可行
8 台服务器 → 需要脚本/工具协调                   → 吃力
32 台服务器 → 必须有调度系统                     → K8s/Slurm
100+ 台     → K8s/Slurm + 队列管理 + 优先级 + 计费 → 算力平台
```

K8s 管 GPU 的价值：

| 能力 | 说明 |
|------|------|
| **统一调度** | 用户提交任务，K8s 自动找有空闲 GPU 的节点 |
| **资源隔离** | 这个 Pod 申请 2 张 GPU，那个 Pod 不能抢 |
| **排队机制** | 资源不够时自动排队，有 GPU 释放出来再跑 |
| **故障自愈** | GPU 节点挂了，Pod 自动迁移到其他节点 |
| **混合编排** | GPU 任务和普通 Web 服务跑在同一个集群，统一管理 |
| **多租户** | 团队 A 用队列 A，团队 B 用队列 B，资源配额隔离 |

### 架构：NVIDIA GPU Operator

GPU Operator 是一个 Helm Chart/K8s Operator，它在 K8s 集群里自动部署和管理整个 GPU 软件栈：

```
┌──────────────────────────────────────────────────────────┐
│  GPU Operator (Helm Chart)                                │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ Node Feature Discovery (NFD)                       │  │
│  │ 自动发现节点上的 GPU 型号、数量 → 给 node 打标签      │  │
│  │ node label: nvidia.com/gpu.product=A100-SXM4-80GB  │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ NVIDIA Driver Container                            │  │
│  │ 把驱动装进容器，DaemonSet 部署到每个 GPU 节点        │  │
│  │ 作用：新节点加入集群时自动装驱动，不用手动操作        │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ NVIDIA Container Toolkit                           │  │
│  │ 部署 nvidia-container-runtime，让 K8s 的             │  │
│  │ 容器运行时 (containerd/cri-o) 能分配 GPU            │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ GPU Device Plugin                                  │  │
│  │ 向 K8s 注册 GPU 资源：nvidia.com/gpu: 8            │  │
│  │ Pod 请求 nvidia.com/gpu: 2 → K8s 知道去哪分配       │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ DCGM Exporter                                      │  │
│  │ 把 GPU 指标暴露成 Prometheus 格式                   │  │
│  │ 在 :9400/metrics 端口提供指标数据                    │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

### Node Label 体系——K8s 怎么知道哪台有 GPU

```
一个 GPU 节点加入集群后，GPU Operator 自动给它打标签：

# 核心标签
nvidia.com/gpu.present=true                    ← 这个节点有 GPU
nvidia.com/gpu.count=8                        ← 每节点 GPU 数量
nvidia.com/gpu.product=A100-SXM4-80GB         ← GPU 型号
nvidia.com/gpu.memory=81920                    ← 每卡显存 (MiB)
nvidia.com/gpu.replicas=1                      ← GPU 复制数（MIG 时有变化）
nvidia.com/cuda.driver-version=535.129.03      ← 驱动版本

# 这些标签用于：
# 1. Pod 调度：只把 GPU Pod 调度到有 GPU 的节点
# 2. 资源分配：K8s 知道每台节点有多少 GPU 可分配
# 3. 亲和性：可以指定"这个 Pod 必须用 A100，不能用 3090"
```

---

## 🛠️ 配置参考

### GPU Operator 部署（Helm）

```bash
# ===== 第一步：添加 NVIDIA Helm 仓库 =====
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# ===== 第二步：安装 GPU Operator =====
helm install --wait --generate-name \
    -n gpu-operator --create-namespace \
    nvidia/gpu-operator \
    --set operator.defaultRuntime=containerd \
    --set driver.enabled=true
# -n gpu-operator          → 装到 gpu-operator 命名空间（Namespace）
# --create-namespace       → 如果命名空间不存在就创建
# --set driver.enabled=true → 让 Operator 自动在节点上装驱动
# --set operator.defaultRuntime=containerd → K8s 集群用的是 containerd

# 如果你的集群已经手动装了驱动，跳过他自动装：
# helm install ... --set driver.enabled=false
```

### 验证部署

```bash
# 看 GPU Operator 的 Pod 是否都 Running
kubectl get pods -n gpu-operator

# 预期输出：
# NAME                                                          READY   STATUS
# gpu-operator-xxxxx                                            1/1     Running
# nvidia-container-toolkit-daemonset-xxxxx                      1/1     Running
# nvidia-cuda-validator-xxxxx                                   0/1     Completed
# nvidia-dcgm-exporter-xxxxx                                    1/1     Running
# nvidia-device-plugin-daemonset-xxxxx                          1/1     Running
# nvidia-driver-daemonset-xxxxx                                 1/1     Running
# nvidia-operator-validator-xxxxx                               1/1     Running

# 看节点有没有被识别为 GPU 节点
kubectl describe node <gpu-node-name> | grep nvidia
# 应该有 nvidia.com/gpu.present=true 等标签
# 应该有 nvidia.com/gpu: 8 这样的可分配资源
```

### 提交一个 GPU Pod

```yaml
# gpu-test-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-verify
spec:
  restartPolicy: Never

  containers:
  - name: cuda-test
    image: nvidia/cuda:12.2-base-ubuntu22.04
    command: ["nvidia-smi"]

    # ===== GPU 资源申请 =====
    resources:
      limits:
        nvidia.com/gpu: 1
    # limits = 硬上限，Pod 最多用这么多
    # nvidia.com/gpu: 1 → 申请 1 张 GPU
    # 如果不写 requests，K8s 自动设置 requests = limits
```

```bash
# 提交
kubectl apply -f gpu-test-pod.yaml

# 看日志（应该能看到 nvidia-smi 输出）
kubectl logs gpu-verify

# 提交完删掉
kubectl delete pod gpu-verify
```

### 资源申请 vs 资源限制

```yaml
resources:
  requests:
    nvidia.com/gpu: 1        # 调度请求：K8s 保证分配给这个 Pod
  limits:
    nvidia.com/gpu: 2        # 使用上限：Pod 最多用这么多
# 对于 GPU 来说，requests 和 limits 通常设为相等
# GPU 不能超分（不像 CPU 内存），一张卡要么给你要么不给你
# 设不等的场景：需要 MIG 或多实例 GPU 共享
```

### GPU 节点选择器

```yaml
spec:
  nodeSelector:
    nvidia.com/gpu.product: A100-SXM4-80GB
  # 确保 Pod 只调度到 A100 节点，不会跑到 3090 节点上

  # 或者用亲和性（更灵活）
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: nvidia.com/gpu.memory
            operator: Gt          # Gt = Greater Than，大于
            values: ["40000"]     # 只调度到显存 > 40GB 的 GPU 节点
```

### GPU 工作负载容忍度和污点

```yaml
spec:
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
  # GPU 节点通常会打 taint（污点），防止非 GPU Pod 调度上来
  # toleration（容忍度）让 GPU Pod 能忽略这个污点
  # 效果：只有声明了"我要用 GPU"的 Pod 才会上 GPU 节点
```

### MIG 模式下的 GPU 资源申请

```yaml
# A100 切成 MIG 3g.40gb × 2 实例后，Pod 申请方式：

resources:
  limits:
    nvidia.com/mig-3g.40gb: 1
# 申请 1 个 MIG 3g.40gb 实例
# 不写 nvidia.com/gpu（整卡已不存在）

# 或者更精确：
resources:
  limits:
    nvidia.com/gpu: 1
# 注意：启用 MIG 后，nvidia.com/gpu 仍然可用
# 但 1 个 nvidia.com/gpu = 1 个 MIG 实例（不是 1 张物理卡）
# 具体行为取决于 GPU Operator 的 MIG 策略配置
```

---

## 📁 项目文件

### 完整部署：PyTorch 分布式训练 Job

```yaml
# pytorch-distributed-job.yaml
# ============================================
# PyTorch 分布式训练任务
#   - 2 节点 × 2 GPU = 4 卡并行训练
#   - Worker 节点各自申请 2 张 GPU
#   - Master 节点协调所有 Worker
# ============================================

apiVersion: kubeflow.org/v1
kind: PyTorchJob          # PyTorchJob 是 Kubeflow 的 CRD
metadata:
  name: resnet50-train    # 任务名称
  namespace: ml-team      # 命名空间
spec:
  # ===== 副本配置 =====
  pytorchReplicaSpecs:

    # --- Master 节点（1 个副本）---
    Master:
      replicas: 1         # Master 只有 1 个
      restartPolicy: OnFailure
      template:
        spec:
          containers:
          - name: pytorch
            image: gpu-train:latest
            command:
            - torchrun
            - --nnodes=2
            - --nproc_per_node=2           # 每节点 2 个进程 = 用 2 张卡
            - --rdzv_backend=c10d
            - --rdzv_endpoint=localhost:29500
            - train.py

            # GPU 资源
            resources:
              limits:
                nvidia.com/gpu: 2          # Master 节点用 2 张 GPU

            # 共享内存（DataLoader 需要）
            volumeMounts:
            - name: dshm
              mountPath: /dev/shm

          volumes:
          - name: dshm
            emptyDir:
              medium: Memory
              sizeLimit: 16Gi

    # --- Worker 节点（1 个副本）---
    Worker:
      replicas: 1          # 1 个 Worker
      restartPolicy: OnFailure
      template:
        spec:
          containers:
          - name: pytorch
            image: gpu-train:latest
            command:
            - torchrun
            - --nnodes=2
            - --nproc_per_node=2
            - --rdzv_backend=c10d
            - --rdzv_endpoint=<master-pod-ip>:29500
            - train.py

            resources:
              limits:
                nvidia.com/gpu: 2

            volumeMounts:
            - name: dshm
              mountPath: /dev/shm

          volumes:
          - name: dshm
            emptyDir:
              medium: Memory
              sizeLimit: 16Gi

# 提交命令：
#   kubectl apply -f pytorch-distributed-job.yaml
# 查看状态：
#   kubectl get pytorchjob -n ml-team
# 查看日志：
#   kubectl logs -n ml-team -l job-name=resnet50-train
```

### GPU 节点池（Node Pool）YAML 示例

```yaml
# gpu-node-pool.yaml
# 为不同类型的 GPU 创建不同的节点池
---
apiVersion: v1
kind: Node
metadata:
  name: gpu-a100-01
  labels:
    node-pool: gpu-a100
    nvidia.com/gpu.product: A100-SXM4-80GB
    accelerator: nvidia-gpu
  taints:
  - key: nvidia.com/gpu
    value: "true"
    effect: NoSchedule
# taint + toleration 确保只有 GPU Pod 能调度到这些节点
---
apiVersion: v1
kind: Namespace
metadata:
  name: team-a
  labels:
    resource-pool: gpu-a100
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota
  namespace: team-a
spec:
  hard:
    nvidia.com/gpu: "4"
# team-a 命名空间最多用 4 张 GPU
# 防止一个团队占满集群 GPU 资源
```

### GPU 监控 ServiceMonitor（Prometheus）

```yaml
# gpu-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dcgm-exporter
  namespace: gpu-operator
spec:
  selector:
    matchLabels:
      app: nvidia-dcgm-exporter
  endpoints:
  - port: gpu-metrics        # DCGM Exporter 暴露的端口名
    interval: 15s            # 每 15 秒采集一次
    path: /metrics           # Prometheus 指标路径
```

---

## ⚠️ 关键注意事项

### 1. `nvidia.com/gpu` 资源不能超分

```
与 CPU（可以超分 10 倍）不同，GPU 是 "整数资源"：
- GPU 0 分配给了 Pod A，Pod B 不能碰
- 除非启用 GPU 共享方案（Volcano HAMI / MIG / MPS）

所以 requests = limits 是正确的默认行为
```

### 2. GPU Operator 的 Driver Container 不是必选项

```
推荐做法：物理装机时手动装驱动，GPU Operator 关闭 driver.enabled
Helm install --set driver.enabled=false

原因：Driver Container 依赖内核头文件精确匹配，容易因为内核小版本
升级导致编译失败。手动装的驱动通过 DKMS 管理更稳定。
```

### 3. PytorchJob 的 restartPolicy

```
Kubernetes 默认 pod restartPolicy 是 Always
PytorchJob/分布式训练建议设为 OnFailure

因为：
  - Always → 训练结束后 Pod 重启又跑一遍 → 浪费 GPU
  - OnFailure → 只在报错时重启
  - Never → 报错了也不重启，任务就丢了
```

### 4. 容器运行时的选择

```
K8s 1.24+ 默认用 containerd，不再用 Docker

GPU 支持需要：
  containerd 配置里加上 nvidia-container-runtime
  或者用 GPU Operator 自动配置（推荐）

检查方法：
  cat /etc/containerd/config.toml | grep nvidia
```

---

## 📝 面试要点

1. **GPU Operator 的架构**：NFD 发现 → Device Plugin 注册 → Driver（可选）→ Toolkit 配置 → DCGM Exporter 监控——五个组件各司其职

2. **nvidia.com/gpu 资源模型**：整数资源，不能超分；MIG 场景下 `nvidia.com/mig-3g.40gb: 1`

3. **Node Taint + Toleration**：GPU 节点打污点，防止非 GPU Pod 调度上来浪费资源

4. **PyTorchJob**：Kubeflow 的 CRD，Master/Worker 模式，每个 Worker 独立申请 GPU

5. **ResourceQuota**：限制命名空间 GPU 用量，防止单个团队/用户占满集群

6. **shm-size**：K8s 里用 `emptyDir medium: Memory` 实现，跟 Docker --shm-size 等价
