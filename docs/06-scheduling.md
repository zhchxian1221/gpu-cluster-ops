# 模块 06：GPU 调度系统

> 当你有 32 台 GPU 服务器、30 个人同时提交任务时，谁先用、用几张卡、等多久——这就是调度系统解决的问题。

---

## 📖 概念

### 为什么 K8s 默认调度器搞不定 AI 任务

先理解问题。假设你有 2 个节点，每节点 4 张 GPU，共 8 张卡：

```
节点 A (4 GPU)    节点 B (4 GPU)
[□□□□]           [□□□□]
```

**场景：用户提交一个需要 4 张卡的分布式训练任务。**

K8s 默认调度器的工作方式：

```
时刻 1：Pod-0 需要 1 张 GPU → 调度到节点 A，占 GPU 0
时刻 2：Pod-1 需要 1 张 GPU → 调度到节点 B，占 GPU 0
时刻 3：Pod-2 需要 1 张 GPU → 调度到节点 A，占 GPU 1
时刻 4：Pod-3 需要 1 张 GPU → 调度到节点 B，占 GPU 1

结果：
  节点 A: [■■□□]  4 个 Pod 分布在 2 个节点，看似都有卡用
  节点 B: [■■□□]

但问题来了——这四个 Pod 属于同一个训练任务，它们需要同时运行！
如果某个 Pod 启动慢了，前三个 Pod 占着 GPU 干等着，GPU 全浪费。

更糟的是：如果 Pod-2 因为节点 A 资源不够被 Pending，
则 Pod-0, Pod-1, Pod-3 占着 GPU 等 Pod-2，3 张卡空转。
这个叫"资源死锁"（Gang Scheduling 缺失）。
```

用一句话说：K8s 默认调度器是"一个一个来，谁先到谁先得"。AI 训练需要"**要么一起跑，要么都不跑**"。

---

### 调度的核心概念

| 概念 | 含义 | 类比 |
|------|------|------|
| **Gang Scheduling** | 一组 Pod 要么全部启动，要么全部等待 | 拼车：4 个人必须一起走，少一个都不发车 |
| **Queue** | 任务队列，资源不够时排队 | 银行排队叫号 |
| **Priority** | 优先级，高优先级的先拿资源 | VIP 插队 |
| **Fair-share** | 公平共享，多个团队按权重分 GPU | 食堂分饭，按人头配给 |
| **Preemption** | 抢占，高优先级可以踢掉低优先级任务 | 急诊病人插队，普通病人往后排 |
| **Backfill** | 回填，大任务排队时让小任务先跑 | 前面大桌还没收拾好，2 个人的小桌先坐 |
| **Topology-aware** | 感知 GPU 拓扑，尽量分配同一台机器/同一个 NVSwitch | 4 个人尽量安排同一张桌子 |
| **GPU Sharing** | 多个任务共享同一张 GPU | 拼桌——一个人用不完一整张桌子 |

---

### 三套主流方案

| | Volcano | Slurm | Kueue |
|---|---------|-------|-------|
| 运行在哪 | K8s 之上（CRD + Controller） | 独立守护进程（裸金属） | K8s 之上（CRD + Controller） |
| 适合谁 | K8s 原生 AI 平台 | 传统 HPC 中心 | 新 K8s 集群 |
| 优势 | Gang scheduling、队列、公平共享一条龙 | 成熟稳定，HPC 标准 | 轻量，K8s SIG 官方项目 |
| 劣势 | 重，概念多 | 和 K8s 是两个世界 | 功能不如 Volcano 丰富 |
| 主流用户 | 字节/快手/商汤 | 高校/超算中心 | 新兴云原生团队 |

**现实中的做法**：很多大厂两者都用。Slurm 管裸金属 HPC 集群，Volcano 管 K8s AI 平台。甚至有 Slurm + K8s 混合调度的方案。

---

## 🛠️ Volcano

### 架构

```
┌────────────────────────────────────────────────────┐
│  Volcano                                          │
│                                                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐     │
│  │ vc-scheduler│  │ vc-controller│ │ admission  │     │
│  │  调度器    │  │  控制器     │  │ webhook    │     │
│  │(替换K8s    │  │(管理CRD     │  │(入站校验)  │     │
│  │ 默认调度器)│  │  生命周期)  │  │            │     │
│  └──────────┘  └──────────┘  └──────────────┘     │
│                                                    │
│  核心 CRD:                                         │
│  ┌─────────────────────────────────────────┐       │
│  │ PodGroup     — 一组 Pod 的集合（Gang）       │       │
│  │ Queue        — 任务队列（资源不够就排队）      │       │
│  │ PriorityClass— 优先级                       │       │
│  │ Job          — Volcano 封装的 Job             │       │
│  └─────────────────────────────────────────┘       │
└────────────────────────────────────────────────────┘
```

### 核心概念逐个解释

#### PodGroup —— Gang Scheduling 的实现

```yaml
apiVersion: scheduling.volcano.sh/v1beta1
kind: PodGroup
metadata:
  name: train-job-pg
spec:
  minMember: 4              # ← 核心！至少 4 个 Pod 都就绪才一起跑
  queue: default
  priorityClassName: high-priority
```

```
minMember = 4 是精髓：
  - 如果只有 3 个 Pod 能调度，第 4 个在等 → 前 3 个也等着，不占 GPU
  - 4 个 Pod 都能跑了 → 同时启动，一起开始训练
  - 避免了"3 张 GPU 空转等第 4 张"的死锁
```

#### Queue —— 资源不够时排队

```yaml
apiVersion: scheduling.volcano.sh/v1beta1
kind: Queue
metadata:
  name: team-a
spec:
  weight: 2             # 权重（相对于其他 Queue）
  capability:
    nvidia.com/gpu: "8" # 这个 Queue 最多用 8 张 GPU
  reclaimable: true     # 空闲时可以被其他 Queue 借用
```

```
Queue 解决什么问题？

场景：10 个人同时提交任务，集群只有 8 张卡
  ├── 前 8 张卡 → 分配给最先提交的人
  └── 后面的 → 排队，有卡释放出来自动分配

没有 Queue：后面的人不知道自己排第几、要等多久
有 Queue：能看到队列深度、预估等待时间
```

#### Priority —— 谁先拿资源

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: production
value: 1000                               # 数字越大优先级越高
globalDefault: false
description: "生产任务"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: development
value: 100
description: "开发测试"
```

```
优先级 + 抢占 = 重要任务来了，不那么重要的先让路

例如：凌晨 3 点，开发测试任务在跑
      突然生产环境的评估任务提交了
      → 开发任务被踢（Pod 进入 Evicted 状态）
      → 生产任务立刻跑
      → 开发任务回到队列排队

这个"踢"的动作就叫 Preemption（抢占）
```

### Volcano Job 示例：4 卡分布式训练

```yaml
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: resnet50-train
spec:
  schedulerName: volcano         # ← 用 Volcano 调度器，不是 K8s 默认调度器
  minAvailable: 4                # ← Gang: 4 个 Pod 必须一起跑
  queue: team-a                  # ← 放到 team-a 的队列
  priorityClassName: production  # ← 生产优先级
  tasks:
  - replicas: 1                  # Master 节点（1 个）
    name: master
    template:
      spec:
        containers:
        - name: pytorch
          image: gpu-train:latest
          command: ["torchrun", "--nnodes=2", "--nproc_per_node=2", "train.py"]
          resources:
            requests:
              nvidia.com/gpu: 2  # Master 要 2 张 GPU
            limits:
              nvidia.com/gpu: 2
  - replicas: 1                  # Worker 节点（1 个）
    name: worker
    template:
      spec:
        containers:
        - name: pytorch
          image: gpu-train:latest
          command: ["torchrun", "--nnodes=2", "--nproc_per_node=2", "train.py"]
          resources:
            requests:
              nvidia.com/gpu: 2  # Worker 也要 2 张 GPU
            limits:
              nvidia.com/gpu: 2
```

这个 Job 的行为：
1. 提交到 `team-a` 队列
2. 需要 `minAvailable: 4` = 2 个 Pod × 每 Pod 2 GPU = 4 张 GPU 同时可用
3. 4 张 GPU 不够 → 排队等（不会只拿到 2 张就启动）
4. 4 张 GPU 够了 → 同时启动，一起训练

---

## 🛠️ Slurm（HPC 传统路线）

Slurm 是超算中心的标准调度器。你不需要会部署（光看文档就能劝退），但面试时要知道它和 K8s 的区别。

### 对比：Slurm vs K8s+Volcano

| | Slurm | K8s + Volcano |
|---|-------|---------------|
| 设计年代 | 2002 年 | 2018 年 |
| 调度单位 | Job（批处理任务） | Pod（容器） |
| 生态 | MPI、Lustre、HPC 工具 | Docker、Helm、Prometheus |
| 用户界面 | `srun`、`sbatch` 命令行 | `kubectl`、Dashboard |
| GPU 支持 | `--gpus=4` | `nvidia.com/gpu: 4` |
| 队列 | `partition` + `QoS` | `Queue` CRD |
| Gang | 原生支持（`--nodes=2 --ntasks-per-node=4`） | 需要 Volcano |
| 易用性 | 极陡峭的学习曲线 | Kubernetes 的学习曲线（也不低） |
| 管理 | 手动装机、`pdsh`/`ansible` | K8s 自动化运维 |

### Slurm 核心概念速查

```bash
# 提交一个 2 节点 × 4 GPU 的训练任务
sbatch \
  --nodes=2 \              # 用 2 个节点
  --ntasks-per-node=4 \    # 每节点 4 个任务（= 4 张 GPU）
  --gpus-per-task=1 \      # 每个任务 1 张 GPU
  --partition=gpu \        # 放到 gpu 分区（类似 K8s 的 namespace）
  --qos=high \             # 用 high QoS（高优先级）
  --job-name=resnet50 \    # 任务名
  --output=resnet50_%j.out # 日志文件
  train.sh
```

### Slurm 的分区（Partition）+ QoS 模型

```
集群
├── Partition: training      ← 训练分区（A100 × 32）
│   ├── QoS: urgent           → 紧急任务，墙钟 24h
│   ├── QoS: normal           → 普通任务，墙钟 72h，可抢占
│   └── QoS: scavenge         → 回填任务，随时可能被踢
│
├── Partition: inference      ← 推理分区（T4 × 64）
│   ├── QoS: realtime         → 实时推理，永不排队
│   └── QoS: batch            → 批处理推理
│
└── Partition: debug          ← 调试分区（3090 × 8）
    └── QoS: debug             → 最长跑 2 小时
```

> K8s + Volcano 也可以用 Queue 实现类似模型，但 Slurm 在超算圈深耕了 20 年，对大规模批处理的理解更深。

---

## 🛠️ GPU 共享方案

一张 GPU 很贵，但一个推理任务可能只用 2GB 显存。让 10 个推理任务共享一张卡，利用率从 15% 提到 85%。

### 四种共享方式

| 方式 | 原理 | 隔离性 | 适用场景 |
|------|------|:---:|------|
| **MIG** | 硬件切分（物理隔离） | 🟢 最强 | 推理，A100/H100 专有 |
| **MPS** | CUDA 层面的多进程服务 | 🟡 中等 | 训练 + 推理混合 |
| **Time-slicing** | GPU 时间片轮转 | 🔴 无隔离 | 开发测试，非生产 |
| **HAMi** | vCUDA —— 显存软限制 | 🟡 中等 | 推理，任意 GPU |

### MIG（Multi-Instance GPU）

```
一张 A100-80GB → 切成 7 份 MIG 1g.10gb
  ┌────────────────────────────────┐
  │  MIG 0 (10GB)  │  MIG 4 (10GB) │
  │  MIG 1 (10GB)  │  MIG 5 (10GB) │
  │  MIG 2 (10GB)  │  MIG 6 (10GB) │
  │  MIG 3 (10GB)  │               │
  └────────────────────────────────┘
  7 个容器各用各的，硬件级隔离，互不干扰
```

### HAMi（vCUDA —— 实际最常用）

MIG 只有 A100/H100 支持。HAMi 让 **任意 GPU**（包括 3090/4090）实现显存和算力限制：

```yaml
# Pod 申请 1 张 GPU 但只用一半显存和 30% 算力
resources:
  limits:
    nvidia.com/gpu: 1
    nvidia.com/gpumem: "12000"   # 只给 12GB 显存（HAMi 实现）
    nvidia.com/gpucores: "30"    # 只给 30% 算力（HAMi 实现）
```

> HAMi 不是硬件隔离，是软件拦截 CUDA API 调用做的限制。在生产环境已经大规模使用（字节跳动等）。

---

## 📁 配置速查

### 集群 GPU 配额模板

```yaml
# 按团队分配 GPU 配额
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota-team-a
  namespace: team-a
spec:
  hard:
    nvidia.com/gpu: "8"         # 团队 A 最多 8 张 GPU
    nvidia.com/gpumem: "320"    # 最多 320GB 总显存
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota-team-b
  namespace: team-b
spec:
  hard:
    nvidia.com/gpu: "4"         # 团队 B 最多 4 张 GPU
```

### 防止 GPU 空占

```yaml
# 如果 Pod 30 分钟内 GPU 利用率低于 10%，自动杀掉
# 防止有人申请了 GPU 但不跑任务
# 这个需要额外的监控 + 清理脚本，概念供参考
```

---

## ⚠️ 关键注意事项

### 1. Gang Scheduling 不是免费的

```
Volcano 的 minMember 确保"一起启动"，但副作用是：
  如果集群碎片化严重（很多零散的 GPU 但凑不齐 4 张连续的），
  可能导致长时间等待，即使总空闲 GPU 足够。

缓解方法：
  - 开启 Backfill（碎片利用）
  - 小任务和大任务分队列
  - GPU 拓扑感知调度（尽量紧凑分配）
```

### 2. 抢占可能导致训练白跑

```
Preemption 被抢占的 Pod 会丢失训练进度。
生产环境必须：
  - 训练脚本支持 checkpoint（断点续训）
  - 被踢后从 checkpoint 恢复，而不是从头开始
  - 或者用 Elastic Training（弹性训练）
```

### 3. GPU 共享是双刃剑

```
优势：GPU 利用率大幅提升
劣势：
  - HAMi 限制显存但不限制显存带宽，可能互相影响
  - 一个任务 OOM 可能 OOM 整个共享组
  - 调试困难——"我的任务为什么变慢了"可能是邻居在抢资源
```

---

## 📝 面试要点

1. **为什么 K8s 默认调度器不行**：逐一调度 Pod → GPU 碎片化 + 死锁。AI 训练需要 Gang Scheduling。

2. **Volcano 的核心价值**：Gang Scheduling + Queue + Priority + Fair-share，一套解决 AI 任务调度。

3. **Slurm 和 K8s 的关系**：不是替代，是并存。Slurm 管传统 HPC 裸金属，K8s 管云原生平台。两者各有所长。

4. **GPU 共享的四种方式**：MIG（硬件）> MPS（CUDA级）> HAMi（软件限制）> Time-slicing（无隔离）。

5. **Preemption 的前提**：训练必须有 checkpoint，否则被抢占就白跑了。

6. **碎片化问题**：集群资源够但凑不齐连续 GPU → 需要拓扑感知调度 + Backfill。
