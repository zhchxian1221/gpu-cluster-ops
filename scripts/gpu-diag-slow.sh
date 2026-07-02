#!/bin/bash
# ===================================
# gpu-diag-slow.sh — 训练慢/GPU 性能问题诊断
# 用法: bash gpu-diag-slow.sh
# 思路: 逐层排查，从 GPU → 显存 → 通信 → 散热 → 软件
# ===================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "  GPU 性能诊断 — 训练为什么慢"
echo "  $(date)"
echo "=========================================="
echo ""

ISSUES=0

# =============================================
# 第 1 层：GPU 在干活吗？
# =============================================
echo "══════════════════════════════════════════"
echo "  第 1 层：GPU 利用率"
echo "══════════════════════════════════════════"
echo ""

nvidia-smi --query-gpu=index,utilization.gpu,utilization.memory --format=csv,noheader | \
while IFS=',' read -r idx gpu_util mem_util; do
    gpu_util=$(echo "$gpu_util" | xargs | tr -d ' %')
    mem_util=$(echo "$mem_util" | xargs | tr -d ' %')

    if [ "$idx" = "index" ]; then continue; fi

    if [ -z "$gpu_util" ]; then gpu_util=0; fi
    if [ -z "$mem_util" ]; then mem_util=0; fi

    if [ "$gpu_util" -ge 80 ]; then
        echo -e "  GPU${idx}: SM 利用率 ${gpu_util}%  ${GREEN}✓ GPU 在满载工作${NC}"
        echo "    → GPU 不是瓶颈，跳第 6 层"
    elif [ "$gpu_util" -ge 30 ]; then
        echo -e "  GPU${idx}: SM 利用率 ${gpu_util}%  ${YELLOW}⚠ 中等负载${NC}"
        echo "    → 可能 batch size 不够大，或数据喂得不够快"
    else
        echo -e "  GPU${idx}: SM 利用率 ${gpu_util}%  ${RED}✗ GPU 在空转！${NC}"
        echo "    → GPU 在等什么——继续排查下层"
    fi
done

echo ""

# =============================================
# 第 2 层：显存够吗？
# =============================================
echo "══════════════════════════════════════════"
echo "  第 2 层：显存使用"
echo "══════════════════════════════════════════"
echo ""

nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader | \
while IFS=',' read -r idx used total; do
    used=$(echo "$used" | xargs | tr -d ' MiB')
    total=$(echo "$total" | xargs | tr -d ' MiB')

    if [ "$idx" = "index" ]; then continue; fi

    if [ -z "$used" ]; then used=0; fi
    if [ -z "$total" ]; then total=1; fi

    pct=$((used * 100 / total))

    if [ "$pct" -ge 95 ]; then
        echo -e "  GPU${idx}: ${used}/${total} MiB (${pct}%)  ${RED}✗ 显存快满了！${NC}"
        echo "    → batch size 太大？有其他进程占着显存？"
        echo "    → 跑: bash gpu-process.sh 看谁在占显存"
    elif [ "$pct" -ge 70 ]; then
        echo -e "  GPU${idx}: ${used}/${total} MiB (${pct}%)  ${GREEN}✓ 显存利用充分${NC}"
    elif [ "$pct" -ge 10 ]; then
        echo -e "  GPU${idx}: ${used}/${total} MiB (${pct}%)  ${YELLOW}⚠ 显存利用偏低${NC}"
        echo "    → batch size 太小？模型太小？"
    else
        echo -e "  GPU${idx}: ${used}/${total} MiB (${pct}%)  ${YELLOW}⚠ 基本没用显存${NC}"
        echo "    → 训练任务真的在跑吗？"
    fi
done

echo ""

# =============================================
# 第 3 层：频率有没有被压？
# =============================================
echo "══════════════════════════════════════════"
echo "  第 3 层：降频检查"
echo "══════════════════════════════════════════"
echo ""

nvidia-smi --query-gpu=index,clocks_throttle_reasons.active,clocks.sm,clocks.max.sm --format=csv,noheader | \
while IFS=',' read -r idx throttle sm_clock max_clock; do
    throttle=$(echo "$throttle" | xargs)
    sm_clock=$(echo "$sm_clock" | xargs | tr -d ' MHz')
    max_clock=$(echo "$max_clock" | xargs | tr -d ' MHz')

    if [ "$idx" = "index" ]; then continue; fi

    if [ "$throttle" = "0x0000000000000000" ] || [ "$throttle" = "0x0" ] || [ -z "$throttle" ]; then
        echo -e "  GPU${idx}: 频率 ${sm_clock}/${max_clock} MHz  ${GREEN}✓ 无降频${NC}"
    else
        echo -e "  GPU${idx}: 频率 ${sm_clock}/${max_clock} MHz  ${RED}✗ 降频中！${NC}"
        echo "    降频原因码: $throttle"

        # 解码常见降频原因
        # 0x1 = gpu_idle, 0x2 = applications_clocks_setting, 0x4 = sw_power_cap
        # 0x8 = hw_slowdown, 0x10 = sync_boost, 0x20 = sw_thermal_slowdown
        # 0x80 = hw_thermal_slowdown, 0x200 = hw_power_brake_slowdown
        DEC_VAL=$((throttle))
        if [ $((DEC_VAL & 0x4)) -ne 0 ]; then
            echo "    → 功耗上限限制 (sw_power_cap)，检查是否设了功率上限"
        fi
        if [ $((DEC_VAL & 0x8)) -ne 0 ]; then
            echo "    → ⚠ 硬件降频 (hw_slowdown)，供电不足或主板 VRM 过热"
        fi
        if [ $((DEC_VAL & 0x20)) -ne 0 ]; then
            echo "    → ⚠ 软件过热降频 (sw_thermal_slowdown)，检查散热！"
        fi
        if [ $((DEC_VAL & 0x80)) -ne 0 ]; then
            echo "    → ❌ 硬件过热保护 (hw_thermal_slowdown)，散热严重不足！"
        fi
        if [ $((DEC_VAL & 0x200)) -ne 0 ]; then
            echo "    → ❌ 供电保护降频 (hw_power_brake)，电源可能有问题"
        fi
    fi
done

echo ""

# =============================================
# 第 4 层：温度正常吗？
# =============================================
echo "══════════════════════════════════════════"
echo "  第 4 层：温度检查"
echo "══════════════════════════════════════════"
echo ""

nvidia-smi --query-gpu=index,temperature.gpu,power.draw,power.limit --format=csv,noheader | \
while IFS=',' read -r idx temp power power_limit; do
    temp=$(echo "$temp" | xargs | tr -d ' C')
    power=$(echo "$power" | xargs | tr -d ' W')
    power_limit=$(echo "$power_limit" | xargs | tr -d ' W')

    if [ "$idx" = "index" ]; then continue; fi

    if [ -z "$temp" ]; then temp=0; fi

    if [ "$temp" -ge 85 ]; then
        echo -e "  GPU${idx}: ${temp}°C  ${RED}✗ 温度过高！${NC}"
        echo "    → 检查机箱风道、风扇转速、环境温度"
    elif [ "$temp" -ge 75 ]; then
        echo -e "  GPU${idx}: ${temp}°C  ${YELLOW}⚠ 温度偏高${NC}"
        echo "    → 满载时正常，但需关注趋势"
    else
        echo -e "  GPU${idx}: ${temp}°C  功耗 ${power}/${power_limit}W  ${GREEN}✓ 正常${NC}"
    fi
done

echo ""

# =============================================
# 第 5 层：有其他进程抢 GPU 吗？
# =============================================
echo "══════════════════════════════════════════"
echo "  第 5 层：GPU 进程"
echo "══════════════════════════════════════════"
echo ""

PROCS=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null)
if [ -z "$PROCS" ]; then
    echo -e "  ${GREEN}✓ 无其他 GPU 进程${NC}"
else
    PROC_COUNT=$(echo "$PROCS" | wc -l)
    echo "  当前 ${PROC_COUNT} 个 GPU 进程:"
    echo ""
    echo "  PID       进程名                        显存"
    echo "  --------  ----------------------------  ----------"
    echo "$PROCS" | while IFS=',' read -r pid name mem; do
        printf "  %-10s %-30s %s\n" "$(echo $pid | xargs)" "$(echo $name | xargs)" "$(echo $mem | xargs)"
    done
    echo ""
    if [ "$PROC_COUNT" -gt 2 ]; then
        echo -e "  ${RED}✗ 多个进程抢占 GPU，可能互相影响！${NC}"
        echo "    → 如果这些不是你期望的训练进程，考虑杀掉"
    fi
fi

echo ""

# =============================================
# 第 6 层：硬件有没有故障信号？
# =============================================
echo "══════════════════════════════════════════"
echo "  第 6 层：硬件故障信号"
echo "══════════════════════════════════════════"
echo ""

# XID 检查
XID=$(dmesg 2>/dev/null | grep -i "NVRM.*Xid" | tail -3 || true)
if [ -n "$XID" ]; then
    echo -e "  ${RED}✗ 发现 XID 错误:${NC}"
    echo "$XID"
else
    echo -e "  ${GREEN}✓ 无 XID 错误${NC}"
fi

# ECC 检查
ECC=$(nvidia-smi --query-gpu=index,ecc.errors.uncorrected.volatile.total --format=csv,noheader 2>/dev/null)
if [ -n "$ECC" ]; then
    ECC_VAL=$(echo "$ECC" | head -1 | xargs)
    if [ "$ECC_VAL" != "0" ] && [ "$ECC_VAL" != "[N/A]" ]; then
        echo -e "  ${RED}✗ 不可纠正 ECC 错误: $ECC_VAL${NC}"
    else
        echo -e "  ${GREEN}✓ 无 ECC 错误${NC}"
    fi
fi

# PCIe 重放
REPLAY=$(nvidia-smi --query-gpu=index,pcie.replay_counter --format=csv,noheader 2>/dev/null | head -1 | xargs)
if [ "$REPLAY" != "0" ] && [ "$REPLAY" != "[N/A]" ]; then
    echo -e "  ${YELLOW}⚠ PCIe 重放计数: $REPLAY (信号质量可能有问题)${NC}"
else
    echo -e "  ${GREEN}✓ PCIe 重放正常${NC}"
fi

echo ""

# =============================================
# 总结
# =============================================
echo "══════════════════════════════════════════"
echo "  诊断总结"
echo "══════════════════════════════════════════"
echo ""
echo "  常见问题 → 排查方向："
echo "  ─────────────────────────────────"
echo "  GPU 利用率低  → batch size 太小，或 dataloader 太慢(num_workers不够)"
echo "  显存快满      → batch size 太大，降低；或清理其他 GPU 进程"
echo "  利用率忽高忽低 → 数据加载是瓶颈，加 num_workers、用 SSD、检查预处理"
echo "  温度高 + 降频 → 检查散热：风扇、风道、环境温度、灰尘"
echo "  多卡利用率不均 → NCCL 通信瓶颈（见模块 7），或负载不均衡"
echo "  GPU 掉卡      → dmesg 看 XID 79，检查电源线、PCIe 插槽、供电"
echo "  一切正常但慢   → 模型本身的算力需求，考虑换更快 GPU 或优化模型"
echo ""
echo "  下一步："
echo "  - 怀疑数据瓶颈 → bash gpu-watch.sh 实时观察利用率波动"
echo "  - 怀疑硬件问题 → bash gpu-stress.sh 300 跑 5 分钟压力测试"
echo "  - 怀疑通信瓶颈 → bash gpu-topo.sh 看拓扑，确认 NVLink 状态"
echo ""
echo "=========================================="
