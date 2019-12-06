#!/bin/bash

APP=$1
FILE=${2:-batch}

main(){
    out=$(balena devices -a "${APP}" | grep -f "${FILE}")
    echo "Statuses:"
    echo "${out}" | awk '{print $6}' | sort  | uniq -c
    echo "Online:"
    echo "${out}" | awk '{print $7}' | sort  | uniq -c
    echo "Supervisors Online:"
    echo "${out}" | awk '/true/{print $8}' | sort  | uniq -c
    echo "OSes:"
    echo "${out}" | awk '{print $9}' | sort  | uniq -c
    local -i maybe_need_restart
    maybe_need_restart=$(echo "${out}" | grep -c 'configuring.*true')
    if [ "${maybe_need_restart}" -gt 0 ]; then
        echo "Devices may need supervisor restart:"
        echo "${out}" | awk '/configuring.*true/{print "\t"$NF}'
    fi
    local -i online_not_upgraded
    online_not_upgraded=$(echo "${out}" | grep -c 'true.*Resin')
    if [ "${online_not_upgraded}" -gt 0 ]; then
        echo "Online Laggards:"
        echo "${out}" | awk '/true.*Resin/{print "\t"$NF}'
    fi
    echo "${out}" > device-list.current.log
}

main
