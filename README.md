# Docker Container Watcher

A lightweight Bash script to monitor Docker containers in real time.  
This script tracks container `start` and `die` events, records service states, and sends notifications for critical changes such as service downtime or recovery.

---

## 📦 Features

- Monitor specific containers listed in `watched_services.txt`
- Persist container state in `./state` files
- Notify on:
  - Container **stopped**
  - Container **restarted**
  - Container **recovered after downtime**
  - Container **unexpected up**
- Escalating notification schedule (e.g., after 1 min, 5 min, 10 min, etc.)
- Outputs recent logs (`warn|error`) when a service crashes

---

## 📂 Folder Structure
```
.
├── watch.sh # Main monitoring script
├── notify.sh # Your notification handler (e.g., Slack, email)
├── watched_services.txt # List of container names to monitor
└── state/ # Auto-generated state files for each container
```


## 📝 How It Works

1. `watch.sh` listens to Docker events in real time using `docker events`.
2. On each `die` or `start` event:
   - If the container is in `watched_services.txt`, its state is updated.
   - Notifications are sent based on downtime and escalation rules.
   - A `.state` file is stored in the `./state` folder with:
     - `status`: `up` / `down`
     - `die_time`: epoch time of last stop
     - `last_notified`: list of seconds already notified (to prevent spamming)
3. A background loop checks every 10 seconds to re-send notifications if a container remains down.

---

## ▶️ Usage

```bash
chmod +x watch.sh notify.sh
./watch.sh