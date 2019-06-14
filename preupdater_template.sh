#!/bin/bash

set -o errexit -o pipefail

# Don't run anything before this source as it sets PATH here
# shellcheck disable=SC1091
source /etc/profile
# Load device settings from config.json
# shellcheck disable=SC1091
source /usr/sbin/resin-vars
# Load SUPERVISOR variables
# shellcheck disable=SC1091
source /etc//resin-supervisor/supervisor.conf

setup_logfile() {
    local workdir=$1
    LOGFILE="${workdir}/preupdate.$(date +"%Y%m%d_%H%M%S").log"
    touch "$LOGFILE"
    tail -f "$LOGFILE" &
    # this is global
    tail_pid=$!
    # redirect all logs to the logfile
    exec 1>> "$LOGFILE" 2>&1
}

finish_up() {
    local failure=$1
    local exit_code=0
    if [ -n "${failure}" ]; then
        echo "Fail: ${failure}"
        exit_code=1
    else
        echo "DONE"
    fi
    sleep 2
    kill $tail_pid || true
    exit ${exit_code}
}

device_repin() {
    COMMIT_HASH=$1
    if [ -z "${COMMIT_HASH}" ]; then
        finish_up "No commit hash provided!"
    fi
    BUILD_ID=$(curl --fail --retry 10 -s "${API_ENDPOINT}/v2/build?\$select=id,commit_hash&\$filter=application%20eq%20${APPLICATION_ID}%20and%20commit_hash%20eq%20'$COMMIT_HASH'" -H "Authorization: Bearer ${DEVICE_API_KEY}" | jq '.d[0].id')  || finish_up "Couldn't get build ID."
    echo "setting device ${DEVICE_ID} to commit ${COMMIT_HASH} with buildID = ${BUILD_ID}"
    curl --fail --retry 10 -s -X PATCH "${API_ENDPOINT}/v2/device(${DEVICE_ID})" -H "Authorization: Bearer ${DEVICE_API_KEY}" -H "Content-Type: application/json" --data-binary '{"build":'"${BUILD_ID}"'}' || finish_up "Couldn't set new commit hash."
}

#######################################
# Globals:
#   CONFIG_PATH
# Arguments:
#   var_name: the name of the required entry in config.json
# Returns:
#   var_value: the value of the entry
#######################################
resin_var_manual_load() {
    local var_name=$1
    local var_value

    if [ -f "${CONFIG_PATH}" ]; then
        var_value=$(jq -r ".${var_name}" "${CONFIG_PATH}") || finish_up "Couldn't get device API key."
        if [ ! -n "${var_value}" ]; then
            finish_up "Couldn't load device API key manually."
        fi
    else
        finish_up "Couldn't find the config.json file."
    fi
    echo "${var_value}"
}

#######################################
# Create or update service environment variable values
# Globals:
#   API_ENDPOINT
#   DEVICE_API_KEY
#   DEVICE_ID
#   UUID
# Arguments:
#   env_name: the env var name
#   env_value: the env var value
# Returns:
#   None
#######################################
service_env_create_update() {
    local env_name=$1
    local env_value=$2
    local ENVID

    ENVID=$(curl --fail --retry 10 -s -X GET \
        "${API_ENDPOINT}/v4/device_service_environment_variable?\$filter=(service_install/device%20eq%20${DEVICE_ID}%20and%20name%20eq%20'${env_name}')" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${DEVICE_API_KEY}"  | jq .d[0].id) || finish_up "Couldn't get environment variable information correctly."

    if [ "${ENVID}" = "null" ]; then
        echo "Service env var doesn't exists, creating."
        SERVICEID=$(curl --fail --retry 10 -s -X GET "${API_ENDPOINT}/v4/service_install?\$filter=device/uuid%20eq%20'${UUID}'&\$expand=installs__service(\$select=service_name)" -H "Content-Type: application/json" -H "Authorization: Bearer ${DEVICE_API_KEY}" | jq -r .d[0].id)

        curl --fail --retry 10 -s -X POST \
        "${API_ENDPOINT}/v4/device_service_environment_variable" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${DEVICE_API_KEY}" \
        --data '{
            "service_install": "'"${SERVICEID}"'",
            "name": "'"${env_name}"'",
            "value": "'"${env_value}"'"
        }' || finish_up "Couldn't create service env var."
    else
        echo "Service env var already exists, updating."
        curl --fail --retry 10 -s -X PATCH \
        "${API_ENDPOINT}/v4/device_service_environment_variable(${ENVID})" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${DEVICE_API_KEY}" \
        --data '{
            "value": "'"${env_value}"'"
        }' || finish_up "Couldn't update service env var."
    fi
}


main() {
    workdir="/mnt/data/ops2"
    mkdir -p "${workdir}" && cd "${workdir}"

    # also sets tail_pid
    setup_logfile "${workdir}"

    # Fill in missing global variables, mostly for 2.0.0-rcX OS versions, that have problem with "resin-var"
    if [ ! -n "${API_ENDPOINT}" ]; then
        API_ENDPOINT=$(resin_var_manual_load "apiEndpoint")
    fi
    if [ ! -n "${APPLICATION_ID}" ]; then
        APPLICATION_ID=$(resin_var_manual_load "applicationId")
    fi
    if [ ! -n "${DEVICE_API_KEY}" ]; then
        DEVICE_API_KEY=$(resin_var_manual_load "deviceApiKey")
    fi
    if [ ! -n "${DEVICE_ID}" ]; then
        DEVICE_ID=$(resin_var_manual_load "deviceId")
    fi
    if [ ! -n "$UUID" ]; then
        UUID=$(resin_var_manual_load "uuid")
    fi

    if [ "$SUPERVISOR_TAG" != "v6.6.11_logstream" ]; then
        finish_up "Supervisor needs to be updated to v6.6.11_logstream before continuing"
    fi

    local superstartscript="/usr/bin/start-resin-supervisor"
    # shellcheck disable=SC2016
    if grep -q '^(\[ "$SUPERVISOR_IMAGE_ID".*' "${superstartscript}"; then
        # Modify the supervisor start script so it doesn't recreate the supervisor container on restart
        tempfile=$(mktemp -u /tmp/tmp.supervisor.XXXXXXXXX)
        cp "${superstartscript}" "${tempfile}"

        # shellcheck disable=SC2016
        sed -i 's/^(\[ "$SUPERVISOR_IMAGE_ID".*//' "${tempfile}"
        cat << EOF >> "${tempfile}"
if [ "\$SUPERVISOR_IMAGE_ID" = "\$SUPERVISOR_CONTAINER_IMAGE_ID" ]; then
    docker start --attach resin_supervisor
else
    runSupervisor
fi
EOF
        mount --bind "${tempfile}" "${superstartscript}"
        echo "Supervisor start script was modified."
    else
        echo "Supervisor script is already modified."
    fi

    echo "Restarting supervisor to make sure changes to the start script are picked up"
    systemctl restart resin-supervisor || finish_up "Supervisor restart didn't work."
    sleep 5 # Let the restart commence
    local i=0
    while ! docker ps | grep -q resin_supervisor ; do
      sleep 1
      i=$((i+1))
      if [ $i -gt 60 ] ; then
        finish_up "Supervisor container didn't come up before timeout"
      fi
    done

    echo "Modifying supervisor container"
    docker exec resin_supervisor sed -i 's/waitAsync()\.timeout(5e3)/waitAsync()\.timeout(5e5)/' /usr/src/app/dist/app.js || finish_up "Supervisor container hotfix didn't work."
    echo "Restarting supervisor container"
    systemctl restart resin-supervisor || finish_up "Supervisor restart didn't work."

    echo "Updating environment variable"
    service_env_create_update "DBUS_SYSTEM_BUS_ADDRESS" "unix:path=/run/dbus/system_bus_socket"

    device_repin "%%TARGET_COMMIT%%"

    echo "Finished"

    finish_up
}

(
  # Check if already running and bail if yes
  flock -n 99 || (echo "Already running script..."; exit 1)
  main
) 99>/tmp/updater.lock
# Proper exit, required due to the locking subshell
exit $?
