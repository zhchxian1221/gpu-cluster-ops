# 模块 05：Kubernetes GPU Operator

> **目标**：从零开始，理解 K8s 是什么、Helm 是什么、GPU Operator 怎么把 GPU 变成 K8s 能管理的资源、能写出 GPU Pod 的 YAML 配置。
>
> **环境限制**：AutoDL 是容器无法装 K8s，本模块以概念 + YAML 逐行解读为主。有 K8s 集群后命令直接可用。

---

## 📖 第一部分：K8s 是什么——从你熟悉的东西开始

### 5.0.1 先不管 GPU，K8s 本身是干什么的

你在公司管过物理服务器和 Ubuntu 系统。想象这个场景：

```
你公司在 3 台物理服务器上跑了 10 个应用：
  - Nginx（Web 服务器）
  - MySQL（数据库）
  - Redis（缓存）
  - 用户系统（Java 应用）
  - 订单系统（Java 应用）
  - 报表系统（Python 应用）
  - ...

你的管理方式：
  1. SSH 到每台机器
  2. 手动装依赖（Java、Python、MySQL...）
  3. 手动启动应用（systemctl start xxx）
  4. 如果一台机器挂了 → 人工发现 → 人工迁移 → 人工重启
  5. 如果某个应用流量大了 → 人工加机器 → 人工部署

问题：
  - 10 个应用你还能管，100 个应用呢？
  - 凌晨 3 点机器挂了，你睡醒才知道
  - 每个应用的依赖不同，装在同一台机器上天天冲突
```

**K8s 的思路**：把你所有的服务器变成一个大池子，你告诉 K8s"我要运行 Nginx，需要 1 核 CPU、512MB 内存、跑 2 个副本"，K8s 自动找合适的机器、自动部署、挂了自动重启。

```
传统运维（你现在的做法）：         K8s 做法：
  手动选机器                       自动选节点
  手动装依赖                       容器镜像自包含
  手动启动进程                     声明期望状态
  人工监控和恢复                    自动健康检查和重启
```

### 5.0.2 K8s 的核心概念——用你熟悉的 IT 知识类比

| K8s 概念 | 一句话解释 | 你熟悉的类比 |
|----------|-----------|-------------|
| **Node** | 一台物理服务器或虚拟机 | 就是一台 Ubuntu 服务器 |
| **Pod** | 一个或几个容器的组合，是最小的调度单位 | 相当于一个"应用实例"，里面跑着 Docker 容器 |
| **Deployment** | 管理 Pod 的副本数量、更新策略 | 相当于 systemd service，保证"这个应用永远跑着 N 个副本" |
| **DaemonSet** | 确保每个 Node 上都跑一个 Pod | 相当于你每台机器都装了 `sshd`，DaemonSet 就是保证这一点 |
| **Job** | 跑一次就退出的任务 | 相当于 `cron` 的一次性任务 |
| **Service** | 给 Pod 一个固定的网络入口 | 相当于 Nginx 的反向代理，把流量转发到后端应用 |
| **Namespace** | 资源隔离的逻辑分组 | 相当于 VLAN——不同 Namespace 里的东西默认互相看不见 |
| **Label** | 给对象贴的标签（key=value） | 相当于你给交换机端口写的描述 "VLAN 10, 财务部" |
| **Taint/Toleration** | 污点和容忍 | 相当于"这间机房噪音大，只有戴耳塞的员工能进"——噪音=污点，耳塞=容忍 |
| **CRD** | 自定义资源，扩展 K8s API | 相当于你给监控系统自定义了一个告警规则格式 |

### 5.0.3 一个 Pod 从"声明"到"运行"发生了什么——理解调度

```
你执行: kubectl apply -f my-pod.yaml

步骤 1: YAML 被提交到 K8s API Server（集群的"大脑"）
步骤 2: API Server 把 Pod 信息存到 etcd（集群的"数据库"）
步骤 3: Scheduler（调度器）看到有一个新 Pod 还没分配节点
        → 遍历所有 Node，找满足条件的
        → 选一个最优的，把 Pod "绑定"到那个 Node
步骤 4: 目标 Node 上的 Kubelet（每台机器上的 Agent）检测到新 Pod
        → 拉取镜像
        → 调用容器运行时（containerd）创建容器
        → 启动容器
        → 持续监控，挂了就重启
步骤 5: Pod 状态变成 Running
```

**关键理解**：你从来没有告诉 K8s "在 192.168.1.5 上跑这个 Pod"。你只声明了"我需要 1 核 CPU、512MB 内存"，K8s 自己决定放哪台机器。这就是**声明式管理**——你说要什么，不说怎么做。

---

## 📖 第二部分：Helm 是什么

### 5.0.4 Helm = K8s 的"apt 包管理器"

你已经很熟悉 Ubuntu 的 apt 了：

```
apt 世界：                        Helm 世界：
  apt search nginx                   helm search hub nginx
  apt install nginx                  helm install my-nginx nginx/nginx
  apt upgrade nginx                  helm upgrade my-nginx nginx/nginx
  apt remove nginx                   helm uninstall my-nginx

  /etc/apt/sources.list.d/            helm repo add nvidia https://...
  (APT 仓库地址)                      (Helm 仓库地址)

  dpkg -l                            helm list
  (查看已安装的包)                    (查看已部署的 Chart)
```

**Helm Chart 是什么**：一个 Chart 就是一套打包好的 K8s YAML 文件 + 可配置参数的模板。

```
类比：
  apt 包 = .deb 文件（二进制 + 安装脚本 + 依赖声明）
  Helm Chart = 一堆 K8s YAML 模板 + 可配置的 values.yaml

比如 nvidia/gpu-operator 这个 Chart 里包含：
  - DaemonSet YAML（5 个，对应 5 个组件）
  - Deployment YAML（Operator 控制器）
  - ServiceAccount / ClusterRole YAML（权限配置）
  - ConfigMap YAML（配置参数）
  - values.yaml（你可以改的参数，如 driver.enabled: true/false）

如果不用 Helm → 你需要手动下载 20+ 个 YAML，一个个 kubectl apply
用了 Helm → 一条命令 helm install，而且能 helm upgrade 更新配置
```

---

## 📖 第三部分：K8s 怎么管理 GPU

### 5.1 问题：从 1 台到 100 台 GPU 服务器

你现在有 1 台 GPU 服务器（AutoDL 上的 3090）。你有 0 个问题。

当你有 32 台的时候：

```
问题：
  1. 用户 A 想用 2 张 GPU → 哪台机器有空闲的？
  2. 用户 B 提交了 8 卡训练 → 8 张零散的空闲 GPU 分布在 5 台机器上，凑不齐
  3. 用户 C 的任务把机器搞崩了 → GPU 3 不可用 → 怎么自动换一台？
  4. 用户 D 占着 4 张 GPU 跑了 3 天，但利用率一直是 0%（占着不跑）
  5. 新买了 4 台 H100 → 怎么让系统自动识别，用户不用关心型号？
```

**K8s 的答案**：把所有 GPU 服务器抽象成一个资源池。用户提交 Pod 说"我要 2 张 GPU"，K8s 自动找、自动分配、自动恢复。

### 5.2 GPU 在 K8s 里的资源模型

```
CPU 在你熟悉的 Linux 上是这样管理的：
  服务器有 64 核 → K8s 看到 64 核 → Pod A 申请 2 核 → 剩余 62 核可分配

GPU 同理：
  服务器有 8 张 A100 → K8s 注册 nvidia.com/gpu: 8 → Pod A 申请 2 张 → 剩余 6 张

但关键区别：
  CPU 可以"超分"（一个 64 核机器可以跑 200 个申请 1 核的 Pod）
  GPU 不能超分（一张卡给了 Pod A，Pod B 就不能碰）
  → 所以 K8s 要求 GPU 的 requests 必须等于 limits
```

### 5.3 这需要一个"翻译官"——GPU Device Plugin

K8s 天生不认识 GPU。它只知道 CPU、内存、磁盘。要让它认识 GPU，需要一个**Device Plugin（设备插件）**：

```
K8s 原生只知道：                    GPU Device Plugin 让它知道：
  cpu: 64                           nvidia.com/gpu: 8
  memory: 256Gi                     nvidia.com/gpu.product: A100-SXM4-80GB
  ephemeral-storage: 1Ti            nvidia.com/gpu.memory: 81920

Device Plugin 的工作方式：
  1. 在每个 GPU 节点上作为一个 DaemonSet Pod 运行
  2. 启动时扫描 /dev/nvidia* 和 nvidia-smi 输出
  3. 向 Kubelet（每台机器上的 K8s Agent）注册：我这里有 nvidia.com/gpu 资源
  4. 当 Pod 申请 nvidia.com/gpu: 1 时，Device Plugin 负责把对应的 /dev/nvidiaX 分配给容器
```

---

## 📖 第四部分：GPU Operator——五组件架构

### 5.4 为什么需要一个 Operator，而不是手动装五个东西

你可以手动装：NFD → Driver → Toolkit → Device Plugin → DCGM Exporter，每个都要配，每个版本还要对齐。花了 2 天装好，内核一更新驱动挂了。

**Operator 模式**就是 K8s 世界里的"自动化运维脚本进化版"——你声明你想要的最终状态，Operator 自动把当前状态调整到目标状态。

```
类比你之前搞网络的：

手动装 = 你 SSH 到每台交换机，逐条配 VLAN
Operator = 你写一个全局配置，控制器自动同步到所有交换机

GPU Operator = 一个懂 GPU 软件栈的自动化程序
  "我要每个 GPU 节点上都有：Device Plugin + Toolkit + DCGM Exporter"
  → Operator 自动在每个 GPU 节点上启动对应的 DaemonSet Pod
  → 新节点加入 → Operator 自动发现 → 自动部署组件
  → 组件挂了 → Operator 自动重启
```

### 5.5 五个组件，逐个解释

整个 GPU Operator 由五个 DaemonSet（或类似组件）组成。**DaemonSet 的本质是："每个符合条件的 Node 上，保证跑一个这个 Pod"**。就像你每台服务器都装了 sshd。

```
┌──────────────────────────────────────────────────────────────┐
│  GPU Operator (一个 Helm install 全部部署)                    │
│                                                              │
│  组件1: Node Feature Discovery (NFD)                         │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ 类型: DaemonSet                                        │  │
│  │ 作用: 自动扫描每个节点的硬件特征 → 给 Node 打标签        │  │
│  │                                                        │  │
│  │ 做的事情：                                              │  │
│  │  ls /dev/nvidia* → 发现有 GPU                         │  │
│  │  nvidia-smi --query-gpu → 读到型号、显存、数量          │  │
│  │  → 生成标签:                                           │  │
│  │    nvidia.com/gpu.present=true                         │  │
│  │    nvidia.com/gpu.product=A100-SXM4-80GB               │  │
│  │    nvidia.com/gpu.count=8                              │  │
│  │    nvidia.com/gpu.memory=81920                         │  │
│  │                                                        │  │
│  │ 类比: 你买了一台新服务器，自动在 CMDB 里登记了配置        │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  组件2: NVIDIA Driver Container (可选, DaemonSet)            │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ 类型: DaemonSet                                        │  │
│  │ 作用: 自动在每个 GPU 节点上编译并安装 NVIDIA 驱动        │  │
│  │                                                        │  │
│  │ 做的事情：                                              │  │
│  │  下载驱动源码 → 编译成 .ko 内核模块 → 加载              │  │
│  │                                                        │  │
│  │ ⚠️ 运维建议:                                           │  │
│  │  生产环境通常在物理装机时手动装好驱动+DKM，              │  │
│  │  然后关掉这个组件: --set driver.enabled=false          │  │
│  │  原因: 内核更新后自动编译可能失败，手动更可控            │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  组件3: NVIDIA Container Toolkit (DaemonSet)                 │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ 类型: DaemonSet                                        │  │
│  │ 作用: 配置 K8s 节点的容器运行时，让它能识别 GPU         │  │
│  │                                                        │  │
│  │ 做的事情：                                              │  │
│  │  编辑 /etc/containerd/config.toml                      │  │
│  │  → 添加 nvidia-container-runtime 作为 GPU 容器运行时   │  │
│  │                                                        │  │
│  │ 类比: 你配 Nginx 让它知道 PHP 解释器在哪               │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  组件4: GPU Device Plugin (DaemonSet)                        │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ 类型: DaemonSet                                        │  │
│  │ 作用: 向 K8s 注册 "nvidia.com/gpu" 这种资源             │  │
│  │                                                        │  │
│  │ 这是整个 GPU Operator 的核心。没有它:                   │  │
│  │  kubectl describe node gpu-node → 看不到 GPU 资源      │  │
│  │  Pod 无法申请 nvidia.com/gpu                          │  │
│  │                                                        │  │
│  │ 做的事情：                                              │  │
│  │  1. 扫描本机 GPU（调用 nvidia-smi）                    │  │
│  │  2. 通过 Unix Socket 向 Kubelet 注册资源               │  │
│  │  3. 持续监控 GPU 数量变化（MIG 启用后数量会变）         │  │
│  │  4. Pod 请求 GPU 时，把 /dev/nvidiaX 分配给它          │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  组件5: DCGM Exporter (DaemonSet)                            │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ 类型: DaemonSet                                        │  │
│  │ 作用: 把 GPU 指标暴露成 Prometheus 格式                 │  │
│  │ 端口: :9400/metrics                                   │  │
│  │                                                        │  │
│  │ 暴露的指标:                                            │  │
│  │  DCGM_FI_DEV_GPU_UTIL → GPU 利用率                     │  │
│  │  DCGM_FI_DEV_MEM_COPY_UTIL → 显存带宽利用率            │  │
│  │  DCGM_FI_DEV_GPU_TEMP → 温度                           │  │
│  │  DCGM_FI_DEV_POWER_USAGE → 功耗                        │  │
│  │  DCGM_FI_DEV_ECC_CURRENT → ECC 错误                    │  │
│  │  (共 200+ 指标)                                        │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

---

## 🛠️ 动手实验

### 实验 1：逐行解读 GPU Operator 部署命令

你现在没有 K8s 集群，但每行命令你都能理解。

```bash
# ===== 第一步：添加 NVIDIA Helm 仓库 =====
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
# 拆解:
# helm     = K8s 的包管理器（前面解释过，类比 apt）
# repo     = 仓库（repository），存着一堆 Chart 的服务器
# add      = 添加一个仓库
# nvidia   = 你给这个仓库起的本地别名（跟 apt source 的命名一样）
# URL      = NVIDIA 官方的 Helm Chart 托管地址
#            NGC = NVIDIA GPU Cloud，NVIDIA 的容器和 Chart 注册中心

# 这行命令做了什么：
#   在你的电脑上（~/.config/helm/repositories.yaml）记了一笔：
#   "nvidia 这个名称 → 指向 https://helm.ngc.nvidia.com/nvidia"

# 类比:
#   echo "deb https://helm.ngc.nvidia.com/nvidia stable main" \
#     > /etc/apt/sources.list.d/nvidia.list
#   (这就是 apt 世界的 "添加仓库")

helm repo update
# 拉取最新的 Chart 索引文件
# 类比: apt update —— 不执行这步，helm install 可能装到旧版本

# 查看 nvidia 仓库里有哪些 Chart
helm search repo nvidia
# 你应该看到 gpu-operator 在列表里

# ===== 第二步：安装 GPU Operator =====
helm install --wait --generate-name \
  -n gpu-operator --create-namespace \
  nvidia/gpu-operator \
  --set driver.enabled=true \
  --set operator.defaultRuntime=containerd

# 逐参数解释：
# helm install        → "安装一个 Chart"
#                        类比: apt install
# --wait              → "等待所有 Pod 都变成 Ready 状态，才返回命令提示符"
#                        不加的话, helm 返回很快但 Pod 可能还在启动中
#                        类比: apt install 等 dpkg 配置完成，不等的话你不知道装好没
# --generate-name     → "自动生成一个部署名称"
#                        如 gpu-operator-1688000000
#                        不加的话你需要手动指定: helm install my-gpu-op nvidia/gpu-operator
# -n gpu-operator     → 安装到名为 gpu-operator 的命名空间（Namespace）
#                        -n = --namespace
#                        类比: 把应用装到哪个 VLAN / 网段
# --create-namespace  → 如果 gpu-operator 这个命名空间不存在 → 自动创建
# nvidia/gpu-operator → "从 nvidia 仓库安装 gpu-operator 这个 Chart"
#                        类比: apt install nginx（从你先前添加的 ubuntu 仓库装 nginx）
# --set driver.enabled=true → 让 Operator 自动安装 NVIDIA 驱动
#                             如果你已经手动装了驱动 → --set driver.enabled=false
# --set operator.defaultRuntime=containerd → 告诉 Operator 你的 K8s 用的是 containerd
#   K8s 1.24 之前的版本用 Docker 作为容器运行时
#   K8s 1.24+ 默认用 containerd（不再用 Docker）
#   这个参数影响 Toolkit 怎么配置容器运行时
```

### 实验 2：理解 K8s 节点——GPU 信息变成了 Label

部署完 GPU Operator 后，你在 K8s 里看到的 GPU 节点会长这样：

```bash
# 查看所有节点
kubectl get nodes
# NAME           STATUS   ROLES    AGE   VERSION
# gpu-node-01    Ready    <none>   1d    v1.28.0
# gpu-node-02    Ready    <none>   1d    v1.28.0

# 查看某个节点的 GPU 标签
kubectl describe node gpu-node-01 | grep nvidia
```

```
# 输出（逐行解释）:

nvidia.com/gpu.present=true
  → 这个节点有 GPU（NFD 自动发现的）

nvidia.com/gpu.product=A100-SXM4-80GB
  → GPU 具体型号（用于 Pod 选择器：只要 A100 不要 3090）

nvidia.com/gpu.count=8
  → 这个节点有 8 张 GPU

nvidia.com/gpu.memory=81920
  → 每张卡 81920 MiB = 80GB 显存

nvidia.com/cuda.driver-version=550.144.01
  → 当前驱动版本

# 资源容量部分：
Capacity:
  cpu:                128
  memory:             1031872Ki
  nvidia.com/gpu:     8       ← 总共有 8 张
Allocatable:
  cpu:                126
  memory:             981056Ki
  nvidia.com/gpu:     8       ← 可分配 8 张
```

**关键理解——Capacity vs Allocatable**：

```
Capacity = 硬件物理容量（8 张卡）
Allocatable = K8s 可以分给 Pod 的量（8 张卡）
两者通常相等（GPU 很少有系统预留）

如果某个 Pod 申请了 2 张：
  Allocatable → 变成 6（动态变化）
  kubectl describe node → 你会看到 nvidia.com/gpu: 6 available
```

### 实验 3：验证 GPU Operator 的所有组件

```bash
kubectl get pods -n gpu-operator
```

```
预期输出（逐行解释每个 Pod）：

NAME                                                  READY   STATUS
gpu-operator-xxxxx                                    1/1     Running
  ↑ 这是一个 Deployment（不是 DaemonSet）
  Operator 控制器本身，运行在某个节点上（不一定是 GPU 节点）
  负责管理其他组件的生命周期

nvidia-container-toolkit-daemonset-xxxxx              1/1     Running
  ↑ DaemonSet，每个 GPU 节点跑一个
  负责配置 containerd 使用 nvidia-container-runtime

nvidia-cuda-validator-xxxxx                           0/1     Completed
  ↑ 这是一个 Job（一次性任务），不是 DaemonSet
  跑完就退出
  作用：验证 CUDA 是否能正常工作
  退出码 0 = 验证通过

nvidia-dcgm-exporter-xxxxx                            1/1     Running
  ↑ DaemonSet，每个 GPU 节点跑一个
  在 :9400/metrics 暴露 Prometheus 格式的 GPU 指标

nvidia-device-plugin-daemonset-xxxxx                  1/1     Running
  ↑ DaemonSet，每个 GPU 节点跑一个
  向 Kubelet 注册 nvidia.com/gpu 资源

nvidia-driver-daemonset-xxxxx                         1/1     Running
  ↑ DaemonSet（仅在 --set driver.enabled=true 时出现）
  负责编译和加载 NVIDIA 驱动

nvidia-operator-validator-xxxxx                       1/1     Running
  ↑ 验证所有组件的配置都正确
```

### 实验 4：提交第一个 GPU Pod——从 YAML 到运行

```yaml
# ============================================
# gpu-test-pod.yaml — 你的第一个 GPU Pod
# 提交: kubectl apply -f gpu-test-pod.yaml
# 看日志: kubectl logs gpu-verify
# 删除: kubectl delete pod gpu-verify
# ============================================

apiVersion: v1
# ↑ K8s API 的版本。v1 是核心 API 组，Pod 属于核心对象

kind: Pod
# ↑ 资源类型。Pod 是最小的调度单位
#   K8s 里常见 kind: Pod, Deployment, DaemonSet, Job, Service, ConfigMap...

metadata:
  name: gpu-verify
  # ↑ Pod 的名称，在同一个 namespace 里必须唯一
spec:
  # ↑ spec = specification，声明这个 Pod "长什么样"

  restartPolicy: Never
  # ↑ 重启策略:
  #   Never       = 容器退出后不重启（跑一次就完）
  #   OnFailure   = 容器报错（退出码非0）才重启
  #   Always      = 永远重启（这是默认值）

  containers:
  # ↑ 这个 Pod 里跑哪些容器。一个 Pod 可以跑多个容器，但通常 1 Pod = 1 容器

  - name: cuda-test
    # ↑ 容器名字（在 Pod 内唯一即可）

    image: nvidia/cuda:12.2-base-ubuntu22.04
    # ↑ Docker 镜像地址
    #   格式: 仓库/镜像名:标签
    #   nvidia/cuda = NVIDIA 官方的 CUDA 镜像
    #   12.2        = CUDA 12.2 版本
    #   base        = 最小体积版（只含 CUDA 运行时，不含 cuDNN 和编译工具）
    #   其他标签: runtime(含cuDNN), devel(含nvcc和头文件)
    #   ubuntu22.04 = 基础是 Ubuntu 22.04

    command: ["nvidia-smi"]
    # ↑ 容器启动后执行的命令
    #   YAML 中 [] 是数组写法
    #   等价于: command: nvidia-smi
    #   容器运行 nvidia-smi → 打印 GPU 信息 → 退出

    resources:
    # ↑ 资源申请。如果不写，K8s 不知道这个 Pod 需要 GPU
    #   没有 GPU → 容器里的 nvidia-smi 会报错 "No devices found"

      limits:
      # ↑ limits = 资源上限
      #   容器最多用这么多

        nvidia.com/gpu: 1
      # ↑ 申请 1 张 GPU
      #   没有写 requests → K8s 自动设 requests = limits = 1
      #   GPU 资源必须 requests == limits（不能超分）
```

**提交后的完整生命周期（每一步都看得见）**：

```bash
# 1. 提交
kubectl apply -f gpu-test-pod.yaml
# → 返回: pod/gpu-verify created

# 2. 立即查看状态
kubectl get pod gpu-verify
# NAME          READY   STATUS    RESTARTS   AGE
# gpu-verify    0/1     Pending   0          2s
# Pending = 等待调度（Scheduler 在找有至少 1 张空闲 GPU 的节点）

# 3. 几秒后再看
kubectl get pod gpu-verify
# gpu-verify    0/1     ContainerCreating   0          5s
# ContainerCreating = 调度完成，正在拉镜像、创建容器

# 4. 再过几秒
kubectl get pod gpu-verify
# gpu-verify    0/1     Completed   0          20s
# Completed = 容器执行完了 nvidia-smi，正常退出

# 5. 看输出
kubectl logs gpu-verify
# 应该看到完整的 nvidia-smi 输出（GPU 型号、驱动版本等）
# 这就是证明：容器里能用 GPU 了！

# 6. 清理
kubectl delete pod gpu-verify
```

### 实验 5：指定 GPU 型号——nodeSelector 和 affinity

如果集群里同时有 A100（¥40/时）和 3090（¥2/时），你不能让生产训练任务跑到 3090 上。

```yaml
# ===== 方式1: nodeSelector（简单直接）=====
apiVersion: v1
kind: Pod
metadata:
  name: gpu-a100-only
spec:
  restartPolicy: Never

  nodeSelector:
  # ↑ nodeSelector = 节点选择器
  #   只有标签匹配的 Node 才会被考虑
  #   相当于: "我只去有这个标签的机器"

    nvidia.com/gpu.product: A100-SXM4-80GB
  # ↑ key: value
  #   标签由 NFD（组件1）自动打的
  #   如果集群里没有 A100 → 这个 Pod 会一直 Pending

  containers:
  - name: test
    image: nvidia/cuda:12.2-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1


# ===== 方式2: affinity（更灵活，支持表达式）=====
apiVersion: v1
kind: Pod
metadata:
  name: gpu-big-only
spec:
  restartPolicy: Never

  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      # ↑ 长名字，拆开看:
      #   requiredDuringScheduling = 调度时必须满足（硬要求）
      #   IgnoredDuringExecution = 运行后如果标签变了也不迁移
      #   还有 preferredDuringScheduling = 优先满足，不满足也能调度（软偏好）

        nodeSelectorTerms:
        - matchExpressions:
          # ↑ 支持更复杂的匹配条件

          - key: nvidia.com/gpu.memory
            operator: Gt
            # ↑ 操作符: Gt = Greater Than（大于）
            #   还有: Lt(小于), In(在列表中), Exists(存在即可), Gte(大于等于)
            values: ["40000"]
            # ↑ 只调度到显存 > 40GB 的节点
            #   40GB = 40000 MiB（nvidia-smi 显存的单位是 MiB）
            #   这过滤掉 3090(24GB)、4090(24GB) 等
            #   保留 A100(40/80GB)、H100(80GB)、A6000(48GB)

          - key: nvidia.com/gpu.count
            operator: Gte
            # ↑ Gte = Greater Than or Equal（大于等于）
            values: ["4"]
            # ↑ 节点上至少有 4 张 GPU
            #   防止 Pod 调度到只有 1-2 张卡的小节点

  containers:
  - name: test
    image: nvidia/cuda:12.2-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 4
      # ↑ 申请 4 张 GPU
      #   K8s 会找"显存>40GB 且 GPU数量≥4 且 空闲GPU≥4" 的节点
```

### 实验 6：GPU 节点隔离——Taint 和 Toleration

这是一个生产环境的经典配置。GPU 节点很贵（一台 A100 服务器几十万），普通 Web 服务 Pod 一定不能调度到 GPU 节点上浪费资源。

**Taint（污点）= "这间机房有噪音"；Toleration（容忍）= "我戴了耳塞，能进"**

```
没有 Taint + Toleration 时：
  Node A (GPU, 贵):  Web-Pod ✓ (可以乱跑)  GPU-Pod ✓
  Node B (CPU, 便宜): Web-Pod ✓            GPU-Pod ✗ (没GPU)

  结果: Web-Pod 可能跑到贵得要死的 GPU 节点上，一张 A100 跑 Nginx
  → 烧钱

加了 Taint + Toleration 后：
  Node A (GPU, Taint: nvidia.com/gpu:NoSchedule)
    → Web-Pod 没 Toleration  → 不能调度 ✗
    → GPU-Pod 有 Toleration  → 能调度 ✓
  Node B (CPU, 无 Taint)
    → Web-Pod  → 能调度 ✓
    → GPU-Pod → 没 GPU，不能调度 ✗

  结果: 各回各家
```

```bash
# ===== 第一步：给 GPU 节点打污点 =====
kubectl taint node gpu-node-01 nvidia.com/gpu=true:NoSchedule
# kubectl taint → 给节点打污点
# node gpu-node-01 → 目标节点
# nvidia.com/gpu=true → 污点的 key=value
# :NoSchedule → 效果：
#   NoSchedule        = 没有容忍度的 Pod 不能调度上来（最常用）
#   PreferNoSchedule  = 尽量不调度（软限制）
#   NoExecute         = 已有的 Pod 也赶走（强制驱逐）
```

```yaml
# ===== 第二步：GPU Pod 声明容忍度 =====
apiVersion: v1
kind: Pod
metadata:
  name: gpu-with-toleration
spec:
  tolerations:
  # ↑ tolerations = 容忍度列表
  #   告诉 K8s: "这些污点我能忍"

  - key: "nvidia.com/gpu"
    operator: "Exists"
    # ↑ operator:
    #   Exists = 只要污点的 key 是 nvidia.com/gpu，不管 value 是什么
    #   Equal  = key 和 value 都必须完全匹配
    effect: "NoSchedule"
    # ↑ 针对 NoSchedule 类型的污点

  # 同时确保只调度到 GPU 节点
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

### 实验 7：PyTorchJob——分布式训练的封装

Kubeflow 是一个 K8s 上的机器学习平台，它提供 PyTorchJob 这个 CRD（自定义资源），封装了 PyTorch 分布式训练的复杂性。

**CRD 是什么**：Custom Resource Definition = 扩展 K8s 的 API，让 K8s 认识新的资源类型。

```
K8s 原生有 Pod, Deployment, Service...
Kubeflow 通过 CRD 添加了 PyTorchJob, TFJob, MPIJob...
Volcano 通过 CRD 添加了 PodGroup, Queue, Job (Volcano版)...

类比：你给监控系统自定义了一个告警规则模板
     CRD 就是给 K8s 自定义了一种新的"资源类型"
```

```yaml
# pytorchjob-demo.yaml
# 需要先装 Kubeflow Training Operator:
# kubectl apply -k "github.com/kubeflow/training-operator/manifests/overlays/standalone"

apiVersion: kubeflow.org/v1
# ↑ 这是 Kubeflow 的 API 组，不是 K8s 核心的 v1
#   kubeflow.org/v1 是由 CRD 注册到 K8s 的

kind: PyTorchJob
# ↑ PyTorchJob 是一种 CRD，不是 K8s 原生的 kind
#   没有装 Kubeflow 的话，kubectl apply 会报 unknown kind

metadata:
  name: train-resnet50
spec:
  pytorchReplicaSpecs:
  # ↑ PyTorch 的副本规格
  #   PyTorch 分布式训练有两种角色：Master（协调者）和 Worker（执行者）

    # ===== Master 副本 =====
    Master:
    # ↑ 训练任务的主节点
    #   负责: 协调所有 Worker、同步梯度、保存 checkpoint

      replicas: 1
      # ↑ Master 只有 1 个

      restartPolicy: OnFailure
      # ↑ Master 挂了自动重启
      #   注意: 训练进度可能丢失，需要 checkpoint 恢复

      template:
      # ↑ Pod 模板，和普通 Pod 的 spec 一样
        spec:
          containers:
          - name: pytorch
            image: pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime
            command:
            - torchrun
            # ↑ PyTorch 分布式训练启动器（1.10+ 版本替代了 torch.distributed.launch）
            - --nnodes=2
            # ↑ 总共 2 个节点（1 Master + 1 Worker）
            - --nproc_per_node=2
            # ↑ 每个节点 2 个进程 = 每节点用 2 张 GPU
            #   总共 4 个进程 = 4 卡并行训练
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
              # ↑ medium: Memory → 挂到内存（tmpfs），不是磁盘
              #   磁盘 I/O 是毫秒级，内存是纳秒级
              #   PyTorch DataLoader 多进程通信依赖这个
              sizeLimit: 16Gi

    # ===== Worker 副本 =====
    Worker:
    # ↑ 训练任务的工作节点
    #   负责: 实际执行计算

      replicas: 1
      # ↑ 1 个 Worker（总共 2 节点，Master + Worker）

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
                nvidia.com/gpu: 2
            volumeMounts:
            - name: dshm
              mountPath: /dev/shm
          volumes:
          - name: dshm
            emptyDir:
              medium: Memory
              sizeLimit: 16Gi
```

**PyTorchJob 自动帮你处理了什么**：

```
如果不用 PyTorchJob，你需要手动写两个 Pod（Master + Worker），然后：
  ✗ 把 Master 的 IP 传给 Worker（环境变量 MASTER_ADDR）
  ✗ 确保 Master 先启动，Worker 后启动
  ✗ Master 挂了要重启，Worker 要重新连接
  ✗ 所有 Worker 都跑完了，要判断 Job 是否成功
  ✗ 跑完后清理所有 Pod

PyTorchJob 自动处理了这些：
  ✓ 自动注入 MASTER_ADDR 和 MASTER_PORT 环境变量
  ✓ Master 先启动，就绪后再起 Worker
  ✓ 挂了自动按 restartPolicy 处理
  ✓ 自动判断 Job 状态（Running/Succeeded/Failed）
  ✓ Job 完成后自动清理（如果配了 ttlSecondsAfterFinished）
```

---

## ✅ 验证步骤

完成本模块后，你应该能回答：

1. **Helm 是什么？** —— K8s 的 apt，一键安装/升级/卸载应用。

2. **DaemonSet 是什么？** —— 确保每个符合条件的 Node 上都跑一个 Pod。GPU Operator 的五个组件里四个是 DaemonSet。

3. **GPU Device Plugin 做什么？** —— 向 K8s 注册 `nvidia.com/gpu` 资源，让 K8s 调度器知道哪台节点有多少空闲 GPU。

4. **Pod 怎么申请 GPU？** —— `resources.limits.nvidia.com/gpu: 2`，requests 必须等于 limits。

5. **怎么区分 A100 和 3090？** —— `nodeSelector: nvidia.com/gpu.product: A100-SXM4-80GB`。

6. **Taint + Toleration 的作用？** —— 防止非 GPU Pod 调度到昂贵的 GPU 节点。

7. **PyTorchJob 比裸 Pod 好在哪里？** —— 自动处理 Master/Worker 协调、环境变量、故障恢复。

---

## ⚠️ 常见陷阱

### 陷阱 1：`/dev/shm` 太小

```
现象：GPU 利用率很低（<30%），DataLoader 极慢，但训练代码正常

原因：K8s 默认 /dev/shm = 64MB，PyTorch DataLoader 多进程需要 GB 级别

解决：Pod 加一个 emptyDir volume 挂到内存
  volumes:
  - name: dshm
    emptyDir:
      medium: Memory
      sizeLimit: 16Gi
```

### 陷阱 2：GPU requests ≠ limits

```yaml
# ❌ 错误 —— K8s 会拒绝这个 Pod
resources:
  requests:
    nvidia.com/gpu: 1
  limits:
    nvidia.com/gpu: 2

# ✅ 正确
resources:
  limits:
    nvidia.com/gpu: 2
  # K8s 自动设 requests = limits = 2
```

### 陷阱 3：Driver Container 编译失败

```
GPU Operator 的自动驱动安装组件（--set driver.enabled=true）
需要编译内核模块（本质是 nvidia.ko）。如果宿主机内核太新、
头文件不对 → 编译失败 → Driver DaemonSet CrashLoopBackOff

生产建议：手动装机时就用 DKMS 装好驱动
          然后 --set driver.enabled=false
```

### 陷阱 4：装了 GPU Operator 但 Pod 还是 Pending

```
kubectl describe pod → 看到 "0/3 nodes are available:
  3 Insufficient nvidia.com/gpu"

可能原因：
  1. 所有 GPU 都被其他 Pod 用完了 → kubectl describe node 看 Allocatable
  2. GPU 节点有 Taint，Pod 没有 Toleration
  3. Pod 的 nodeSelector 不匹配任何节点（如选了 A100 但集群只有 3090）
  4. Device Plugin 没启动 → kubectl get pods -n gpu-operator
```

---

## 📝 练习题

1. **口头陈述**：用 3 分钟说清楚 GPU Operator 五个组件各自的作用。不看笔记，录音自己听一遍。

2. **YAML 改错**：下面这个 Pod YAML 有 3 个错误，找出来：
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: bad-gpu-pod
   spec:
     containers:
     - name: test
       image: nvidia/cuda:12.2-base-ubuntu22.04
       command: nvidia-smi
       resources:
         requests:
           nvidia.com/gpu: 1
         limits:
           nvidia.com/gpu: 2
   ```

3. **场景推演**：Pod 一直 Pending，描述信息是 `0/5 nodes are available: 2 Insufficient nvidia.com/gpu, 3 node(s) had untolerated taint`。说出可能的原因和排查步骤。

4. **对比题**：PyTorchJob 和裸 Pod 跑分布式训练，各有什么优缺点？什么场景你会选哪个？

---

## 📚 延伸阅读

- [NVIDIA GPU Operator 官方文档](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/)
- [K8s Device Plugin 机制](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/)
- [Helm 官方文档](https://helm.sh/docs/)
- [Kubeflow Training Operator](https://www.kubeflow.org/docs/components/training/)
