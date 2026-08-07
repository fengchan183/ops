#!/bin/bash
# ============================================================
# auto_partition.sh — 自动分区并格式化脚本 (MBR / GPT 双模式)
#
# 用法：
#   ./auto_partition.sh <硬盘名> <mbr|gpt> <大小1> [大小2] ... [大小N]
#
# 说明：
#   - 分区个数 = 大小参数个数
#   - 大小格式：数字+后缀 (K/M/G/T，大小写均可)，不带后缀按 GiB 处理，支持小数
#       例: 512M  100G  1.5T  465.76G
#   - 各分区大小之和需约等于磁盘可用容量（误差约 1GiB 内可接受）
#   - 最后一个分区自动吸收分区表开销与舍入余量，占满可用空间
#   - 分区操作用 parted 完成（MBR/GPT 通用，不依赖 fdisk/gdisk），完成后格式化 ext4
#   - 只做分区与格式化，不挂载
#
# 约束：
#   MBR 最多 4 个主分区；GPT 最多 128 个分区
#
# 示例：
#   ./auto_partition.sh sdb gpt 100G 100G 100G
#   ./auto_partition.sh sdb mbr 465.76G
#   ./auto_partition.sh nvme0n1 gpt 100G 200G 165.76G
# ============================================================

set -e
set -o pipefail

usage() {
    cat <<EOF
用法: $0 <硬盘名> <mbr|gpt> <大小1> [大小2] ... [大小N]

  大小格式: 数字+后缀 (K/M/G/T，大小写均可)，不带后缀按 GiB 处理，支持小数
  例: 512M  100G  1.5T  465.76G

  N = 分区个数 = 大小参数个数
  各分区大小之和需约等于磁盘可用容量（脚本会先显示可用容量）
  最后一个分区自动吸收分区表开销与舍入余量，占满可用空间

约束:
  MBR 最多 4 个主分区
  GPT 最多 128 个分区

示例:
  $0 sdb gpt 100G 100G 100G
  $0 sdb mbr 465.76G
  $0 nvme0n1 gpt 100G 200G 165.76G
EOF
    exit 1
}

# ---------- 0. 工具与权限检查 ----------
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：必须使用 root 权限运行（需要 parted / mkfs.ext4）"
    exit 1
fi

for cmd in parted wipefs lsblk partprobe mkfs.ext4; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "错误：未找到命令 $cmd，请先安装对应软件包"
        exit 1
    fi
done

# ---------- 1. 参数解析 ----------
if [ $# -lt 3 ]; then
    echo "错误：至少需要 3 个参数"
    usage
fi

DISK_NAME="$1"
TABLE_TYPE="$2"
shift 2
SIZES=("$@")
PART_COUNT=${#SIZES[@]}
DISK="/dev/${DISK_NAME}"

# nvme/mmc 等盘名以数字结尾，分区设备名会多一个 p
if [[ "$DISK_NAME" =~ [0-9]$ ]]; then
    PART_PREFIX="${DISK_NAME}p"
else
    PART_PREFIX="${DISK_NAME}"
fi

TABLE_TYPE=$(echo "$TABLE_TYPE" | tr '[:upper:]' '[:lower:]')
if [ "$TABLE_TYPE" != "mbr" ] && [ "$TABLE_TYPE" != "gpt" ]; then
    echo "错误：分区表类型必须是 mbr 或 gpt，当前输入: ${TABLE_TYPE}"
    usage
fi

if [ "$TABLE_TYPE" = "mbr" ]; then
    MAX_PARTS=4
    PARTED_LABEL="msdos"
else
    MAX_PARTS=128
    PARTED_LABEL="gpt"
fi
if [ "$PART_COUNT" -lt 1 ] || [ "$PART_COUNT" -gt "$MAX_PARTS" ]; then
    echo "错误：${TABLE_TYPE^^} 分区数必须在 1~${MAX_PARTS} 之间，当前输入 ${PART_COUNT} 个"
    exit 1
fi

# ---------- 2. 检查硬盘 ----------
echo "正在检查硬盘 ${DISK} ..."
if ! lsblk "${DISK}" >/dev/null 2>&1; then
    echo "错误：硬盘 ${DISK} 不存在！可用硬盘："
    lsblk -d -o NAME,SIZE,TYPE | grep disk
    exit 1
fi

if lsblk -n -o MOUNTPOINT "${DISK}" | grep -q .; then
    echo "错误：${DISK} 上有分区处于挂载状态，请先卸载"
    lsblk "${DISK}"
    exit 1
fi

DISK_SIZE=$(lsblk -d -n -o SIZE "${DISK}" | head -1)
echo "找到硬盘: ${DISK}，大小: ${DISK_SIZE}"

# ---------- 3. 扇区信息与可用空间 ----------
SECTOR_SIZE=$(cat "/sys/block/${DISK_NAME}/queue/hw_sector_size" 2>/dev/null || echo 512)
TOTAL_SECTORS=$(cat "/sys/block/${DISK_NAME}/size" 2>/dev/null)
if [ -z "$TOTAL_SECTORS" ]; then
    echo "错误：无法获取硬盘扇区数"
    exit 1
fi

ALIGN_SECTORS=$((1048576 / SECTOR_SIZE))              # 1 MiB 对齐
FIRST_SECTOR=$ALIGN_SECTORS
if [ "$TABLE_TYPE" = "gpt" ]; then
    LAST_SECTOR=$((TOTAL_SECTORS - ALIGN_SECTORS - 1)) # 末尾预留 1 MiB 给 GPT 备份头
else
    LAST_SECTOR=$((TOTAL_SECTORS - 1))                 # MBR 可用到最后一个扇区
fi
USABLE_SECTORS=$((LAST_SECTOR - FIRST_SECTOR + 1))
if [ "$USABLE_SECTORS" -le 0 ]; then
    echo "错误：磁盘可用空间不足"
    exit 1
fi

# ---------- 4. 大小解析 ----------
human_size() {
    local sectors=$1
    local bytes=$((sectors * SECTOR_SIZE))
    if [ "$bytes" -ge $((1024*1024*1024)) ]; then
        printf "%d.%02d GiB" $((bytes / 1073741824)) $(((bytes % 1073741824) * 100 / 1073741824))
    elif [ "$bytes" -ge $((1024*1024)) ]; then
        printf "%d.%02d MiB" $((bytes / 1048576)) $(((bytes % 1048576) * 100 / 1048576))
    else
        printf "%d.%02d KiB" $((bytes / 1024)) $(((bytes % 1024) * 100 / 1024))
    fi
}

to_sectors() {
    local input="$1" int frac unit base f3
    if [[ "$input" =~ ^([0-9]+)([.]([0-9]+))?([kKmMgGtT])?$ ]]; then
        int=${BASH_REMATCH[1]}
        frac=${BASH_REMATCH[3]:-}
        unit=${BASH_REMATCH[4]:-G}
    else
        return 1
    fi
    case "$unit" in
        k|K) base=1024 ;;
        m|M) base=$((1024*1024)) ;;
        g|G) base=$((1024*1024*1024)) ;;
        t|T) base=$((1024*1024*1024*1024)) ;;
    esac
    if [ -n "$frac" ]; then
        if [ ${#frac} -ge 3 ]; then f3=${frac:0:3}; else f3=$(printf "%-3s" "$frac" | tr ' ' '0'); fi
    else
        f3=000
    fi
    local bytes=$(( (10#$int * 1000 + 10#$f3) * base / 1000 ))
    echo $(( (bytes + SECTOR_SIZE - 1) / SECTOR_SIZE ))
}

PART_SECTORS=()
TOTAL_REQUESTED=0
for size in "${SIZES[@]}"; do
    sec=$(to_sectors "$size") || {
        echo "错误：无法解析大小 '${size}'（支持格式如 100G / 512M / 1.5T）"
        exit 1
    }
    PART_SECTORS+=("$sec")
    TOTAL_REQUESTED=$((TOTAL_REQUESTED + sec))
done

# ---------- 5. 容量校验 ----------
TOLERANCE_SECTORS=$((ALIGN_SECTORS * 1024))   # 允许约 1GiB 误差，由最后一个分区吸收
if [ "$TOTAL_REQUESTED" -gt "$TOTAL_SECTORS" ]; then
    echo "错误：分区大小之和超过硬盘总容量"
    echo "  合计: $(human_size $TOTAL_REQUESTED)"
    echo "  硬盘: $(human_size $TOTAL_SECTORS)"
    exit 1
fi
if [ "$TOTAL_REQUESTED" -lt $((USABLE_SECTORS - TOLERANCE_SECTORS)) ]; then
    echo "错误：分区大小之和远小于磁盘可用容量，会留下过多未分配空间"
    echo "  合计: $(human_size $TOTAL_REQUESTED)"
    echo "  可用: $(human_size $USABLE_SECTORS)"
    exit 1
fi

# ---------- 6. 计算分区布局 ----------
# 非最后一个分区向下对齐到 1 MiB；最后一个分区占满到 LAST_SECTOR
declare -a PART_ALIGN PLAN_START PLAN_END
s=$FIRST_SECTOR
for ((i=0; i<PART_COUNT; i++)); do
    PLAN_START[$i]=$s
    if [ $i -eq $((PART_COUNT - 1)) ]; then
        PLAN_END[$i]=$LAST_SECTOR
        break
    fi
    if [ "${PART_SECTORS[$i]}" -lt "$ALIGN_SECTORS" ]; then
        echo "错误：分区 ${SIZES[$i]} 过小，除最后一个分区外，每个分区至少 1 MiB"
        exit 1
    fi
    PART_ALIGN[$i]=$(( PART_SECTORS[$i] / ALIGN_SECTORS * ALIGN_SECTORS ))
    PLAN_END[$i]=$((s + PART_ALIGN[$i] - 1))
    s=$(( PLAN_END[$i] + 1 ))
done

# ---------- 7. 确认 ----------
echo ""
echo "=========================================="
echo "  即将执行以下操作："
echo "=========================================="
echo "  硬盘:       ${DISK} (${DISK_SIZE})"
echo "  分区表:     ${TABLE_TYPE^^} (parted: ${PARTED_LABEL})"
echo "  分区数量:   ${PART_COUNT}"
echo "  可用空间:   $(human_size $USABLE_SECTORS)"
echo "  文件系统:   ext4"
echo "  ----------------------------------------"
for ((i=0; i<PART_COUNT; i++)); do
    end=$(( PLAN_END[$i] - PLAN_START[$i] + 1 ))
    if [ $i -eq $((PART_COUNT - 1)) ]; then
        printf "  /dev/%s%-2d  请求: %s  实际: %s (占满剩余)\n" "${PART_PREFIX}" "$((i+1))" "${SIZES[$i]}" "$(human_size $end)"
    else
        printf "  /dev/%s%-2d  请求: %s  实际: %s\n" "${PART_PREFIX}" "$((i+1))" "${SIZES[$i]}" "$(human_size $end)"
    fi
done
echo "  ※ 最后一个分区自动吸收分区表开销和舍入余量，实际大小以完成后 lsblk 为准"
echo "=========================================="
echo ""
echo "⚠️  警告：此操作将清除 ${DISK} 上的所有数据！"
read -rp "输入 YES 确认继续: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo "已取消。"
    exit 0
fi

# ---------- 8. 执行分区 (parted) ----------
echo ""
echo "正在分区 ${DISK} (${TABLE_TYPE^^}) ..."

# 清除旧分区表与文件系统签名，避免 parted mklabel 报磁盘忙/已分区
wipefs -a "${DISK}"
parted -s "${DISK}" mklabel "${PARTED_LABEL}"

for ((i=0; i<PART_COUNT; i++)); do
    start=${PLAN_START[$i]}
    end=${PLAN_END[$i]}
    echo "创建分区 $((i+1)): 起始=${start} 结束=${end}"
    set +e
    parted -s "${DISK}" unit s mkpart primary "${start}" "${end}" 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "错误：parted 创建第 $((i+1)) 个分区失败 (exit $rc)"
        exit 1
    fi
done

echo "分区完成。"
partprobe "${DISK}" 2>/dev/null || true
sleep 2

# ---------- 9. 验证分区结果 ----------
PARTITIONS=$(lsblk -n -o NAME "${DISK}" | grep -v "^${DISK_NAME}$" | sort -V)
ACTUAL_COUNT=$(echo "$PARTITIONS" | grep -c .)
if [ "$ACTUAL_COUNT" -ne "$PART_COUNT" ]; then
    echo "错误：检测到 ${ACTUAL_COUNT} 个分区，期望 ${PART_COUNT} 个，分区未生效！"
    echo "当前分区情况："
    lsblk "${DISK}"
    exit 1
fi

echo "检测到以下分区："
for part in $PARTITIONS; do
    echo "  /dev/${part}"
done

# ---------- 10. 格式化 ----------
echo ""
echo "开始格式化（mkfs.ext4）..."
FORMATTED_COUNT=0
for part in $PARTITIONS; do
    FULL_PART="/dev/${part}"
    echo "格式化 ${FULL_PART} ..."
    mkfs.ext4 -F "${FULL_PART}"
    FORMATTED_COUNT=$((FORMATTED_COUNT + 1))
    echo "  ✓ ${FULL_PART} 格式化完成"
done

# ---------- 11. 完成报告 ----------
echo ""
echo "=========================================="
echo "  全部完成！"
echo "=========================================="
echo "  硬盘:       ${DISK}"
echo "  分区表:     ${TABLE_TYPE^^}"
echo "  已格式化:   ${FORMATTED_COUNT} 个分区"
echo ""
echo "分区详情:"
lsblk "${DISK}" -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
echo "=========================================="
