#!/bin/bash

# Function to Search for ERRORs and exceptions on all Openstack Overcloud nodes.
# Search options include DATE, UUID and compressed (gz) logs.
# On each overcloud node, it will also show current status of HA and containers.
# Results will be saved as ${node}_errors_${today}.log

print_openstack_errors() {
  read -p "To search within compressed logs, enter \" gz \" : " -e include_gz
  [[ "$include_gz" =~ ^gz$ ]] && include_gz="-o -name '*.gz'" || include_gz=""
  today="`date +%Y-%m-%d`"
  read -p "To search for errors on specific DATE, enter date as : " -i "$today" -e DATE
  read -p "To search for a specific Openstack object, enter its UUID : " -e UUID

  FIND_ERR="${DATE}.*(CRITICAL|ERROR).*(Traceback|Exception)"
  [[ -z "$UUID" ]] || FIND_ERR="$FIND_ERR|$UUID"

  FIND_PATH="/var/log/containers"
  SSH_CMD="sudo docker ps -a | grep -E '(Down|unhealthy|Restarting)'; \
  df -h; \
  sudo pcs status | grep -i error; \
  sudo find ${FIND_PATH} \( -name '*.log' ${include_gz} \) \
    -print0 | xargs -0 -I % sh -c \" \
    sudo zgrep -m 3 -B 5 -A 20 -E '${FIND_ERR}' % > TEMP \
    && echo -e '\n\n*** \$(hostname): % ***\n' \
    && sort -u TEMP || echo -en '.' \" "

  osp_version=$(cat /etc/yum.repos.d/latest-installed)
  echo -e "\nBase OSP version: $osp_version"
  echo -e "\nCurrently deployed puddle:"
  cat /etc/yum.repos.d/rhos-release-*.repo | grep -m 1 puddle_baseurl

  echo -e "\nRunning on each Overcloud node the following command:\n"
  echo "${SSH_CMD}"

  . stackrc

  for item in $(openstack server list -f value -c Name -c Networks | tr ' =' ':') ; do
    IP=$(echo $item | cut -d ':' -f 3)
    NODE=$(echo $item | cut -d ':' -f 1)
    echo -e "\n\n\n###### $NODE: ssh heat-admin@$IP on ${today} ######\n"
    ssh -o "StrictHostKeyChecking no" heat-admin@$IP "$SSH_CMD" |& tee -a ${NODE}_errors_${today}.log
  done
}

# --------------------------------------

# Add all functions to bashrc (to be available after ssh logout):

sed -i.bak '/print_openstack_errors (/,/}$/d' ~/.bashrc

typeset -f >> ~/.bashrc
