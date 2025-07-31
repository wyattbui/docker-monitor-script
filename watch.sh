#!/bin/bash

WATCHED_FILE="watched_services.txt"
STATE_DIR="./state"
mkdir -p "$STATE_DIR"

get_epoch() {
  date +%s
}

is_watched() {
  grep -Fxq "$1" "$WATCHED_FILE"
}

should_notify() {
  local seconds=$1
  shift
  local notified=("$@")
  local schedule=(60 300 600 1800 3600 86400) # 1p 5p 10p 30p 1h 1d
  for t in "${schedule[@]}"; do
    if (( seconds >= t )) && [[ ! " ${notified[*]} " =~ " $t " ]]; then
      echo "$t"
      return
    fi
  done
  echo ""
}

write_state() {
  local name=$1
  local status=$2
  local die_time=$3
  local last_notified=$4

  {
    echo "status=$status"
    echo "die_time=$die_time"
    echo "last_notified=$last_notified"
  } > "$STATE_DIR/$name.state"
}

notify_container_die() {
  local name=$1
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

  exit_info=$(docker inspect "$name" --format '{{.State.ExitCode}} {{.State.Error}}')
  exit_code=$(echo "$exit_info" | awk '{print $1}')
  exit_error=$(echo "$exit_info" | cut -d' ' -f2-)
  pid=$(docker inspect -f '{{.State.Pid}}' "$name")
  oom_log=$(dmesg -T | grep "$pid" | tail -n 3)
  last_logs=$(docker logs --tail 50 "$name" 2>&1 | grep -Ei 'warn|error' | tail -n 10)

  msg="[$timestamp] 🚨 Service [$name] DOWN.\n🧯 ExitCode=$exit_code"
  [[ -n "$exit_error" && "$exit_error" != "<nil>" ]] && msg="$msg, Error: $exit_error"
  [[ -n "$oom_log" ]] && msg="$msg\n💥 dmesg:\n$oom_log"
  [[ -n "$last_logs" ]] && msg="$msg\n📋 Logs:\n$last_logs"

  ./notify.sh "$msg"
}

watch_events() {
  docker events --filter event=die --filter event=start |
  while read -r line; do
    event_type=$(echo "$line" | grep -oP 'container \K(die|start)')
    name=$(echo "$line" | grep -oP 'name=\K[^,)]+')
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    epoch=$(get_epoch)

    [[ -z "$event_type" || -z "$name" ]] && continue
    state_file="$STATE_DIR/$name.state"

    [[ -f "$state_file" ]] && source "$state_file" 2>/dev/null || {
      status="up"
      die_time=0
      last_notified=""
    }

    if [[ "$event_type" == "die" ]]; then
      is_watched "$name" || continue

      notify_container_die "$name"
      write_state "$name" "down" "$epoch" ""

    elif [[ "$event_type" == "start" ]]; then
      if ! is_watched "$name" && [[ "$name" != *migration* ]]; then
        ./notify.sh "[$timestamp] ❗ Container [$name] have been started ✅."
      fi

      if [[ "$status" == "down" ]]; then
        duration=$((epoch - die_time))
        
        # Kiểm tra restart hay deploy mới
        created_at=$(docker inspect -f '{{.Created}}' "$name" 2>/dev/null)
        started_at=$(docker inspect -f '{{.State.StartedAt}}' "$name" 2>/dev/null)

        if [[ "$created_at" != "$started_at" ]]; then
          action="🔄 RESTART"
        else
          action="🚀 DEPLOY"
        fi

        if is_watched "$name"; then
          if (( duration < 15 )); then
            ./notify.sh "[$timestamp] $action service $name (downtime ${duration}s)"
          else
            ./notify.sh "[$timestamp] ✅ Service $name restored after ${duration}s ($action)"
          fi
        fi
        write_state "$name" "up" 0 ""
      fi
    fi
  done
}

check_down_loop() {
  while true; do
    for state_file in "$STATE_DIR"/*.state; do
      [[ -f "$state_file" ]] || continue
      source "$state_file"
      name=$(basename "$state_file" .state)
      is_watched "$name" || continue
      [[ "$status" != "down" ]] && continue

      now=$(get_epoch)
      elapsed=$((now - die_time))
      IFS=',' read -ra sent <<< "$last_notified"
      notify_time=$(should_notify "$elapsed" "${sent[@]}")

      if [[ -n "$notify_time" ]]; then
        ./notify.sh "[$(date "+%Y-%m-%d %H:%M:%S")] 🚨 Service [$name] DOWN trong $elapsed giây"
        sent+=("$notify_time")
        new_notified=$(IFS=','; echo "${sent[*]}")
        write_state "$name" "down" "$die_time" "$new_notified"
      fi
    done
    sleep 10
  done
}

./notify.sh "⚡ Started Docker Monitor"

watch_events &
check_down_loop &

wait
