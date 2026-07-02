#!/bin/bash
# ============================================================
# GPU 健康巡检脚本
# 用途：快速检查 GPU 节点的核心健康指标
# 用法：bash health-check.sh
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================"
echo "  GPU 健康巡检 - $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

# 1. 检查驱动
echo "[1/6] 检查 NVIDIA 驱动..."
if nvidia-smi > /dev/null 2>&1; then
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    echo -e "  ${GREEN}✓${NC} 驱动正常 (版本: ${DRIVER_VER})"
else
    echo -e "  ${RED}✗${NC} 驱动异常！nvidia-smi 无法运行"
    exit 1
fi

# 2. GPU 基本信息
echo "[2/6] GPU 设备信息..."
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
echo "  数量: ${GPU_COUNT}"
nvidia-smi --query-gpu=index,name,temperature.gpu,power.draw,power.limit,utilization.gpu,memory.used,memory.total \
    --format=csv,noheader | while IFS=',' read -r idx name temp power power_limit util mem_used mem_total; do
    # 温度判断
    TEMP_VAL=$(echo "$temp" | tr -d ' ')
    if [ "$TEMP_VAL" -gt 85 ]; then
        TEMP_FLAG="${RED}⚠${NC}"
    else
        TEMP_FLAG="${GREEN}✓${NC}"
    fi
    echo -e "  GPU${idx}: ${name} | ${TEMP_FLAG} ${temp}°C | 功耗: ${power} | 利用率: ${util} | 显存: ${mem_used}/${mem_total}"
done

# 3. ECC 错误
echo "[3/6] ECC 错误检查..."
nvidia-smi --query-gpu=index,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,retired_pages.single_bit_ecc.count,retired_pages.double_bit.count \
    --format=csv,noheader | while IFS=',' read -r idx corrected uncorrected retired_single retired_double; do
    UNCORR_VAL=$(echo "$uncorrected" | tr -d ' ')
    if [ "$UNCORR_VAL" != "0" ] && [ -n "$UNCORR_VAL" ]; then
        echo -e "  ${RED}GPU${idx}: 不可纠正 ECC 错误 = ${uncorrected} !!!${NC}"
    else
        echo -e "  GPU${idx}: 可纠正=${corrected} 不可纠正=${uncorrected} 退役页(SBE)=${retired_single} 退役页(DBE)=${retired_double}"
    fi
done

# 4. PCIe 链路
echo "[4/6] PCIe 链路状态..."
nvidia-smi --query-gpu=index,pcie.link.gen.current,pcie.link.width.current,pcie.link.gen.max,pcie.link.width.max,pcie.replay_counter \
    --format=csv,noheader | while IFS=',' read -r idx gen width gen_max width_max replay; do
    GEN_VAL=$(echo "$gen" | tr -d ' ')
    GEN_MAX=$(echo "$gen_max" | tr -d ' ')
    if [ "$GEN_VAL" != "$GEN_MAX" ]; then
        echo -e "  ${YELLOW}GPU${idx}: PCIe Gen${GEN_VAL}x${width} ← 降速了！(最大 Gen${GEN_MAX}x${width_max})${NC}"
    else
        echo -e "  GPU${idx}: PCIe Gen${GEN_VAL}x${width} (满速)  重放计数=${replay}"
    fi
done

# 5. XID 错误
echo "[5/6] XID 错误（24小时内）..."
XID_COUNT=$(dmesg 2>/dev/null | grep -i "NVRM.*Xid" | wc -l || echo "0")
if [ "$XID_COUNT" -gt 0 ]; then
    echo -e "  ${RED}⚠ 发现 ${XID_COUNT} 条 XID 错误！${NC}"
    dmesg | grep -i "NVRM.*Xid"
else
    echo -e "  ${GREEN}✓${NC} 无 XID 错误"
fi

# 6. GPU 进程
echo "[6/6] GPU 进程..."
PROC_COUNT=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | wc -l)
if [ "$PROC_COUNT" -gt 0 ]; then
    echo "  当前 ${PROC_COUNT} 个进程在用 GPU:"
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader | while IFS=',' read -r pid name mem; do
        echo -e "    PID:${pid}  ${name}  显存: ${mem}"
    done
else
    echo -e "  ${GREEN}✓${NC} 无 GPU 进程（GPU 空闲）"
fi

echo ""
echo "========================================"
echo "  巡检完成"
echo "========================================"
