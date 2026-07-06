# 模块 05：Kubernetes GPU Operator

> **目标**：理解 K8s 怎么管理 GPU、GPU Operator 每个组件干什么、能写出 GPU Pod 和 PyTorchJob 的 YAML 配置。
>
> **环境限制**：AutoDL 是容器无法装 K8s，本模块以概念 + YAML 逐行解读为主。有 K8s 集群后命令直接可用。

---

## 📖 概念解释

### 5.1 先理解问题——从 1 台到 100 台发生了什么

你现在有 1 台 GPU 服务器（AutoDL 上的 3090）。你怎么知道 GPU 在不在用？看一眼 `nvidia-smi` 就行。

**当你有 32 台的时候：**

```
问题：
  1. 用户 A 想用 2 张 GPU → 哪台机器有空闲的 2 张？
  2. 用户 B 提交了任务，但机器 5 的 GPU 3 坏了 → 自动换一台？
  3. 用户 C 占着 8 张 GPU 但 3 天没跑任何计算 → 怎么发现？
  4. 新买了 4 台 H100 加入集群 → 怎么让用户知道"这里有新卡"？
  5. 用户 D 的任务把机器搞崩了 → 怎么自动恢复？

单机运维靠眼睛看，集群运维靠调度系统管。
```

**K8s 的答案**：把所有 GPU 服务器变成一个大池子，用户不关心"用哪台机器的哪张卡"，只声明"我需要 2 张 GPU"，K8s 自动找、自动分配、自动恢复。

```
用户视角：
  kubectl apply -f my-job.yaml     # 提交："我要 2 张 GPU"

K8s 内部：
  1. 看所有节点，哪些有 ≥2 张空闲 GPU
  2. 选一台最合适的（拓扑最近、负载最轻）
  3. 把 Pod 调度过去，挂上 GPU
  4. Pod 跑完了 → 释放 GPU → 给下一个任务
  5. 节点挂了 → Pod 自动迁移到另一台
```

### 5.2 架构——GPU Operator 五个组件各干什么

GPU Operator 是一个 Helm Chart，一键部署五个组件。你不需要手动装每一个，但面试时要能说出各自的作用。

```
┌──────────────────────────────────────────────────────────────┐
│  GPU Operator (一个 Helm install 全部搞定)                    │
│                                                              │
│  组件1: Node Feature Discovery (NFD)                         │
│    "这台机器有没有 GPU？什么型号？几张？"                       │
│    → 自动发现 → 给 K8s Node 打标签                            │
│    标签: nvidia.com/gpu.product=A100-SXM4-80GB               │
│          nvidia.com/gpu.count=8                              │
│          nvidia.com/gpu.memory=81920                         │
│                                                              │
│  组件2: NVIDIA Driver Container (DaemonSet)                  │
│    "给每个 GPU 节点自动装驱动"                                  │
│    → 新节点加入集群 → 自动部署驱动 → 无需手动操作                │
│    → 可选：如果物理装机时已经手动装了驱动，可以关闭这个组件        │
│                                                              │
│  组件3: NVIDIA Container Toolkit (DaemonSet)                 │
│    "让 K8s 的容器运行时（containerd）能分配 GPU 给容器"          │
│    → 配置 containerd 使用 nvidia-container-runtime            │
│                                                              │
│  组件4: GPU Device Plugin (DaemonSet)                        │
│    "向 K8s 注册：这台节点有 nvidia.com/gpu 资源，共 8 个"       │
│    → K8s 调度器才知道"节点 A 还剩 3 张 GPU 可以分配"            │
│                                                              │
│  组件5: DCGM Exporter (DaemonSet)                            │
│    "把 GPU 指标暴露成 Prometheus 格式"                         │
│    → Grafana 能画出 GPU 利用率/温度/功耗的历史曲线              │
│    → 在 :9400/metrics 端口                                    │
└──────────────────────────────────────────────────────────────┘
```

**关键理解——Device Plugin 是核心**：

```
没有 Device Plugin 时：
  kubectl describe node gpu-node-01
  → 看不到 nvidia.com/gpu 这个资源
  → Pod 无法申请 GPU

有 Device Plugin 后：
  kubectl describe node gpu-node-01
  → Capacity: nvidia.com/gpu: 8
  → Allocatable: nvidia.com/gpu: 8
  → K8s 知道"这里有 8 张 GPU 可以分"

Pod 申请 GPU：
  resources:
    limits:
      nvidia.com/gpu: 2
  → K8s 调度器：节点 A 还有 3 张空闲 → 分配 2 张 → 剩余 1 张
```

### 5.3 Node Label——K8s 怎么区分 A100 和 3090

你买的 GPU 集群里可能同时有 A100（训练）和 3090（开发），价格差 10 倍。不能让开发任务跑到 A100 上浪费。

```
GPU Operator 自动给节点打的标签：

  nvidia.com/gpu.present=true         → 有 GPU
  nvidia.com/gpu.product=A100-SXM4-80GB → 型号
  nvidia.com/gpu.count=8              → 数量
  nvidia.com/gpu.memory=81920         → 显存（MiB）
  nvidia.com/cuda.driver-version=550.144.01 → 驱动版本

Pod 用 nodeSelector 选择 GPU 类型：
  nodeSelector:
    nvidia.com/gpu.product: A100-SXM4-80GB  → 只要 A100
```

### 5.4 GPU 资源模型——为什么 requests = limits

```
CPU 内存资源：
  requests: 2 CPU     → 调度保证（找有 2 核空闲的节点）
  limits: 4 CPU       → 运行上限（最多用到 4 核）
  requests < limits   → 可以超分（一个 8 核机器可以跑 20 个请求 1 核的 Pod）

GPU 资源：
  requests: nvidia.com/gpu: 1
  limits: nvidia.com/gpu: 1
  requests = limits   → 不能超分！GPU 是整数资源

原因：GPU 不像 CPU 可以分时共享（除非用 MIG/MPS/HAMi）
      一张卡分给 Pod A 了，Pod B 就不能碰
      所以 K8s 要求 GPU 的 requests 必须等于 limits
```

---

## 🛠️ 动手实验

### 实验 1：逐行解读 GPU Operator 部署命令

你现在没有 K8s 集群，但可以把这段命令每一行的作用搞清楚。拿到集群后直接复制粘贴就能用。

```bash
# ===== 第一步：添加 NVIDIA Helm 仓库 =====
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
# helm repo add → 添加一个 Helm Chart 仓库
# nvidia → 给这个仓库起名叫 nvidia（本地别名）
# URL → NVIDIA 官方的 Helm Chart 托管地址（NGC = NVIDIA GPU Cloud）

helm repo update
# 拉取最新的 Chart 索引文件
# 相当于 apt update —— 不执行这步，helm install 可能装旧版本

# ===== 第二步：安装 GPU Operator =====
helm install --wait --generate-name \
  -n gpu-operator --create-namespace \
  nvidia/gpu-operator \
  --set driver.enabled=true \
  --set operator.defaultRuntime=containerd
# 逐参数解释：
# helm install        → 安装一个 Helm Chart
# --wait              → 等所有 Pod 都 Ready 了才返回（否则 helm 立刻返回，你不知道装没装完）
# --generate-name     → 自动生成一个部署名称（如 gpu-operator-1688000000）
# -n gpu-operator     → 安装到 gpu-operator 这个命名空间
# --create-namespace  → 如果命名空间不存在，自动创建
# nvidia/gpu-operator → 从 nvidia 仓库安装 gpu-operator 这个 Chart
# --set driver.enabled=true → 让 Operator 自动在节点上安装 NVIDIA 驱动
# --set operator.defaultRuntime=containerd → 告诉 Operator 你的 K8s 用的是 containerd
#   （K8s 1.24+ 默认用 containerd，不再用 Docker）
```

### 实验 2：验证 GPU Operator 部署

```bash
# 看 GPU Operator 的所有 Pod
kubectl get pods -n gpu-operator
```

```
预期输出（逐行解读）：

NAME                                                  READY   STATUS
gpu-operator-xxxxx                                    1/1     Running
  ↑ Operator 控制器本身，管理其他组件的生命周期

nvidia-container-toolkit-daemonset-xxxxx              1/1     Running
  ↑ DaemonSet，每个 GPU 节点跑一个，配容器运行时

nvidia-cuda-validator-xxxxx                           0/1     Completed
  ↑ Job，跑完就退出。验证 CUDA 能不能正常工作

nvidia-dcgm-exporter-xxxxx                            1/1     Running
  ↑ DaemonSet，每个 GPU 节点跑一个，暴露 Prometheus 指标

nvidia-device-plugin-daemonset-xxxxx                  1/1     Running
  ↑ DaemonSet，向 K8s 注册 GPU 资源

nvidia-driver-daemonset-xxxxx                         1/1     Running
  ↑ DaemonSet（如果 --set driver.enabled=true），装驱动的

nvidia-operator-validator-xxxxx                       1/1     Running
  ↑ 验证 Operator 所有组件都配置正确
```

```bash
# 看节点有没有被识别为 GPU 节点
kubectl get nodes -o wide
kubectl describe node <gpu-node-name> | grep nvidia
```

```
预期输出：
  nvidia.com/gpu.present=true
  nvidia.com/gpu.product=NVIDIA-A100-SXM4-80GB
  nvidia.com/gpu.count=8
  nvidia.com/gpu.memory=81920
  nvidia.com/cuda.driver-version=550.144.01
  ...
  Capacity:
    nvidia.com/gpu: 8        ← 总共有 8 张
  Allocatable:
    nvidia.com/gpu: 8        ← 可分配 8 张
```

### 实验 3：提交第一个 GPU Pod——逐行解读

把下面这个 YAML 保存到你的项目里，面试时能说出每一行的作用。

```yaml
# ============================================
# gpu-test-pod.yaml — 最简 GPU Pod
# 提交: kubectl apply -f gpu-test-pod.yaml
# 查看: kubectl logs gpu-verify
# 删除: kubectl delete pod gpu-verify
# ============================================

apiVersion: v1
kind: Pod                  # Pod = K8s 最小的调度单位
metadata:
  name: gpu-verify         # Pod 名称
spec:
  restartPolicy: Never     # 跑完不重启（OnFailure=报错才重启，Always=永远重启）

  containers:
  - name: cuda-test
    image: nvidia/cuda:12.2-base-ubuntu22.04
    # ↑ NVIDIA 官方的 CUDA 基础镜像
    # 不需要在镜像里装驱动——驱动是宿主机共享的

    command: ["nvidia-smi"]
    # 容器启动后执行 nvidia-smi，打印 GPU 信息后退出

    resources:
      limits:
        nvidia.com/gpu: 1
      # limits = 这个容器最多用 1 张 GPU
      # 没有写 requests → K8s 自动设 requests = limits = 1
      # 这意味着"我要 1 张 GPU，多不要，少不行"
```

提交后的完整生命周期：

```bash
# 1. 提交
kubectl apply -f gpu-test-pod.yaml
# Pod 进入 Pending 状态

# 2. K8s 调度器查找有 ≥1 张空闲 GPU 的节点
# 找到 → 绑定 Pod 到该节点 → Pod 进入 ContainerCreating

# 3. Kubelet 调用 nvidia-container-runtime 创建容器
# 注入 /dev/nvidia0 设备 + nvidia 相关的 .so 库

# 4. 容器启动，运行 nvidia-smi → 输出 GPU 信息 → 退出

# 5. 查看结果
kubectl logs gpu-verify
# 应该看到 nvidia-smi 的完整输出

# 6. 清理
kubectl delete pod gpu-verify
```

### 实验 4：GPU 节点亲和性——指定 GPU 型号

```yaml
# gpu-pod-with-selector.yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-a100-only
spec:
  restartPolicy: Never

  # ===== 方式1：nodeSelector（简单）=====
  nodeSelector:
    nvidia.com/gpu.product: A100-SXM4-80GB
  # 这个 Pod 只会被调度到 A100 节点
  # 如果集群没有 A100 → Pod 永远 Pending

  containers:
  - name: test
    image: nvidia/cuda:12.2-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
---
# ===== 方式2：affinity（更灵活）=====
apiVersion: v1
kind: Pod
metadata:
  name: gpu-big-memory
spec:
  restartPolicy: Never

  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        # requiredDuring... = 硬要求，不满足就不调度
        # IgnoredDuringExecution = 运行后如果标签变了也不迁移
        nodeSelectorTerms:
        - matchExpressions:
          - key: nvidia.com/gpu.memory
            operator: Gt           # Gt = Greater Than，大于
            values: ["40000"]      # 只要显存 > 40GB 的 GPU（= A100/H100 等）
          - key: nvidia.com/gpu.count
            operator: Gte          # Gte = Greater Than or Equal
            values: ["4"]          # 而且节点上至少有 4 张 GPU

  containers:
  - name: test
    image: nvidia/cuda:12.2-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 4          # 申请 4 张 GPU
```

### 实验 5：GPU 节点污点和容忍——防止非 GPU Pod 乱调度

这是生产环境必须做的事——GPU 节点比普通节点贵得多，不能让普通的 Web 服务 Pod 调度上去浪费资源。

```yaml
# ===== 第一步：给 GPU 节点打污点 =====
# kubectl taint node gpu-node-01 nvidia.com/gpu=true:NoSchedule

# 解读：
# kubectl taint → 给节点打污点
# node gpu-node-01 → 目标节点
# nvidia.com/gpu=true → 污点的 key=value
# :NoSchedule → 效果：没有对应容忍度的 Pod 不能调度到这个节点

# ===== 第二步：GPU Pod 声明容忍度 =====
apiVersion: v1
kind: Pod
metadata:
  name: gpu-with-toleration
spec:
  # 容忍 GPU 节点的污点
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"      # 只要污点 key 是 nvidia.com/gpu，不管 value 是什么都容忍
    effect: "NoSchedule"    # 针对 NoSchedule 类型的污点

  # 同时指定只要 GPU 节点
  nodeSelector:
    nvidia.com/gpu.present: "true"

  containers:
  - name: test
    image: nvidia/cuda:12.2-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
```

**污点+容忍的逻辑**：

```
节点 gpu-node-01：污点 nvidia.com/gpu:NoSchedule

Pod A（没有 toleration）     → 不能调度 ❌
Pod B（有 GPU toleration）    → 能调度 ✅
Pod C（普通 Web 服务）        → 不能调度 ❌（这正是我们要的）
```

### 实验 6：PyTorchJob——分布式训练的 K8s 抽象

Kubeflow 提供了一个叫 PyTorchJob 的 CRD（自定义资源），专门封装了 PyTorch 分布式训练的复杂性。

```yaml
# pytorchjob-demo.yaml
# 需要先装 Kubeflow Training Operator：
# kubectl apply -k github.com/kubeflow/training-operator/manifests/overlays/standalone

apiVersion: kubeflow.org/v1
kind: PyTorchJob            # ← 不是普通的 Job，是 PyTorchJob
metadata:
  name: train-resnet50
spec:
  pytorchReplicaSpecs:
    # ===== Master 副本 =====
    Master:
      replicas: 1           # Master 永远只有 1 个
      restartPolicy: OnFailure
      template:
        spec:
          containers:
          - name: pytorch
            image: pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime
            command:
            - torchrun
            - --nnodes=2               # 2 个节点（1 Master + 1 Worker）
            - --nproc_per_node=2       # 每节点 2 个进程（= 2 GPU）
            - train.py
            resources:
              limits:
                nvidia.com/gpu: 2      # Master 用 2 张
            volumeMounts:
            - name: dshm
              mountPath: /dev/shm      # 共享内存
          volumes:
          - name: dshm
            emptyDir:
              medium: Memory
              sizeLimit: 16Gi

    # ===== Worker 副本 =====
    Worker:
      replicas: 1           # 1 个 Worker
      restartPolicy: OnFailure
      template:
        spec:
          containers:
          - name: pytorch
            image: pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime
            command:
            - torchrun
            - --nnodes=2
            - --nproc_per_node=2
            - train.py
            resources:
              limits:
                nvidia.com/gpu: 2      # Worker 也用 2 张
            volumeMounts:
            - name: dshm
              mountPath: /dev/shm
          volumes:
          - name: dshm
            emptyDir:
              medium: Memory
              sizeLimit: 16Gi
```

**PyTorchJob 帮你自动处理了什么**：

```
你自己写裸 Pod 需要处理：         PyTorchJob 自动处理：
  ├─ Master 地址怎么传给 Worker      ├─ 注入 MASTER_ADDR 环境变量
  ├─ Worker 怎么等 Master 就绪       ├─ Master 先启动，就绪后起 Worker
  ├─ Master 挂了怎么办               ├─ 自动重启 Master
  ├─ 所有 Worker 挂了算完成           ├─ 自动判断 Job 成功/失败
  └─ 清理资源                        └─ Job 完成后自动清理 Pod
```

### 实验 7：MIG 在 K8s 里的使用

如果你的集群有 A100/H100，启用 MIG 后 GPU 资源会变：

```bash
# 宿主机上启用了 MIG（模块 1 学过）
sudo nvidia-smi -mig 1
sudo nvidia-smi mig -cgi 9,9 -C    # 创建 2 个 3g.40gb 实例

# 此时 kubectl describe node 显示：
# nvidia.com/gpu: 0                ← 整卡资源变成 0
# nvidia.com/mig-3g.40gb: 2       ← MIG 实例变成可分配资源
```

```yaml
# Pod 申请 MIG 实例
apiVersion: v1
kind: Pod
metadata:
  name: inference-with-mig
spec:
  containers:
  - name: vllm
    image: vllm/vllm-openai:latest
    resources:
      limits:
        nvidia.com/mig-3g.40gb: 1  # 申请 1 个 MIG 3g.40gb 实例
        # 不是 nvidia.com/gpu: 1！
```

### 实验 8：防止 GPU 碎片——拓扑感知调度

```
问题：
  节点 A: GPU 0,1 空闲，GPU 2,3 被占
  节点 B: GPU 0,1 空闲，GPU 2,3 被占

  来了一个需要 4 张 GPU 的任务
  → K8s 不能用（节点 A 只有 2 张空闲，节点 B 也只有 2 张）
  → 但总共 4 张空闲！就是凑不到一起！
  → 这叫 GPU 碎片化

解决方法：Volcano 的拓扑感知调度（模块 6 讲过）
  尽量把同一个任务的 GPU 分配到同一节点、同一 NUMA、同一 NVSwitch 下
```

```yaml
# Volcano Job 里指定拓扑策略
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: topology-aware-train
spec:
  schedulerName: volcano
  minAvailable: 4
  tasks:
  - replicas: 4
    name: worker
    template:
      spec:
        containers:
        - name: pytorch
          resources:
            limits:
              nvidia.com/gpu: 1
      # Volcano 会自动尝试把这些 Pod 调度到拓扑最近的位置
```

---

## ✅ 验证步骤

完成本模块后，你应该能回答：

1. **GPU Operator 五个组件各干什么？** —— NFD（发现）、Driver（自动装驱动）、Toolkit（配运行时）、Device Plugin（注册资源）、DCGM Exporter（暴露指标）。

2. **Pod 申请 GPU 用什么资源名？** —— `nvidia.com/gpu`，MIG 场景用 `nvidia.com/mig-3g.40gb` 等。

3. **怎么区分 A100 和 3090？** —— `nodeSelector: nvidia.com/gpu.product: A100-SXM4-80GB`。

4. **为什么 GPU 节点要打污点？** —— 防止非 GPU Pod 调度上来浪费昂贵资源。

5. **PyTorchJob 比裸 Pod 好在哪？** —— 自动处理 Master/Worker 协调、环境变量注入、故障恢复。

---

## ⚠️ 常见陷阱

### 陷阱 1：`/dev/shm` 太小导致 DataLoader 极慢

```
现象：训练日志正常，但 GPU 利用率很低，DataLoader 特别慢

原因：K8s 默认 /dev/shm = 64MB（跟 Docker 一样）
      PyTorch DataLoader 多进程共享数据需要大量共享内存

解决：
  volumes:
  - name: dshm
    emptyDir:
      medium: Memory      # 挂到内存（RAM）
      sizeLimit: 16Gi     # 16GB 共享内存
```

### 陷阱 2：GPU 资源 requests ≠ limits 导致问题

```yaml
# ❌ 错误写法
resources:
  requests:
    nvidia.com/gpu: 1
  limits:
    nvidia.com/gpu: 2     # requests ≠ limits！

# K8s 会拒绝这个 Pod → GPU 资源必须 requests = limits
# 错误信息：nvidia.com/gpu: limits must equal requests

# ✅ 正确写法
resources:
  limits:
    nvidia.com/gpu: 1     # K8s 自动设 requests = limits = 1
```

### 陷阱 3：Driver Container 内核版本不匹配

```
GPU Operator 的 Driver Container（--set driver.enabled=true）
需要编译内核模块，如果宿主机内核太新 → 编译失败 → Pod CrashLoopBackOff

推荐：物理装机时手动装驱动 + DKMS
      GPU Operator 关掉自动装驱动：--set driver.enabled=false
```

---

## 📝 练习题

1. **YAML 默写**：不看参考，写一个申请 2 张 GPU 的 Pod YAML。包含 nodeSelector 只调度到 A100。

2. **架构口头描述**：用 5 句话描述 GPU Operator 五个组件各自的作用。目标是面试时能不看笔记说清楚。

3. **故障场景推演**：
   - 场景 A：Pod 一直 Pending，`kubectl describe pod` 显示 `0/3 nodes are available: 3 Insufficient nvidia.com/gpu`——什么原因？怎么解决？
   - 场景 B：Pod Running 但 GPU 利用率 0%，日志正常——可能是什么原因？

4. **对比题**：PyTorchJob 和裸 Pod 跑分布式训练，各有什么优缺点？

---

## 📚 延伸阅读

- [NVIDIA GPU Operator 官方文档](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/)
- [Kubeflow Training Operator](https://www.kubeflow.org/docs/components/training/)
- [K8s Device Plugin 机制](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/)
