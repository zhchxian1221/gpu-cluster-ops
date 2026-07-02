#!/bin/bash
# ===================================
# gpu-hw-fault.sh — GPU 硬件故障诊断
# 用法: bash gpu-hw-fault.sh
# 场景: 怀疑 GPU 硬件有问题、验收新卡、定期深度体检
# ===================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "  GPU 硬件故障诊断"
echo "  $(date)"
echo "=========================================="
echo ""

FATAL=0
WARN=0

# =============================================
# 1. XID 错误 —— GPU 的"蓝屏"
# =============================================
echo "══════════════════════════════════════════"
echo "  1. XID 错误 (GPU 致命错误)"
echo "══════════════════════════════════════════"
echo ""

XID_OUTPUT=$(dmesg 2>/dev/null | grep -i "NVRM.*Xid" || true)
XID_COUNT=$(echo "$XID_OUTPUT" | grep -c "Xid" || true)

if [ "$XID_COUNT" -eq 0 ] || [ -z "$XID_OUTPUT" ]; then
    echo -e "  ${GREEN}✓ 无 XID 错误${NC}"
else
    echo -e "  ${RED}发现 ${XID_COUNT} 条 XID 错误:${NC}"
    echo ""
    echo "$XID_OUTPUT" | tail -10 | while read -r line; do
        echo "  $line"
    done
    echo ""

    # 提取 XID 编号并判断严重程度
    echo "$XID_OUTPUT" | grep -oP 'Xid\s*[:\s]*\K\d+' | while read -r code; do
        case "$code" in
            13) echo -e "    XID $code → ${RED}图形引擎异常，硬件可能损坏，建议 RMA${NC}" ;;
            31) echo -e "    XID $code → ${YELLOW}显存页错误，监控是否频发${NC}" ;;
            43) echo -e "    XID $code → ${RED}GPU 停止响应，可能是供电或散热问题${NC}" ;;
            45) echo -e "    XID $code → ${YELLOW}驱动先发清理（GPU 无响应后强制重置）${NC}" ;;
            48) echo -e "    XID $code → ${RED}双 bit ECC 错误！显存硬件故障，RMA${NC}" ;;
            63) echo -e "    XID $code → ${YELLOW}显存页退役事件，可用显存减少${NC}" ;;
            74) echo -e "    XID $code → ${YELLOW}NVLink 错误，检查 NVLink 连接${NC}" ;;
            79) echo -e "    XID $code → ${RED}GPU fell off the bus！检查 PCIe 供电和接触${NC}" ;;
            92) echo -e "    XID $code → ${RED}高频双 bit ECC 错误，显存严重故障${NC}" ;;
            94) echo -e "    XID $code → ${YELLOW}已隔离的 ECC 错误${NC}" ;;
            119) echo -e "    XID $code → ${YELLOW}温度超限，改善散热${NC}" ;;
            *)  echo -e "    XID $code → 未知错误码，查 https://docs.nvidia.com/deploy/xid-errors/" ;;
        esac
        FATAL=$((FATAL + 1))
    done

    echo ""
    echo "  历史 XID 总数: $XID_COUNT"
    if [ "$XID_COUNT" -gt 10 ]; then
        echo -e "  ${RED}⚠ XID 过于频繁，硬件极可能有故障${NC}"
    fi
fi

echo ""

# =============================================
# 2. ECC 错误
# =============================================
echo "══════════════════════════════════════════"
echo "  2. ECC 显存错误"
echo "══════════════════════════════════════════"
echo ""

nvidia-smi --query-gpu=index,name,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total --format=csv | \
while IFS=',' read -r idx name corrected uncorrected; do
    corrected=$(echo "$corrected" | xargs)
    uncorrected=$(echo "$uncorrected" | xargs)

    if [ "$idx" = "index" ]; then continue; fi

    echo "  GPU$idx ($(echo $name | xargs))"

    if [ "$uncorrected" = "[N/A]" ]; then
        echo -e "    ${GREEN}无 ECC 保护（消费级卡，正常）${NC}"
        return
    fi

    # 可纠正错误
    if [ "$corrected" = "0" ]; then
        echo -e "    可纠正: 0  ${GREEN}✓${NC}"
    elif [ "$corrected" -lt 100 ]; then
        echo -e "    可纠正: $corrected  ${YELLOW}⚠ 少量，观察趋势${NC}"
        WARN=$((WARN + 1))
    elif [ "$corrected" -lt 1000 ]; then
        echo -e "    可纠正: $corrected  ${YELLOW}⚠ 偏多，可能是显存退化前兆${NC}"
        WARN=$((WARN + 1))
    else
        echo -e "    可纠正: $corrected  ${RED}✗ 大量错误！显存在快速退化${NC}"
        FATAL=$((FATAL + 1))
    fi

    # 不可纠正错误
    if [ "$uncorrected" = "0" ]; then
        echo -e "    不可纠正: 0  ${GREEN}✓${NC}"
    else
        echo -e "    不可纠正: $uncorrected  ${RED}✗ 有不可纠正错误！必须关注！${NC}"
        FATAL=$((FATAL + 1))
    fi
done

echo ""

# =============================================
# 3. 退役显存页
# =============================================
echo "══════════════════════════════════════════"
echo "  3. 退役显存页 (永久损坏)"
echo "══════════════════════════════════════════"
echo ""

nvidia-smi --query-gpu=index,retired_pages.single_bit_ecc.count,retired_pages.double_bit.count --format=csv | \
while IFS=',' read -r idx single double; do
    single=$(echo "$single" | xargs)
    double=$(echo "$double" | xargs)

    if [ "$idx" = "index" ]; then continue; fi

    if [ "$single" = "[N/A]" ]; then
        echo "  GPU$idx: 无 ECC，不适用 ✓"
        return
    fi

    if [ "$single" = "0" ] && [ "$double" = "0" ]; then
        echo -e "  GPU$idx: 无退役页  ${GREEN}✓${NC}"
    else
        echo -e "  GPU$idx: 单 bit=${single}  双 bit=${double}  ${RED}✗ 有退役页！${NC}"
        echo "    → 显存有永久坏块，退役页不可恢复"
        echo "    → 如果持续增长，显存在加速损坏，建议 RMA"
        FATAL=$((FATAL + 1))
    fi
done

echo ""

# =============================================
# 4. PCIe 信号质量
# =============================================
echo "══════════════════════════════════════════"
echo "  4. PCIe 信号质量"
echo "══════════════════════════════════════════"
echo ""

nvidia-smi --query-gpu=index,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max,pcie.replay_counter --format=csv | \
while IFS=',' read -r idx gen width gen_max width_max replay; do
    gen=$(echo "$gen" | xargs)
    width=$(echo "$width" | xargs)
    gen_max=$(echo "$gen_max" | xargs)
    width_max=$(echo "$width_max" | xargs)
    replay=$(echo "$replay" | xargs)

    if [ "$idx" = "index" ]; then continue; fi

    echo "  GPU$idx: 当前 Gen${gen} x${width} / 最大 Gen${gen_max} x${width_max}"

    # 降速检查
    if [ "$gen" != "$gen_max" ] || [ "$width" != "$width_max" ]; then
        echo -e "    ${YELLOW}⚠ 链路降速${NC}"
        echo "    → GPU 空闲时会自动降到 Gen1 省电，有负载应恢复"
        echo "    → 如果负载下也不恢复 → 检查物理连接、BIOS、PCIe 插槽"
    else
        echo -e "    速率正常 ${GREEN}✓${NC}"
    fi

    # 重放计数
    if [ "$replay" = "[N/A]" ]; then
        echo "    重放: N/A"
    elif [ "$replay" = "0" ]; then
        echo -e "    重放: 0  ${GREEN}✓${NC}"
    else
        echo -e "    重放: $replay  ${RED}✗ PCIe 信号有问题！${NC}"
        echo "    → 数据在 PCIe 链路上传输出错需要重传"
        echo "    → 检查：PCIe 线缆、插槽接触、主板、电磁干扰"
        FATAL=$((FATAL + 1))
    fi
done

echo ""

# =============================================
# 5. GPU 掉卡检测
# =============================================
echo "══════════════════════════════════════════"
echo "  5. GPU 掉卡检测 (Fell off bus)"
echo "══════════════════════════════════════════"
echo ""

FELL_OFF=$(dmesg 2>/dev/null | grep -i "fell off the bus" || true)
if [ -z "$FELL_OFF" ]; then
    echo -e "  ${GREEN}✓ 无掉卡记录${NC}"
else
    echo -e "  ${RED}✗ GPU 曾经从 PCIe 总线上掉下！${NC}"
    echo "  $FELL_OFF"
    echo "  → 常见原因：电源供电不足、GPU过热、PCIe插槽接触不良、主板故障"
    FATAL=$((FATAL + 1))
fi

echo ""

# =============================================
# 6. 温度极值检查
# =============================================
echo "══════════════════════════════════════════"
echo "  6. 温度评估"
echo "══════════════════════════════════════════"
echo ""

nvidia-smi --query-gpu=index,temperature.gpu --format=csv,noheader | \
while IFS=',' read -r idx temp; do
    temp=$(echo "$temp" | xargs | tr -d ' C')
    if [ "$idx" = "index" ]; then continue; fi
    if [ -z "$temp" ]; then temp=0; fi

    if [ "$temp" -ge 90 ]; then
        echo -e "  GPU$idx: ${temp}°C  ${RED}✗ 极端高温！GPU 有损坏风险${NC}"
        FATAL=$((FATAL + 1))
    elif [ "$temp" -ge 85 ]; then
        echo -e "  GPU$idx: ${temp}°C  ${YELLOW}⚠ 偏高，检查散热${NC}"
        WARN=$((WARN + 1))
    elif [ "$temp" -ge 70 ]; then
        echo -e "  GPU$idx: ${temp}°C  ${GREEN}✓ 满载正常范围${NC}"
    else
        echo -e "  GPU$idx: ${temp}°C  ${GREEN}✓ 正常（空载或轻载）${NC}"
    fi
done

echo ""

# =============================================
# 7. 功耗异常
# =============================================
echo "══════════════════════════════════════════"
echo "  7. 功耗检查"
echo "══════════════════════════════════════════"
echo ""

nvidia-smi --query-gpu=index,power.draw,power.limit --format=csv,noheader | \
while IFS=',' read -r idx draw limit; do
    draw=$(echo "$draw" | xargs | tr -d ' W')
    limit=$(echo "$limit" | xargs | tr -d ' W')

    if [ "$idx" = "index" ]; then continue; fi
    if [ -z "$draw" ]; then draw=0; fi
    if [ -z "$limit" ]; then limit=1; fi

    echo "  GPU$idx: 功耗 ${draw}W / 上限 ${limit}W"

    if [ "$limit" -eq 0 ] || [ "$limit" = "[N/A]" ]; then
        echo "    → 无法读取功耗上限"
    elif [ "$draw" -eq 0 ]; then
        echo "    → 当前空载"
    fi

    # 功耗上限是否异常低（比如硬件故障被限制到很低）
    if [ "$limit" -ne 0 ] && [ "$limit" != "[N/A]" ] && [ "$limit" -lt 100 ]; then
        echo -e "    ${RED}✗ 功耗上限异常低 (${limit}W)！可能是供电故障${NC}"
        FATAL=$((FATAL + 1))
    fi
done

echo ""

# =============================================
# 8. NVLink 错误（多卡）
# =============================================
GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
if [ "$GPU_COUNT" -ge 2 ]; then
    echo "══════════════════════════════════════════"
    echo "  8. NVLink 错误"
    echo "══════════════════════════════════════════"
    echo ""

    # 用 nvidia-smi 检查 NVLink 状态
    nvidia-smi nvlink -s 2>/dev/null | head -40 || echo "  无法读取 NVLink 状态（可能不支持）"

    echo ""
fi

# =============================================
# 总结
# =============================================
echo "══════════════════════════════════════════"
echo "  诊断结论"
echo "══════════════════════════════════════════"
echo ""

if [ "$FATAL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo -e "  ${GREEN}✓ 未发现硬件故障，GPU 状态健康${NC}"
elif [ "$FATAL" -eq 0 ]; then
    echo -e "  ${YELLOW}⚠ 发现 ${WARN} 个警告，建议持续监控${NC}"
else
    echo -e "  ${RED}✗ 发现 ${FATAL} 个严重问题 + ${WARN} 个警告${NC}"
    echo ""
    echo "  严重问题列表："
    echo "  ────────────"
    echo "  1. 检查是否仍在保修期，收集诊断数据"
    echo "  2. 运行 nvidia-bug-report.sh 生成完整报告"
    echo "     sudo nvidia-bug-report.sh"
    echo "  3. 联系 NVIDIA 或 OEM 供应商"
    echo "  4. 对于显存类错误（XID 48/92/63），基本确定要 RMA"
    echo "  5. 对于 PCIe 类错误（XID 79），先检查物理连接再申请 RMA"
fi

echo ""
echo "  建议的下一步："
echo "  ──────────────"
echo "  验收新卡   → bash gpu-stress.sh 3600 (跑 1 小时)"
echo "  日常巡检   → bash gpu-hw-fault.sh > /tmp/gpu_hw_$(date +%Y%m%d).log"
echo "  完整诊断   → bash gpu-diag-slow.sh (性能+硬件一起查)"
echo "  生成报告   → sudo nvidia-bug-report.sh (生成给 NVIDIA 看的完整日志)"
echo ""
echo "=========================================="
