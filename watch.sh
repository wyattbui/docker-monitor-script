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

watch_events() {
  docker events --filter event=die --filter event=start |
  while read -r line; do
    event_type=$(echo "$line" | grep -oP 'container \K(die|start)')
    name=$(echo "$line" | grep -oP 'name=\K[^,)]+')
    image=$(echo "$line" | grep -oP 'image=\K[^,)]+')
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    epoch=$(get_epoch)

    [[ -z "$event_type" || -z "$name" ]] && continue
    state_file="$STATE_DIR/$name.state"
    touch "$state_file"
    source "$state_file" 2>/dev/null || true

    if [[ "$event_type" == "die" ]]; then
      is_watched "$name" || continue
      echo "[$timestamp] ⚠️ [$name] stopped"
      write_state "$name" "down" "$epoch" ""

      # Log warn/error
      docker logs --tail 50 "$name" 2>&1 | grep -Ei 'warn|error'

    elif [[ "$event_type" == "start" && "$status" == "down" ]]; then
      is_watched "$name" || continue
      duration=$((epoch - die_time))
      is_watched "$name" && watched=1 || watched=0

      if (( watched )) && (( duration < 30 )); then
        ./notify.sh "[$timestamp] 🔄 Vừa deploy lại $name (mất ${duration}s)"
      elif (( watched )) && (( duration >= 30 )); then
        ./notify.sh "[$timestamp] ✅ Service $name đã hồi phục sau ${duration}s downtime"
      elif (( !watched )) && (( duration >= 30 )); then
        ./notify.sh "[$timestamp] ❗️Service lạ [$name] đã UP. sau ${duration}s downtime"
      fi

      write_state "$name" "up" 0 ""
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
./notify.sh "Started monitor script"

# 👉 Chạy song song
watch_events &
check_down_loop &

wait