#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/metal_mode_sweep.sh <input_file> <dp> [seconds_per_mode]

Example:
  scripts/metal_mode_sweep.sh puzzle135.txt 43 40

Optional environment overrides:
  GPU_ID=0
  GRID=80,256
  GRP_SIZE=64
  NB_RUN=4
  WAIT_TIMEOUT_MS=8000
  STATE_MODES="1 2 3 4"
EOF
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
  exit 1
fi

input_file="$1"
dp="$2"
seconds_per_mode="${3:-40}"

if [[ ! -f "$input_file" ]]; then
  echo "Input file not found: $input_file" >&2
  exit 1
fi

if ! [[ "$dp" =~ ^[0-9]+$ && "$seconds_per_mode" =~ ^[0-9]+$ ]]; then
  echo "dp and seconds_per_mode must be integers." >&2
  exit 1
fi

gpu_id="${GPU_ID:-0}"
grid="${GRID:-80,256}"
grp_size="${GRP_SIZE:-64}"
nb_run="${NB_RUN:-4}"
wait_timeout_ms="${WAIT_TIMEOUT_MS:-8000}"
state_modes="${STATE_MODES:-1 2 3 4}"

if ! [[ "$grid" =~ ^[0-9]+,[0-9]+$ ]]; then
  echo "GRID must be in 'X,Y' format, got: $grid" >&2
  exit 1
fi

if [[ ! -x "./kangaroo" ]]; then
  echo "./kangaroo not found or not executable. Build first: make gpu=1" >&2
  exit 1
fi

echo "Mode sweep config:"
echo "  input=$input_file dp=$dp sec_per_mode=$seconds_per_mode"
echo "  gpuId=$gpu_id grid=$grid grp=$grp_size nbRun=$nb_run timeoutMs=$wait_timeout_ms"
echo "  modes=$state_modes"
echo
printf "%-8s %-10s %-10s %-12s %-12s\n" "Mode" "MK/s" "GPU MK/s" "Count" "AvgYears"

stop_with_children() {
  local parent_pid="$1"
  local child_pids=""
  child_pids="$(pgrep -P "$parent_pid" 2>/dev/null || true)"

  if [[ -n "$child_pids" ]]; then
    kill -INT $child_pids 2>/dev/null || true
  fi
  kill -INT "$parent_pid" 2>/dev/null || true
  sleep 1

  child_pids="$(pgrep -P "$parent_pid" 2>/dev/null || true)"
  if [[ -n "$child_pids" ]]; then
    kill -TERM $child_pids 2>/dev/null || true
  fi
  kill -TERM "$parent_pid" 2>/dev/null || true
  sleep 1

  child_pids="$(pgrep -P "$parent_pid" 2>/dev/null || true)"
  if [[ -n "$child_pids" ]]; then
    kill -KILL $child_pids 2>/dev/null || true
  fi
  kill -KILL "$parent_pid" 2>/dev/null || true
}

for mode in $state_modes; do
  if ! [[ "$mode" =~ ^[0-9]+$ ]]; then
    echo "Skip invalid mode token: $mode" >&2
    continue
  fi

  log_file="$(mktemp)"
  clean_log_file="$(mktemp)"
  out_file="mode_sweep_${mode}_$$.txt"

  if command -v script >/dev/null 2>&1; then
    script -q "$log_file" \
      env \
        -u KANGAROO_METAL_PROFILE \
        -u KANGAROO_METAL_INV_PROFILE \
        KANGAROO_METAL_STATE_CACHE_MODE="$mode" \
        KANGAROO_METAL_BLOCK_WAIT=1 \
        KANGAROO_METAL_GRP_SIZE="$grp_size" \
        KANGAROO_METAL_NB_RUN="$nb_run" \
        KANGAROO_METAL_WAIT_TIMEOUT_MS="$wait_timeout_ms" \
        ./kangaroo -gpu -gpuId "$gpu_id" -g "$grid" -d "$dp" -t 0 -o "$out_file" "$input_file" \
      >/dev/null 2>&1 &
  else
    env \
      -u KANGAROO_METAL_PROFILE \
      -u KANGAROO_METAL_INV_PROFILE \
      KANGAROO_METAL_STATE_CACHE_MODE="$mode" \
      KANGAROO_METAL_BLOCK_WAIT=1 \
      KANGAROO_METAL_GRP_SIZE="$grp_size" \
      KANGAROO_METAL_NB_RUN="$nb_run" \
      KANGAROO_METAL_WAIT_TIMEOUT_MS="$wait_timeout_ms" \
      ./kangaroo -gpu -gpuId "$gpu_id" -g "$grid" -d "$dp" -t 0 -o "$out_file" "$input_file" \
      >"$log_file" 2>&1 &
  fi
  run_pid=$!

  (
    sleep "$seconds_per_mode"
    stop_with_children "$run_pid"
  ) &
  killer_pid=$!
  wait "$run_pid" 2>/dev/null || true
  kill -TERM "$killer_pid" 2>/dev/null || true
  wait "$killer_pid" 2>/dev/null || true

  LC_ALL=C tr -d '\r\004\010' <"$log_file" >"$clean_log_file" || cp "$log_file" "$clean_log_file"
  line="$(grep -E '\[[0-9]+(\.[0-9]+)? MK/s\]' "$clean_log_file" | tail -n 1 || true)"
  mkps="$(echo "$line" | sed -nE 's/^\[([0-9]+(\.[0-9]+)?) MK\/s\].*/\1/p')"
  gpu_mkps="$(echo "$line" | sed -nE 's/.*\[GPU ([0-9]+(\.[0-9]+)?) MK\/s\].*/\1/p')"
  count="$(echo "$line" | sed -nE 's/.*\[Count ([^]]+)\].*/\1/p')"
  avg_years="$(echo "$line" | sed -nE 's/.*\(Avg ([^)]+)\).*/\1/p')"

  if [[ -z "$mkps" ]]; then
    printf "%-8s %-10s %-10s %-12s %-12s\n" "$mode" "n/a" "n/a" "n/a" "n/a"
  else
    printf "%-8s %-10s %-10s %-12s %-12s\n" "$mode" "$mkps" "${gpu_mkps:-n/a}" "${count:-n/a}" "${avg_years:-n/a}"
  fi

  rm -f "$log_file" "$clean_log_file" "$out_file"
done
