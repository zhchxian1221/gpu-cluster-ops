#!/bin/bash
# ===================================
# gpu-xid.sh — XID 错误检查
# 用法: bash gpu-xid.sh
# ===================================
set -e

echo "========== XID 错误检查 =========="
echo ""

XID_OUTPUT=$(dmesg 2>/dev/null | grep -i "NVRM.*Xid" || true)

if [ -z "$XID_OUTPUT" ]; then
    echo "  ✓ 无 XID 错误"
else
    echo "  ⚠ 发现以下 XID 错误:"
    echo ""
    echo "$XID_OUTPUT" | while read -r line; do
        # 提取 XID 编号
        XID_CODE=$(echo "$line" | grep -oP 'Xid\s*[:\s]*\K\d+' || echo "$line" | grep -o 'Xid [0-9]*')
        echo "  $line"

        # 匹配常见 XID 含义
        case "$XID_CODE" in
            *13*)  echo "    → 图形引擎异常 (硬件可能损坏)" ;;
            *31*)  echo "    → 显存页错误" ;;
            *43*)  echo "    → GPU 停止处理" ;;
            *45*)  echo "    → 先发清理 (驱动检测到无响应后强制重置)" ;;
            *48*)  echo "    → 双 bit ECC 错误 (显存硬件问题)" ;;
            *63*)  echo "    → ECC 显存页退役或行重映射" ;;
            *74*)  echo "    → NVLink 错误" ;;
            *79*)  echo "    → GPU fell off the bus (PCIe 掉卡，检查电源/散热)" ;;
            *92*)  echo "    → 高频双 bit ECC 错误" ;;
            *94*)  echo "    → 已隔离的 ECC 错误" ;;
            *119*) echo "    → GPU 温度超限" ;;
        esac
        echo ""
    done

    echo "  XID 错误总数: $(echo "$XID_OUTPUT" | wc -l)"
    echo "  ⚠ 出现任何 XID 错误都需要关注，尤其是 48/79/92"
fi

echo ""
echo "========== 完成 =========="
