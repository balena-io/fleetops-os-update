# Overview

To perform an upgrade using this repo (with very specific parameters in terms of source and target host OS versions):

1. First, create a `params` file locally to use (`cp params.example params`)
1. Set a target commit in the created `params` file
1. Create a file called batch with line-separated UUIDs
1. Run `./run_preupdate.sh` to confirm and prepare all devices in `batch` are ready for upgrade
1. If `grep -i "fail\|error" preupdater.log` returns no output, the update can proceed. Otherwise, some supervisor updates may be required.
1. Finally, run `./run.sh` to perform the actual upgrade and reboot into the new host OS



## Useful helpers (horribly inefficient)
```
while read uuid; do curl -X GET \
"https://api.balena-cloud.com/v5/device?\$filter=uuid%20eq%20'${uuid}'" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer $token" | jq '.d[0] | .uuid,.is_on__commit,.api_heartbeat_state,.os_version' && sleep 1; done < batch > device-status.log
```

Presuming Resin OS -> balenaOS upgrade:
```
grep Resin -B 3 device-status.log | grep -B 2 offline | grep -v "offline\|$(awk -F= '/TARGET_COMMIT/{print $2}' params)\|--" | sed 's/"//g' > offline.log
```

```
grep Resin -B 3 device-status.log | grep -B 2 online | grep -v "online\|$(awk -F= '/TARGET_COMMIT/{print $2}' params)\|--" | sed 's/"//g' > online-but-not-updated.log
```
