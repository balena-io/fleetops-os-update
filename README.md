# Overview

To perform an upgrade using this repo (with very specific parameters in terms of source and target host OS versions):

1. First, create a `params` file locally to use (`cp params.example params`)
1. Set a target commit in the created `params` file
1. Create a file called batch with line-separated UUIDs
1. Run `./run_preupdate.sh` to confirm and prepare all devices in `batch` are ready for upgrade
1. If `grep -i "fail\|error" preupdater.log` returns no output, the update can proceed. Otherwise, some supervisor updates may be required.
1. Finally, run `./run.sh` to perform the actual upgrade and reboot into the new host OS

## Useful helpers

### To generate a device list:
```bash
balena devices -a "${APP}" > device-list.mega.log
```

### To create a batch file based on online status + tag:
```bash
awk '/true.*${STARTING_OS}/{print $NF}' device-list.mega.log | awk -F/ '{print $5}' | sort | shuf > mega-batch.log
for i in $(cat mega-batch.log); do balena tags --device $i | grep -q "${TAG}" && echo $i; done >> tags.log 2>/dev/null
sort -u tags.log | shuf -n "${BATCH_SIZE}" > batch
```

### To filter out devices requiring a supervisor upgrade:
```bash
awk '/Fail: Super/{print $1}' preupdater.log > ../fleetops-supervisor-update/batch
```

### To create a batch for supervisor updates:
```bash
awk '/${STARTING_SUPER}/{print}' device-list.mega.log | grep -f batch | awk -F/ '{print $5}' > supervisor-upgrades
```

### To connect to a device once it returns online:
```bash
uuid="${UUID}"; until balena ssh "${uuid}" 2>/dev/null; do sleep 60; done
```

### To monitor the incremental progress of the update:
```bash
watch -n 120 ./monitor.sh ${APP} batch
```
