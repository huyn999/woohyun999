#!/usr/bin/env bash
# env/hardware/storage.sh — CRIU image storage capacity/bandwidth/latency 제약
#
# 모사 대상: 임베디드 장치에서 CRIU image가 저장되는 persistent storage.
#   - capacity  = loop-backed ext4 image 크기
#   - bandwidth = cgroup v2 io.max로 해당 loop device의 rbps/wbps 제한
#   - latency   = dm-delay로 block I/O 요청 지연
#
# 전제:
#   - run cgroup은 hardware/cgroup.sh create가 이미 만들어 둠.
#   - cleanup은 live resource(마운트/loop)만 정리하고, image_disk.img는 run artifact로 남김.
#
# Action: apply | verify | cleanup
#
# Usage:
#   storage.sh apply   <run_id> <enabled> <capacity> <rbps|max> <wbps|max> [delay_enabled] [read_ms] [write_ms]
#   storage.sh verify  <run_id> <enabled> <capacity> <rbps|max> <wbps|max> [delay_enabled] [read_ms] [write_ms]
#   storage.sh cleanup <run_id>

set -euo pipefail

CG_ROOT="/sys/fs/cgroup"

ACTION="${1:-}"
RUN_ID="${2:-}"

if [[ -z "$ACTION" || -z "$RUN_ID" ]]; then
	echo "usage: $0 {apply <run_id> <enabled> <capacity> <rbps|max> <wbps|max> [delay_enabled] [read_ms] [write_ms] | verify <run_id> <enabled> <capacity> <rbps|max> <wbps|max> [delay_enabled] [read_ms] [write_ms] | cleanup <run_id>}" >&2
	exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$PROJECT_ROOT/runs/$RUN_ID"
STORAGE_DIR="$RUN_DIR/storage"
IMAGE_DIR="$RUN_DIR/image"
BACKING_FILE="$STORAGE_DIR/image_disk.img"
STORAGE_STATE="$RUN_DIR/storage.env"
CG_PATH="$CG_ROOT/criu_test_$RUN_ID"
DM_NAME="criu_img_$(printf '%s' "$RUN_ID" | tr -c 'A-Za-z0-9_.-' '_')"

require_root() {
	[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root" >&2; exit 1; }
}

bool_enabled() {
	case "$1" in
		true|yes|1) return 0 ;;
		false|no|0|"") return 1 ;;
		*) echo "ERROR: invalid storage enabled value: $1" >&2; exit 2 ;;
	esac
}

limit_to_bytes() {
	local value="$1"
	local label="$2"

	if [[ "$value" == "max" ]]; then
		echo "max"
		return 0
	fi

	numfmt --from=iec "$value" 2>/dev/null \
		|| { echo "ERROR: invalid $label (got: '$value')" >&2; exit 2; }
}

format_limit() {
	local value="$1"

	if [[ "$value" == "max" ]]; then
		echo "max"
	else
		numfmt --to=iec --suffix=B "$value"
	fi
}

loop_majmin() {
	local loop_dev="$1"
	lsblk -no MAJ:MIN "$loop_dev" | tr -d '[:space:]'
}

validate_delay_ms() {
	local value="$1"
	local label="$2"

	[[ "$value" =~ ^[0-9]+$ ]] \
		|| { echo "ERROR: $label must be a non-negative integer milliseconds value (got: '$value')" >&2; exit 2; }
}

write_state() {
	local enabled="$1"
	local capacity="$2"
	local rbps="$3"
	local wbps="$4"
	local delay_enabled="$5"
	local read_ms="$6"
	local write_ms="$7"
	local loop_dev="${8:-}"
	local loop_majmin_value="${9:-}"
	local data_dev="${10:-}"
	local data_majmin="${11:-}"
	local dm_name="${12:-}"

	cat > "$STORAGE_STATE" <<EOF
STORAGE_IMAGE_ENABLED=$enabled
STORAGE_IMAGE_CAPACITY=$capacity
STORAGE_IMAGE_RBPS=$rbps
STORAGE_IMAGE_WBPS=$wbps
STORAGE_IMAGE_DELAY_ENABLED=$delay_enabled
STORAGE_IMAGE_DELAY_READ_MS=$read_ms
STORAGE_IMAGE_DELAY_WRITE_MS=$write_ms
STORAGE_IMAGE_LOOP=$loop_dev
STORAGE_IMAGE_LOOP_MAJMIN=$loop_majmin_value
STORAGE_IMAGE_DATA_DEV=$data_dev
STORAGE_IMAGE_MAJMIN=$data_majmin
STORAGE_IMAGE_DM_NAME=$dm_name
STORAGE_IMAGE_DM_DEV=${data_dev:-}
STORAGE_IMAGE_BACKING=$BACKING_FILE
IMAGE_DIR=$IMAGE_DIR
EOF
}

find_loop_for_backing() {
	losetup -j "$BACKING_FILE" 2>/dev/null | awk -F: 'NR == 1 {print $1}'
}

do_cleanup() {
	require_root
	local loop_dev=""
	local dm_name="$DM_NAME"

	local unmounted=0
	while mountpoint -q "$IMAGE_DIR"; do
		umount "$IMAGE_DIR" || {
			echo "[storage] WARN: failed to unmount $IMAGE_DIR" >&2
			return 1
		}
		unmounted=$((unmounted + 1))
		(( unmounted < 8 )) || {
			echo "[storage] WARN: too many mount layers at $IMAGE_DIR" >&2
			return 1
		}
	done
	if (( unmounted > 0 )); then
		echo "[storage] unmounted: $IMAGE_DIR ($unmounted layer(s))"
	fi

	if [[ -f "$STORAGE_STATE" ]]; then
		# shellcheck source=/dev/null
		source "$STORAGE_STATE"
		loop_dev="${STORAGE_IMAGE_LOOP:-}"
		dm_name="${STORAGE_IMAGE_DM_NAME:-$dm_name}"
	fi

	if [[ -n "$dm_name" ]] && dmsetup info "$dm_name" >/dev/null 2>&1; then
		dmsetup remove "$dm_name" || {
			echo "[storage] WARN: failed to remove dm device $dm_name" >&2
			return 1
		}
		echo "[storage] removed dm-delay: $dm_name"
	fi
	[[ -n "$loop_dev" ]] || loop_dev="$(find_loop_for_backing)"

	if [[ -n "$loop_dev" && -b "$loop_dev" ]] && losetup "$loop_dev" >/dev/null 2>&1; then
		losetup -d "$loop_dev" || {
			echo "[storage] WARN: failed to detach $loop_dev" >&2
			return 1
		}
		echo "[storage] detached loop: $loop_dev"
	fi
}

create_delay_device() {
	local loop_dev="$1"
	local read_ms="$2"
	local write_ms="$3"
	local sectors
	local dm_dev

	validate_delay_ms "$read_ms" "storage.image.delay.read_ms"
	validate_delay_ms "$write_ms" "storage.image.delay.write_ms"
	command -v dmsetup >/dev/null || { echo "ERROR: dmsetup not found" >&2; exit 1; }
	command -v blockdev >/dev/null || { echo "ERROR: blockdev not found" >&2; exit 1; }

	sectors="$(blockdev --getsz "$loop_dev")"
	[[ "$sectors" =~ ^[0-9]+$ && "$sectors" -gt 0 ]] \
		|| { echo "ERROR: cannot get sector count for $loop_dev" >&2; exit 1; }

	dmsetup create "$DM_NAME" --table "0 $sectors delay $loop_dev 0 $read_ms $loop_dev 0 $write_ms"
	dmsetup mknodes "$DM_NAME" >/dev/null 2>&1 || true
	dm_dev="/dev/mapper/$DM_NAME"

	for _ in $(seq 1 50); do
		[[ -b "$dm_dev" ]] && {
			echo "$dm_dev"
			return 0
		}
		sleep 0.02
	done

	echo "ERROR: dm-delay device did not appear: $dm_dev" >&2
	exit 1
}

apply_io_max() {
	local rbps="$1"
	local wbps="$2"
	local majmin="$3"
	local rbps_value
	local wbps_value

	rbps_value="$(limit_to_bytes "${rbps:-max}" "storage.image.rbps")"
	wbps_value="$(limit_to_bytes "${wbps:-max}" "storage.image.wbps")"

	if [[ "$rbps_value" == "max" && "$wbps_value" == "max" ]]; then
		echo "[storage] io.max: no bandwidth cap"
		return 0
	fi

	echo "+io" > "$CG_ROOT/cgroup.subtree_control" 2>/dev/null || true
	if [[ ! -f "$CG_PATH/io.max" ]]; then
		echo "ERROR: io controller not delegated to $CG_PATH" >&2
		exit 1
	fi

	echo "$majmin rbps=$rbps_value wbps=$wbps_value" > "$CG_PATH/io.max"
	echo "[storage] applied: io.max $majmin rbps=$(format_limit "$rbps_value") wbps=$(format_limit "$wbps_value")"
}

do_apply() {
	local enabled="$1"
	local capacity="${2:-256M}"
	local rbps="${3:-max}"
	local wbps="${4:-max}"
	local delay_enabled="${5:-false}"
	local read_ms="${6:-0}"
	local write_ms="${7:-0}"
	local capacity_bytes
	local loop_dev
	local loop_majmin_value
	local data_dev
	local data_majmin

	require_root
	mkdir -p "$STORAGE_DIR" "$IMAGE_DIR"

	# 같은 run_id의 이전 실패 흔적이 있으면 enabled 여부와 무관하게 먼저 정리한다.
	do_cleanup || true

	if ! bool_enabled "$enabled"; then
		write_state "false" "$capacity" "$rbps" "$wbps" "$delay_enabled" "$read_ms" "$write_ms"
		echo "[storage] disabled: image dir = $IMAGE_DIR"
		return 0
	fi

	command -v losetup >/dev/null || { echo "ERROR: losetup not found" >&2; exit 1; }
	command -v mkfs.ext4 >/dev/null || { echo "ERROR: mkfs.ext4 not found" >&2; exit 1; }
	command -v mountpoint >/dev/null || { echo "ERROR: mountpoint not found" >&2; exit 1; }
	command -v lsblk >/dev/null || { echo "ERROR: lsblk not found" >&2; exit 1; }

	capacity_bytes="$(limit_to_bytes "$capacity" "storage.image.capacity")"
	[[ "$capacity_bytes" != "max" ]] || { echo "ERROR: storage.image.capacity cannot be max" >&2; exit 2; }

	truncate -s "$capacity_bytes" "$BACKING_FILE"
	loop_dev="$(losetup --find --show "$BACKING_FILE")"
	loop_majmin_value="$(loop_majmin "$loop_dev")"
	data_dev="$loop_dev"

	if bool_enabled "$delay_enabled"; then
		data_dev="$(create_delay_device "$loop_dev" "$read_ms" "$write_ms")"
		echo "[storage] applied: dm-delay read=${read_ms}ms write=${write_ms}ms ($loop_dev -> $data_dev)"
	else
		echo "[storage] dm-delay: disabled"
	fi

	mkfs.ext4 -F -q "$data_dev"
	mount "$data_dev" "$IMAGE_DIR"
	data_majmin="$(loop_majmin "$data_dev")"

	apply_io_max "$rbps" "$wbps" "$data_majmin"
	write_state "true" "$capacity" "$rbps" "$wbps" "$delay_enabled" "$read_ms" "$write_ms" \
		"$loop_dev" "$loop_majmin_value" "$data_dev" "$data_majmin" "$DM_NAME"

	echo "[storage] applied: image capacity = $(format_limit "$capacity_bytes")  ($capacity_bytes)"
	echo "[storage] mounted: $data_dev -> $IMAGE_DIR"
}

do_verify() {
	local enabled="$1"
	local capacity="${2:-256M}"
	local rbps="${3:-max}"
	local wbps="${4:-max}"
	local delay_enabled="${5:-false}"
	local read_ms="${6:-0}"
	local write_ms="${7:-0}"
	local fail=0

	check() {
		if eval "$2"; then printf "  [PASS] %s\n" "$1"
		else printf "  [FAIL] %s\n" "$1"; fail=$((fail+1)); fi
	}

	check "image dir exists ($IMAGE_DIR)" "[ -d '$IMAGE_DIR' ]"

	if ! bool_enabled "$enabled"; then
		return $fail
	fi

	[[ -f "$STORAGE_STATE" ]] || { echo "  [FAIL] storage state exists ($STORAGE_STATE)"; return 1; }
	# shellcheck source=/dev/null
	source "$STORAGE_STATE"

	local expected_capacity actual_capacity
	expected_capacity="$(limit_to_bytes "$capacity" "storage.image.capacity")"
	actual_capacity="$(stat -c %s "$BACKING_FILE" 2>/dev/null || echo missing)"

	check "image backing size == $expected_capacity (actual: $actual_capacity)" \
		"[ '$actual_capacity' = '$expected_capacity' ]"
	check "image dir is mounted ($IMAGE_DIR)" "mountpoint -q '$IMAGE_DIR'"
	check "loop device exists (${STORAGE_IMAGE_LOOP:-missing})" "[ -n '${STORAGE_IMAGE_LOOP:-}' ] && [ -b '${STORAGE_IMAGE_LOOP:-}' ]"

	if bool_enabled "$delay_enabled"; then
		local actual_table
		validate_delay_ms "$read_ms" "storage.image.delay.read_ms"
		validate_delay_ms "$write_ms" "storage.image.delay.write_ms"
		actual_table="$(dmsetup table "${STORAGE_IMAGE_DM_NAME:-missing}" 2>/dev/null || true)"
		check "dm-delay device exists (${STORAGE_IMAGE_DM_NAME:-missing})" \
			"dmsetup info '${STORAGE_IMAGE_DM_NAME:-missing}' >/dev/null 2>&1"
		check "dm-delay read=${read_ms}ms write=${write_ms}ms (actual: ${actual_table:-missing})" \
			"printf '%s\n' '$actual_table' | grep -q ' delay ' && printf '%s\n' '$actual_table' | grep -q ' $read_ms ' && printf '%s\n' '$actual_table' | grep -q ' $write_ms$'"
	else
		echo "  [PASS] dm-delay disabled"
	fi

	local rbps_value wbps_value actual_io
	rbps_value="$(limit_to_bytes "${rbps:-max}" "storage.image.rbps")"
	wbps_value="$(limit_to_bytes "${wbps:-max}" "storage.image.wbps")"
	if [[ "$rbps_value" != "max" || "$wbps_value" != "max" ]]; then
		actual_io="$(grep -E "^${STORAGE_IMAGE_MAJMIN:-missing} " "$CG_PATH/io.max" 2>/dev/null || true)"
		check "io.max has $STORAGE_IMAGE_MAJMIN rbps=$rbps_value wbps=$wbps_value (actual: ${actual_io:-missing})" \
			"printf '%s\n' '$actual_io' | grep -q 'rbps=$rbps_value' && printf '%s\n' '$actual_io' | grep -q 'wbps=$wbps_value'"
	else
		echo "  [PASS] io.max bandwidth cap disabled"
	fi

	return $fail
}

case "$ACTION" in
	apply)
		do_apply "${3:-false}" "${4:-256M}" "${5:-max}" "${6:-max}" "${7:-false}" "${8:-0}" "${9:-0}"
		;;
	verify)
		do_verify "${3:-false}" "${4:-256M}" "${5:-max}" "${6:-max}" "${7:-false}" "${8:-0}" "${9:-0}"
		;;
	cleanup)
		do_cleanup
		;;
	*)
		echo "ERROR: unknown action: $ACTION" >&2
		exit 2
		;;
esac
