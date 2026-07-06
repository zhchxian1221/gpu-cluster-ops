# 模块 03：GPU 监控与诊断

> DCGM 部署、GPU 压力测试、故障诊断（XID/ECC/PCIe/散热）。

---

## 四个监控维度

```
计算：GPU 利用率、Tensor Core 利用率、时钟频率
显存：使用量/总量、带宽利用率、温度
通信：PCIe 带宽、NVLink 带宽、重放次数
健康：温度、功耗、ECC 错误、XID 错误、降频原因
```

---

## nvidia-smi vs DCGM

| | nvidia-smi | DCGM |
|---|-----------|------|
| 指标数量 | ~50 | 200+ |
| 历史数据 | ❌ | ✅ |
| Prometheus | 需第三方 | 原生 dcgm-exporter |
| 健康检查 | 手动 | 自动诊断 |
| 集群管理 | ❌ | ✅ |

---

## DCGM 核心操作

```bash
# 安装（NVIDIA 官方仓库）
sudo apt install -y datacenter-gpu-manager

# 启动后台服务（容器环境用 nohup）
sudo nohup nv-hostengine > /tmp/dcgm.log 2>&1 &

# 发现 GPU
dcgmi discovery -l

# 创建 GPU 组并设置健康监控
dcgmi group -c mygpus
dcgmi group -g <组ID> -a 0
dcgmi health -g <组ID> -s a    # 监控所有项
dcgmi health -g <组ID> -c      # 检查健康状态

# 连续监控关键指标
dcgmi dmon -e 1001,1002,155,1009 -d 1
# 1001=SM利用率 1002=显存利用率 155=温度 1009=功耗

# 诊断测试
sudo dcgmi diag -r 2            # Level 2: 中等（5-10分钟）
```

---

## XID 错误速查

| XID | 含义 | 严重程度 |
|:---:|------|:---:|
| 13 | 图形引擎异常 | ❌ 可能 RMA |
| 31 | 显存页错误 | ⚠️ 关注趋势 |
| 48 | 双 bit ECC 错误 | ❌ RMA |
| 63 | 显存页退役 | ⚠️ 显存减少 |
| 74 | NVLink 错误 | ⚠️ 通信问题 |
| 79 | GPU fell off bus | ❌ 掉卡 |
| 92 | 高频双 bit ECC | ❌ RMA |
| 119 | 温度超限 | ⚠️ 改善散热 |

```bash
dmesg | grep -i "NVRM.*Xid"
```

---

## 性能瓶颈诊断流程

```
用户说"训练慢" → 逐层排查：

1. GPU 利用率 < 30%？
   → batch size 太小或 data loader 太慢

2. 显存快满（>95%）？
   → batch size 太大，降低

3. 利用率忽高忽低？
   → 数据加载是瓶颈，加 num_workers

4. 有降频？
   → 检查温度、功耗限制

5. 多卡利用率不均？
   → NCCL 通信瓶颈

6. 一切正常？
   → 模型本身的算力需求
```

---

## 压力测试

```bash
# PyTorch 就地压测（无需额外工具）
python3 -c "
import torch, time
size = 5000
a = torch.randn(size, size, device='cuda')
b = torch.randn(size, size, device='cuda')
print('Burning 60s...')
start = time.time()
while time.time() - start < 60:
    torch.mm(a, b)
print('Done, no errors')
"
```

---

## 关键告警阈值

| 指标 | 警告 | 严重 |
|------|:---:|:---:|
| GPU 温度 | >80°C | >85°C |
| 不可纠正 ECC | >0 | 持续增长 |
| PCIe 重放 | >100 | >1000 |
| 退役显存页 | >0 | 持续增长 |
| XID 错误 | 任意 | 48/79/92 |
