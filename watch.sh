#!/bin/bash

WATCHED_FILE="watched_services.txt"
STATE_DIR="./state"
mkdir -p "$STATE_DIR"

JOBS_LOG="$STATE_DIR/jobs.log"

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

  # Kiểm tra log OOM theo PID container
  oom_log=$(dmesg -T | grep -E "Killed process[[:space:]]+$pid\b" | tail -n 10)

  # Lấy logs cuối nếu có lỗi
  last_logs=$(docker logs --tail 50 "$name" 2>&1 | grep -Ei 'warn|error|out of memory' | tail -n 10)

  # Nếu có OOM hoặc exit_code != 0 thì gửi notify
  if [[ -n "$oom_log" || "$exit_code" -ne 0 ]]; then
    msg="[$timestamp] 🚨 Service [$name] DOWN (PID=$pid)."
    msg="$msg\n🧯 ExitCode=$exit_code"
    [[ -n "$exit_error" && "$exit_error" != "<nil>" ]] && msg="$msg, Error: $exit_error"
    [[ -n "$oom_log" ]] && msg="$msg\n💥 OOM Detected:\n$oom_log"
    [[ -n "$last_logs" ]] && msg="$msg\n📋 Logs:\n$last_logs"
    ./notify.sh "$msg"
  fi
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
      # Nếu là job dạng ecom-testing-task-* thì chỉ log, không notify ngay
      if [[ "$name" == ecom-testing-task-* ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'),$name" >> "$JOBS_LOG"
        continue
      fi

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
          action="⚡DEPLOY"
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

last_alert_cpu=0
last_alert_mem=0
last_alert_disk=0
alert_cpu_interval=60  # seconds
alert_mem_interval=60  # seconds
alert_disk_interval=300  # seconds

check_system_resources() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  local now=$(date +%s)

  cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}' | cut -d. -f1)
  disk_usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

  mem_info=$(free -m)
  total_mem=$(echo "$mem_info" | awk '/Mem:/ {print $2}')
  used_mem=$(echo "$mem_info" | awk '/Mem:/ {print $3}')
  mem_usage=0
  if [[ -z "$total_mem" || "$total_mem" -eq 0 ]]; then
    mem_usage=0
  else
    mem_usage=$(( 100 * used_mem / total_mem ))
  fi

  # Thresholds
  CPU_THRESHOLD=85
  MEM_THRESHOLD=90
  DISK_THRESHOLD=85

  if (( cpu_usage >= CPU_THRESHOLD && now - last_alert_cpu > alert_cpu_interval )); then
    ./notify.sh "[$timestamp] 🔥 High CPU usage: ${cpu_usage}%"
    last_alert_cpu=$now
  fi

  if (( mem_usage >= MEM_THRESHOLD && now - last_alert_mem > alert_mem_interval )); then
    ./notify.sh "[$timestamp] 🔥 High RAM usage: ${mem_usage}% (${used_mem}/${total_mem}MB)"
    last_alert_mem=$now
  fi

  if (( disk_usage >= DISK_THRESHOLD && now - last_alert_disk > alert_disk_interval )); then
    ./notify.sh "[$timestamp] 🔥 Disk usage high: ${disk_usage}%"
    last_alert_disk=$now
  fi
}

last_heartbeat=0
heartbeat_interval=$((6 * 3600))  # 6 giờ tính bằng giây
send_heartbeat() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  local now=$(date +%s)

  if (( now - last_heartbeat < heartbeat_interval )); then
    return
  fi

  # Thu thập thông tin
  cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}' | cut -d. -f1)
  mem_info=$(free -m)
  total_mem=$(echo "$mem_info" | awk '/Mem:/ {print $2}')
  used_mem=$(echo "$mem_info" | awk '/Mem:/ {print $3}')
  mem_usage=0
  if [[ -n "$total_mem" && "$total_mem" -ne 0 ]]; then
    mem_usage=$(( 100 * used_mem / total_mem ))
  fi
  disk_usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

  # Gửi heartbeat
  ./notify.sh "[$timestamp] [Heartbeat]: Monitor still alive.\nCPU: ${cpu_usage}%\nRAM: ${mem_usage}% (${used_mem}/${total_mem}MB)\nDisk: ${disk_usage}%"

  last_heartbeat=$now
}

check_system_loop() {
  while true; do
    check_system_resources
    send_heartbeat
    sleep 15  # Kiểm tra mỗi 15 giây
  done
}

check_jobs_summary_loop() {
  SUMMARY_LOG="$STATE_DIR/jobs_summary.log"

  while true; do
    if [[ -s "$JOBS_LOG" ]]; then
      summary=$(awk -F',' '
        {
          job=$2
          count[job]++
          timestamps[job]=(timestamps[job] ? timestamps[job] "\n   • " $1 : "   • " $1)
        }
        END {
          for (job in count) {
            print "=============================="
            print "📌 Job: " job
            print "🔹 Số lần chạy: " count[job]
            print "🔹 Các lần chạy:"
            print timestamps[job]
            print ""
          }
        }' "$JOBS_LOG")

      echo "$summary" > "$SUMMARY_LOG"

      # Chia nhỏ message nếu quá dài 
      max_len=4000
      msg="$summary"
      while [[ -n "$msg" ]]; do
        chunk=${msg:0:$max_len}
        ./notify.sh "$chunk"
        msg=${msg:$max_len}
      done

      # truncate thay vì rm
      : > "$JOBS_LOG"
    fi

    sleep 3600 # 1 tiếng
  done
}



watch_events &
check_jobs_summary_loop &
check_down_loop &
check_system_loop &

wait
