#!/bin/bash
####################################################################################
# By Eran Kuris and Noam Manos, 2019 ###############################################
####################################################################################

# Script description
disclosure='----------------------------------------------------------------------

This is an interactive script to create and test OpenStack topologies including:

* Multiple VM instances of following Operating Systems: RHEL (8.0, 7.6, 7.5, 7.4), Cirros and Windows.
* Multiple Networks and NICs with IPv4 & IPv6 subnets and Floating IPs, connected to external networks (Flat / Vlan)
* Tests includes: SSH Keypair, non-admin Tenant, Security group for HTTP/S, North-South, East-West, SNAT, and more.

Running with pre-defined parameters (optional):

* To show this help menu:                               -h / --help
* To set VM image:                                      -i / --image    [ rhel74 / rhel75 / rhel76 / rhel80 / cirros40 / win2019 ]
* To set topology - Multiple VMs or multiple NICs:      -t / --topology [ mni = Multiple Networks Interfaces / mvi = Multiple VM Instances ]
* To set the number of networks:                        -n / --networks [ 1-100 ]
* To set the number of VMs:                             -v / --machines [ 1-100 ]
* To create external network:                           -e / --external [ flat / vlan / skip ]
* To skip IPv6 tests (only IPv4 tests):                      --no-ipv6
* To test as Admin user (no tenant):                         --admin
* To run environment cleanup initially:                 -c / --cleanup  [ NO / YES / ONLY ]
* To quit on first error:                               -q / --quit     [ YES (default) / NO ]
* To trace BASH commands:                               -x / --trace
* To debug OpenStack commands                           -d / --debug


Command examples:

# ./create_multi_topology.sh

  Will run interactively (enter choices during execution).

# ./create_multi_topology.sh -x -t mvi -i cirros40 -n 2 -v 2 -e skip -c YES

  Will create and test Multiple VMs (4 total).
  On each of the 2 Networks - 2 CirrOS connected:

         <--> CirrOS_vm1         <--> CirrOS_vm3
  Net1 -|                 Net2 -|
         <--> CirrOS_vm2         <--> CirrOS_vm4

# ./create_multi_topology.sh -t mni -i rhel80 -n 2 -v 2 -e skip -c YES

  Will create and test Multiple NICs (4 total).
  On each of the 2 RHEL8 - 2 NICs connected:

             <--> NIC_1                   <--> NIC_3
  RHEL8_vm1 -|                RHEL8_vm2 -|
             <--> NIC_2                   <--> NIC_4

----------------------------------------------------------------------'

# Logging output with tee
log_file=multi_topology_$(date +%d-%m-%Y_%H%M).log
(

####################################################################################

# Default variables
set -T
export RED='\e[0;31m'
export GREEN='\e[38;5;22m'
export CYAN='\e[36m'
export YELLOW='\e[1;33m'
export NO_COLOR='\e[0m'
export HAT="${RED}🎩︎${NO_COLOR}"
export PYTHONIOENCODING=utf8

export KEY_FILE=tester_key.pem
export previous_vm=""
export previous_fip=""
export previous_ipv6=""
export ipv6_enable=YES
export tenant_enable=YES
export default_network_type=flat
export default_physical_network=datacentre

# RHEL Images
export rhel_images_url='http://file.tlv.redhat.com/~nmanos/rhel-custom-images/'
export RHEL74_IMG='rhel-guest-image-7.4-290_apache_php.qcow2'
export RHEL75_IMG='rhel-guest-image-7.5-190_apache_php.qcow2'
export RHEL76_IMG='rhel-guest-image-7.6-210_apache_php.qcow2'
export RHEL80_IMG='rhel-guest-image-8.0-1736_apache_php.qcow2'

# CIRROS Images
export cirros40_images_url='http://download.cirros-cloud.net/0.4.0/'
export CIRROS40_IMG='cirros-0.4.0-x86_64-disk.img'

# Windows Images
export win_images_url='http://file.tlv.redhat.com/~nmanos/windows-custom-images/'
export WIN2019_IMG='windows_2019_ssh.qcow2'

####################################################################################

# CLI user options

check_cli_args() {
  [[ -z "$1" ]] && echo "Missing arguments. Please see Help with: -h" && exit 1
}

shopt -s nocasematch # No case sensitive match for cli options
POSITIONAL=()
while [ $# -gt 0 ]; do
  # Consume next (1st) argument
  case $1 in
  -h|--help)
    echo "${disclosure}" && exit 0
    shift ;;
  -i|--image)
    check_cli_args $2
    img_name="$2"
    echo "VM image to use: $img_name"
    shift 2 ;;
  -t|--topology)
    check_cli_args $2
    topology="$2"
    [[ $topology = mni ]] && echo "Topology to create: Multiple NICs per virtual-machine"
    [[ $topology = mvi ]] && echo "Topology to create: Multiple VMs per network"
    shift 2 ;;
  -n|--networks)
    check_cli_args $2
    net_num="$2"
    echo "Number of Networks to create: $net_num"
    shift 2 ;;
  -v|--machines)
    check_cli_args $2
    inst_num="$2"
    echo "Number of VMs to create: $inst_num"
    shift 2 ;;
  --no-ipv6)
    ipv6_enable=NO
    echo "Create and test IPv6 networks: $ipv6_enable"
    shift ;;
  --admin)
    tenant_enable=NO
    echo "Create and test Non-Admin Tenant: $tenant_enable"
    shift ;;
  -e|--external)
    check_cli_args $2
    external_network_type="$2"
    echo "External network type to create: $external_network_type"
    shift 2 ;;
  -c|--cleanup)
    check_cli_args $2
    cleanup_needed="$2"
    echo "CLEANUP all OpenStack objects initially: $cleanup_needed"
    shift 2 ;;
  -d|--debug)
    debug="--debug"
    echo "Executing OpenStack commands with DEBUG verbosity"
    shift ;;
  -x|--trace)
    trace_bash=YES
    echo "Tracing BASH commands"
    shift ;;
  -q|--quit)
    check_cli_args $2
    quit_on_error="$2"
    echo "Quit on first error: $quit_on_error"
    shift 2 ;;
  -*)
    echo "$0: Error - unrecognized option $1" 1>&2
    echo "${disclosure}" && exit 1 ;;
  *)
    break ;;
  esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

####################################################################################

### FUNCTIONS ###

# Function to print $PS1 and then message
function prompt() {
  eval 'echo -e "\n'$PS1'$1\n"' | sed -e 's#\\\[##g' -e 's#\\\]##g';
}

# Function to print each bash command before it is executed (use in conjunction with "set -T"
function trap_commands() {
  # When using -x / --trace option
  if [[ "$trace_bash" = YES ]]; then
    trap '! [[ "$BASH_COMMAND" =~ ^(echo|read|\[\[|while|for|prompt) ]] && \
  cmd=`eval echo -e "[${PWD##*/}]\$ $BASH_COMMAND" 2>/dev/null` && \
  echo -e "${CYAN}$cmd${NO_COLOR}"' DEBUG
  fi
}

# Function to download file from URL, if local file doesn't exists, or has a different size on URL
function download_file() {
  # FILE_DIR => $1
  # FILE_NAME => $2

  if [[ -z "$2" ]]; then
    FILE_PATH="$1"
    FILE_NAME=$(basename "$1")
  else
    FILE_PATH="$1/$2"
    FILE_NAME=$2
  fi

  echo "Downloading $FILE_NAME from: $FILE_PATH"
  # wget does not always exists on hosts, using curl instead
  # wget -nc ${FILE_PATH} --no-check-certificate
  local_file_size=$([[ -f ${FILE_NAME} ]] && wc -c < ${FILE_NAME} || echo "0")
  remote_file_size=$(curl -sI ${FILE_PATH} | awk '/Content-Length/ { print $2 }' | tr -d '\r' )
  if [[ "$local_file_size" -ne "$remote_file_size" ]]; then
      curl -o ${FILE_NAME} ${FILE_PATH}
  else
    echo "$FILE_NAME already downloaded, and equals to remote file $FILE_PATH"
  fi
}

function create_floating_ip() {
  prompt "Creating new floating ip on external network: $ext_net"
  export fip=$(openstack floating ip create $ext_net -c floating_ip_address -f value)
  #openstack floating ip show "$fip"
}

function test_new_vm_active() {
  prompt "Waiting until the new VM \"${vm_name}\" is created and activated"

  vm_id=$(openstack server list -c ID -f value | head -1)
  CONDITION="openstack server show $vm_id | grep -E 'ACTIVE' -B 5"

  COUNT=0; ATTEMPTS=20
  until eval $CONDITION || [[ $COUNT -eq $ATTEMPTS ]]; do
    echo -e "$(( COUNT++ ))... \c"
    sleep 1
  done
  if [[ $COUNT -eq $ATTEMPTS ]]; then
    prompt "${RED} Limit of $ATTEMPTS attempts has exceeded. ${NO_COLOR}"
    return 1
  fi
  return 0
}

function test_vm_console_init() {
  prompt "Getting VNC console URL for $vm_name ($vm_id)"
  openstack console url show $vm_id

  prompt "Checking for boot errors on $vm_name ($vm_id)"
  CONDITION="openstack console log show $vm_id | grep \"${vm_name//_/-}\" -C 10"

  COUNT=0; ATTEMPTS=20
  until eval $CONDITION || [[ $COUNT -eq $ATTEMPTS ]]; do
    echo -e "$(( COUNT++ ))... \c"
    sleep 1
  done
  if [[ $COUNT -eq $ATTEMPTS ]]; then
    eval $CONDITION
    prompt "${RED} Limit of $ATTEMPTS attempts has exceeded. ${NO_COLOR}"
    return 1
  fi
  eval $CONDITION
  return 0
}

function test_fip_port_active() {
  prompt "Setting a NAME to the new floating ip port: \"${vm_name}_${fip}\""
  openstack $debug port set $port_id --name "${vm_name}_${fip}"
  openstack $debug port show $port_id

  prompt "Waiting for floating ip to be ACTIVE on $vm_name, with internal IP address $int_ipv4"
  #until openstack floating ip show "$fip" | grep -E 'ACTIVE' -B 6; do sleep 1 ; done
  CONDITION="openstack port show $port_id | grep -E 'ACTIVE' -B 14"
  COUNT=0; ATTEMPTS=20
  until eval $CONDITION || [[ $COUNT -eq $ATTEMPTS ]]; do
    echo -e "$(( COUNT++ ))... \c"
    sleep 1
  done
  if [[ $COUNT -eq $ATTEMPTS ]]; then
    prompt "${RED} Limit of $ATTEMPTS attempts has exceeded. ${NO_COLOR}"
    return 1
  fi
  return 0
}

function run_in_ssh() {
  prompt "Running within SSH $1 : $2"
  COUNT=0
  ATTEMPTS=5
  until ssh -i $KEY_FILE -o StrictHostKeyChecking=no $1 "$2" || [[ $COUNT -eq $ATTEMPTS ]]; do
    echo -e "$(( COUNT++ ))... \c"
    sleep 1
  done
  if [[ $COUNT -eq $ATTEMPTS ]]; then
    prompt "${RED} SSH command has failed. ${NO_COLOR}"
    return 1
  fi
  return 0
}

function test_connectivity() {
  prompt "Pinging the new FIP ${fip} of ${vm_name} from Undercloud (North-South test)"
  # until ping -c1 $fip ; do sleep 1 ; done
  ping -w 30 -c 5 ${fip:-NO_FIP}

  prompt "CURL to the new FIP ${fip} of ${vm_name} (TCP test on Ports 80 and 443)"
  curl $fip:80 || echo -e "\n\n ${vm_name} does not have Web server (Apache) listener on ${fip}:80\n"
  curl $fip:443 || echo -e "\n\n ${vm_name} does not have Web server (Apache) listener on ${fip}:443\n"

  prompt "Generating ssh key to access ${vm_name}: ssh-keygen -f ~/.ssh/known_hosts -R ${fip}"
  touch ~/.ssh/known_hosts
  ssh-keygen -f ~/.ssh/known_hosts -R ${fip}

  prompt "Checking within ${vm_name} uptime, and pinging 8.8.8.8 (SNAT test)"
  run_in_ssh "$ssh_user@$fip" "ping -c 1 8.8.8.8 && uptime"

  # If having more than one VM - testing connectivity between the current and the previous VM
  if [[ ! -z "$previous_fip" ]] ; then
    prompt "Checking within ${vm_name} connectivity to previous VM: $previous_vm, Floating IP: $previous_fip (IPv4 East-West test)"
    run_in_ssh "$ssh_user@$fip" "ping -c 1 $previous_fip"
  fi

  # If requested - Testing IPv6 East-West connectivity
  if [[ $ipv6_enable = YES ]] && [[ ! -z "$previous_ipv6" ]] ; then
    prompt "Checking within ${vm_name} connectivity to previous VM: $previous_vm, Internal IPv6: $previous_ipv6 (IPv6 East-West test)"
    run_in_ssh "$ssh_user@$fip" "ping6 -c 1 $previous_ipv6"
  fi

  export previous_vm=${vm_name}
  export previous_fip=$fip
  export previous_ipv6=$int_ipv6
}

function run_cleanup() {
  prompt "Deleting all VM instances"
  for vm in $(openstack server list --all -c ID -f value | grep -v "^$"); do echo -e ".\c"; openstack server delete $vm; done

  for router in $(openstack router list -c ID -f value | grep -v "^$"); do
    prompt "Removing all subnets from router (ID: $router)"
    for subnet in $(openstack subnet list -c ID -f value | grep -v "^$"); do echo -e ".\c"; openstack $debug router remove subnet $router $subnet; done;
  done

  prompt "Deleting all floating ips"
  for fip in $(openstack floating ip list -c ID -f value | grep -v "^$"); do echo -e ".\c"; openstack $debug floating ip delete $fip; done

  #for OSP 13 might need to use: neutron router-gateway-clear
  prompt "Unsetting external gateway from all routers"
  for router in $(openstack router list -c ID -f value | grep -v "^$"); do echo -e ".\c"; openstack $debug router unset --external-gateway $router; done

  prompt "Deleting all trunks"
  for trunk in $(openstack network trunk list -c ID -f value | grep -v "^$"); do echo -e ".\c"; openstack $debug network trunk delete $trunk; done

  prompt "Deleting all ports"
  for port in $(openstack port list -c ID -f value | grep -v "^$"); do echo -e ".\c"; openstack $debug port delete $port; done

  prompt "Deleting all subnets"
  for subnet in $(openstack network list --internal -c Subnets -f value | tr -d "," | grep -v "^$"); do echo -e ".\c"; openstack $debug subnet delete $subnet; done

  prompt "Deleting all routers"
  for router in $(openstack router list -c ID -f value | grep -v "^$"); do echo -e ".\c"; openstack $debug router delete $router; done

  prompt "Deleting all internal networks"
  for network in $(openstack network list --internal -c ID -f value | grep -v "^$"); do echo -e ".\c"; openstack $debug network delete $network; done

  if [[ "$external_network_type" =~ ^(flat|vlan)$ ]]; then
    prompt "You've requested to re-create external network - Deleting all external networks and subnets"
    for subnet in $(openstack subnet list -c ID -f value | grep -v "^$"); do echo -e ".\c"; openstack $debug subnet delete $subnet; done
    for network in $(openstack network list --external -c ID -f value | grep -v "^$"); do echo -e ".\c"; openstack $debug network delete $network; done
  fi

  #prompt "Deleting all VM images"
  #for img in $(openstack image list -c ID -f value | grep -v "^$"); do echo -e ".\c"; openstack $debug image delete $img; done

  #prompt "Deleting all VM flavors"
  #for flavor in $(openstack flavor list -c ID -f value | grep -v "^$"); do echo -e ".\c"; openstack $debug flavor delete $flavor; done

  prompt "Deleting all security groups"
  for secgroup in $(openstack security group list -c ID -f value | grep -v "^$"); do echo -e ".\c"; openstack $debug security group delete $secgroup; done

  prompt "Deleting Tenant Project (test_cloud), User (tester), and Keypair (tester-key)"
  rm -rf $KEY_FILE
  openstack project list | grep test_cloud && openstack $debug project delete test_cloud || echo No project test_cloud
  openstack user list | grep tester && openstack $debug user delete tester || echo No user tester
  openstack keypair list | grep tester-key && openstack $debug keypair delete tester-key || echo No keypair tester-key
}

####################################################################################

### MAIN ###

# When using -x / --trace option, the script will print each bash command before it is executed
export -f trap_commands
trap_commands;

# Evaluating general script options

# When using -q / --quit option, the script will stop executing on first error
if [[ -z "$quit_on_error" ]] || [[ "$quit_on_error" = YES ]]; then
   prompt "Script will stop executing on the first error!"
   set -e
fi

####################################################################################

# Run Cleanup ONLY

if [[ $cleanup_needed = ONLY ]]; then
    prompt "Running CLEANUP only!"
    run_cleanup;
    exit 0
fi

####################################################################################

# Check OSP version and Overcloud deployment

osp_version=$(cat /etc/yum.repos.d/latest-installed)
prompt "Base OSP version: $osp_version"
prompt "Currently deployed puddle: $(cat /etc/yum.repos.d/rhos-release-*.repo | grep -m 1 puddle_baseurl)"

osp_version=$(echo $osp_version | awk '{print $1}')

prompt "Checking Overcloud services"
if [[ "$USER" != "stack" ]]; then
    echo "You must be logged in as \"stack\" user. Exiting."
    exit 1
fi

cd /home/stack

ENV_FILE=/home/stack/overcloudrc
if [[ ! -f $ENV_FILE ]]; then
    echo "Can't find \"overcloudrc\" environment file! Overcloud must be correctly deployed. Exiting."
    exit 1
else
  prompt "Switching to Overcloud with \"overcloudrc\". Please note that any previous configuration on Undercloud with \"stackrc\" will be ignored."
    source $ENV_FILE
    openstack endpoint list
fi

####################################################################################

# Evaluating user input parameters

# Getting VMs instances operating system image
# [[ -z "$img_name" ]] && select img_name in rhel74 rhel75 rhel76 rhel80 cirros40 win2019; do [ -n "$img_name" ] && break; done
while ! [[ "$img_name" =~ ^(rhel74|rhel75|rhel76|rhel80|cirros40|win2019)$ ]]; do
  echo -e "\nWhich image do you want to use: rhel74 / rhel75 / rhel76 / rhel80 / cirros40 / win2019 ?"
  read -r img_name
done

# Getting VMs - Networks topology type
while ! [[ "$topology" =~ ^(mni|mvi)$ ]]; do
  echo -e "\nWhich Networks <--> VMs topology do you want to create ?
  * To create multiple NICs on each machine, enter: mni
  * To create multiple VMs on each network, enter: mvi"
  read -r topology
done

# Checking if external network exists
ext_net=$(openstack network list --external -c Name -f value)
if [[ -z "$ext_net" ]]; then
  echo -e "\n${RED}Warning: External network does NOT exist on Overcloud!${NO_COLOR}"
  if [[ "$external_network_type" =~ ^(skip)$ ]]; then
    # NO external network exists -> setting default network. e.g. "flat - datacentre"
    echo -e "Default external network to be created: $default_network_type - $default_physical_network"
  fi
else
  echo -e "\n${YELLOW}External network exists:${NO_COLOR} $ext_net"
  openstack network show $ext_net > EXT_NET.out
  cat EXT_NET.out
  if [[ "$external_network_type" =~ ^(skip)$ ]]; then
    # External network EXISTS -> preserving it
    default_network_type="$(grep provider:network_type EXT_NET.out | cut -d '|' -f 3 | tr -d ' ')"
    default_physical_network="$(grep provider:physical_network EXT_NET.out | cut -d '|' -f 3 | tr -d ' ')"
    echo -e "Existing external network to be used: $default_network_type - $default_physical_network"
  fi
fi

# Checking if to create new external network, and getting network details
if [[ ! "$external_network_type" =~ ^(skip)$ ]]; then
  echo -e "\nWill create a new external network, of type $external_network_type\n"

  # Getting external network type
  while ! [[ "$external_network_type" =~ ^(flat|vlan|skip)$ ]]; do
    echo -e "\nDo you want to create a new external network ?
  Press enter to skip it, otherwise enter the network type to create (flat / vlan)"
    read -i skip -e external_network_type
  done
  default_network_type=$external_network_type

  # Getting VLAN network details if required
  if [[ $external_network_type = vlan ]]; then
    while ! [[ "$physical_network_name" =~ ^([^ ]+)$ ]]; do
      echo -e "\nWhat is the VLAN Physical Network Name (for example: datacentre) ?"
      read -r physical_network_name
    done
    default_physical_network=$physical_network_name

    while ! [[ "$vlan_subnet_range" = *.*.*.*/* ]]; do
      echo -e "\nWhat is the VLAN Subnet CIDR (for example: 10.35.166.0/24) ?"
      read -r vlan_subnet_range
    done

    while ! [[ "$vlan_gateway" = *.*.*.* ]]; do
      echo -e "\nWhat is the VLAN Gateway (for example: 10.35.166.254) ?"
      read -r vlan_gateway
    done

    while ! [[ "$vlan_start" = *.*.*.* ]]; do
      echo -e "\nWhat is the VLAN Allocation Pool Start (for example: 10.35.166.100) ?"
      read -r vlan_start
    done

    while ! [[ "$vlan_end" = *.*.*.* ]]; do
      echo -e "\nWhat is the VLAN Allocation Pool End (for example: 10.35.166.140) ?"
      read -r vlan_end
    done

    while ! [[ "$vlan_id" =~ ^([0-9]+)$ ]]; do
      echo -e "\nWhat is the VLAN provider segmentation ID (for example: 181)?"
      read -r vlan_id
    done
  fi
fi

# Getting number of networks to create
while ! [[ "$net_num" =~ ^([0-9]+)$ && "$net_num" -le "100" && "$net_num" -gt "0" ]]; do
  echo -e "\nHow many internal networks do you want to create (1-100) ?"
  read -r net_num
done

# Getting number of VM instances to create
while ! [[ "$inst_num" =~ ^([0-9]+)$ && "$inst_num" -le "100" && "$inst_num" -gt "0" ]]; do
  echo -e "\nHow many VM instances do you want to create (1-100) ?
${YELLOW}NOTICE:${NO_COLOR} In a multiple VMs topology (mvi)- it's the number of instances per network!
The total number of instances will be ${YELLOW}N X $net_num ${NO_COLOR}"
  read -r inst_num
done


####################################################################################

# Running CLEANUP if required (cleanup_needed = YES)
if ! [[ "$cleanup_needed" =~ ^(NO|YES|ONLY)$ ]]; then
  echo -e "\n${YELLOW}NOTICE: Before starting, do you want to remove ALL exiting VMs and Networks ? ${NO_COLOR}
Enter in upper-case \"YES\", or press enter to skip cleanup: "
  read -r cleanup_needed
  cleanup_needed=${cleanup_needed:-NO}
fi

if [[ "$cleanup_needed" =~ ^(YES|ONLY)$ ]];  then
  run_cleanup;
  [[ "$cleanup_needed" = ONLY ]] && prompt "Exiting after cleanup!" && exit 0
fi

####################################################################################

# Downloading and creating images & flavors (as Admin)

# Windows Images
if [[ $img_name = win2019 ]]; then
  # windows 2019 download
  prompt "Downloading Windows 2019 Image file - Recommended for Baremetal compute nodes only!"
  download_file "${win_images_url}" "${WIN2019_IMG}"

  # windows 2019 image
  prompt "Creating Windows 2019 Glance Image - Recommended for Baremetal compute nodes only!"
  openstack image show $img_name || openstack -v $debug image create $img_name --container-format bare --disk-format qcow2 --public --file $WIN2019_IMG

  # windows 2019 flavor
  prompt "Creating Windows Flavor - Recommended for Baremetal compute nodes only!"
  flavor=windows_flavor_1ram_1vpu_25disk
  openstack flavor show $flavor || openstack $debug flavor create --public $flavor --id auto --ram 1024 --disk 25 --vcpus 1
  ssh_user=Administrator

else
  # CirrOS Images
  if [[ $img_name = cirros40 ]]; then
    # cirros download
    prompt "Downloading CirrOS 4.0.0 Image file"
    download_file "${cirros40_images_url}" "${CIRROS40_IMG}"

    # cirros image
    prompt "Creating CirrOS 4.0.0 Glance Image"
    openstack image show $img_name || openstack $debug image create $img_name --container-format bare --disk-format qcow2 --public --file $CIRROS40_IMG

    # cirros flavor
    prompt "Creating CirrOS Flavor"
    flavor=cirros_flavor_0.5ram_1vpu_1disk
    openstack flavor show $flavor || openstack $debug flavor create --public $flavor --id auto --ram 512 --disk 1 --vcpus 1
    ssh_user=cirros

  else
    # RHEL Images
    if [[ $img_name = rhel74 ]]; then
      # rhel v7.4 download
      prompt "Downloading RHEL v7.4 Image file"
      download_file "${rhel_images_url}" "${RHEL74_IMG}"

      # rhel v7.4 image
      prompt "Creating RHEL v7.4 Glance Image"
      openstack image show $img_name || openstack $debug image create $img_name --container-format bare --disk-format qcow2 --public --file $RHEL74_IMG

    else
      if [[ $img_name = rhel75 ]]; then
        # rhel v7.5 download
        prompt "Downloading RHEL v7.5 Image file"
        download_file "${rhel_images_url}" "${RHEL75_IMG}"

        # rhel v7.5 image
        prompt "Creating RHEL v7.5 Glance Image"
        openstack image show $img_name || openstack $debug image create $img_name --container-format bare --disk-format qcow2 --public --file $RHEL75_IMG

      else
        if [[ $img_name = rhel76 ]]; then
          # rhel v7.6 download
          prompt "Downloading RHEL v7.6 Image file"
          download_file "${rhel_images_url}" "${RHEL76_IMG}"

          # rhel v7.6 image
          prompt "Creating RHEL v7.6 Glance Image"
          openstack image show $img_name || openstack $debug image create $img_name --container-format bare --disk-format qcow2 --public --file $RHEL76_IMG

        else
          if [[ $img_name = rhel80 ]]; then
            # rhel v8.0 download
            prompt "Downloading RHEL v8.0 Image file"
            download_file "${rhel_images_url}" "${RHEL80_IMG}"

            # rhel v8.0 image
            prompt "Creating RHEL v8.0 Glance Image"
            openstack image show $img_name || openstack $debug image create $img_name --container-format bare --disk-format qcow2 --public --file $RHEL80_IMG
          fi
        fi
      fi
    fi
    # rhel flavor
    prompt "Creating RHEL Flavor"
    flavor=rhel_flavor_1ram_1vpu_10disk
    openstack flavor show $flavor || openstack $debug flavor create --public $flavor --id auto --ram 1024 --disk 10 --vcpus 1
    ssh_user=cloud-user
  fi
fi

####################################################################################

# Creating a new external network (as Admin), if requested with --external / -e
if [[ $external_network_type = vlan ]]; then
  network_name=Net_Vlan
  openstack $debug network create --provider-network-type vlan --provider-segment "$vlan_id" --provider-physical-network "${physical_network_name:-$default_physical_network}" --external "Ext_${network_name}"
  openstack $debug subnet create --subnet-range "$vlan_subnet_range" --network "Ext_${network_name}" --no-dhcp --gateway "$vlan_gateway" --allocation-pool start="$vlan_start",end="$vlan_end" "Sub_${network_name}"
else
  if [[ $external_network_type = flat ]]; then
  network_name=Net_Flat
  openstack $debug network create --provider-network-type flat --provider-physical-network "${physical_network_name:-$default_physical_network}" --external "Ext_${network_name}"
  openstack $debug subnet create --subnet-range 10.0.0.0/24 --network "Ext_${network_name}" --no-dhcp --gateway 10.0.0.1 --allocation-pool start=10.0.0.210,end=10.0.0.250 "Sub_${network_name}"
  fi
fi

# Getting external network name, and if it is not yet created, exiting with Error
ext_net=$(openstack network list --external -c Name -f value)

if [[ -z "$ext_net" ]]; then
  echo -e "\n${PS1}Error: ${RED}External network was not created, exiting!${NO_COLOR}"
  exit 1
fi

####################################################################################

# When NOT using --admin option, the script will create tenant tester (non-admin user), and all further actions will be run on Tester tenant

if [[ $tenant_enable = YES ]] ; then

  prompt "Creating Tenant user \"tester\" - a privileged user (non-admin)"
  openstack $debug project create test_cloud --enable
  openstack $debug user create tester --enable --password testerpass --project test_cloud
  openstack $debug role add _member_ --user tester --project test_cloud
  openstack user list
  openstack role list

  prompt "Creating a \"tester_rc\" environment file, which is similar to \"overcloudrc\", but with tester user limited access"
  KEYSTONE_PUBLIC_ADD=$(openstack endpoint list | grep keystone.*public | cut -d '|' -f 8 | tr -d ' ')
  echo "Keystone Public IP: $KEYSTONE_PUBLIC_ADD"

  KEYSTONE_PUBLIC_DOMAIN=$(echo $KEYSTONE_PUBLIC_ADD | cut -d ':' -f 2 | tr -d '/')
  echo "Keystone Public Domain: $KEYSTONE_PUBLIC_DOMAIN"

  KEYSTONE_ADMIN_DOMAIN=$(openstack endpoint list | grep keystone.*admin | awk -F'\\||//|:' '{print $10}' | tr -d ' ')
  echo "Keystone Admin Domain: $KEYSTONE_ADMIN_DOMAIN"

cat > tester_rc <<EOF
# Clear any old environment that may conflict.
for key in \$( set | awk '{FS="="}  /^OS_/ {print \$1}' ); do unset \$key ; done
export OS_NO_CACHE=True
export COMPUTE_API_VERSION=1.1
export OS_USERNAME=tester
export no_proxy=,${KEYSTONE_PUBLIC_DOMAIN},${KEYSTONE_ADMIN_DOMAIN}
export OS_USER_DOMAIN_NAME=Default
export OS_VOLUME_API_VERSION=3
export OS_CLOUDNAME=tester
export OS_AUTH_URL=${KEYSTONE_PUBLIC_ADD}/v3
export NOVA_VERSION=1.1
export OS_IMAGE_API_VERSION=2
export OS_PASSWORD=testerpass
export OS_PROJECT_DOMAIN_NAME=Default
export OS_IDENTITY_API_VERSION=3
export OS_PROJECT_NAME=test_cloud
export OS_AUTH_TYPE=password
export PYTHONWARNINGS="ignore:Certificate has no, ignore:A true SSLContext object is not available"

# Add OS_CLOUDNAME to PS1
if [ -z "\${CLOUDPROMPT_ENABLED:-}" ]; then
  export PS1=\\\${OS_CLOUDNAME:+"(\\\$OS_CLOUDNAME)"}\ \$PS1
  export CLOUDPROMPT_ENABLED=1
fi

# Add Timestamp to PS1
if [ -z "\${TIMESTAMP_ENABLED:-}" ]; then
  export PS1="\$HAT[\\\$(date '+%Y-%m-%d %H:%M:%S')] \$PS1"
  export TIMESTAMP_ENABLED=1
fi
EOF

  # Print diff between tester_rc and overcloudrc
  diff tester_rc overcloudrc || prompt "New environment source file was created:\"tester_rc\" "

  # Running actions as tenant tester (privileged user)
  prompt "Sourcing \"tester_rc\" environment to run actions as tenant \"tester\" (privileged user)"
  source tester_rc

fi

####################################################################################

# Creating Router, Gateway, and Internal Networks + Subnets
prompt "Creating Router and $net_num Internal Networks with Subnets"

# Create networks
openstack $debug router create Router_eNet
router_id=$(openstack router list | grep -m 1 Router_eNet | cut -d " " -f 2)

# Create internal networks and sub-networks
for i in `seq 1 $net_num`; do
  prompt "Creating Internal Network $i : int_net_$i"
  openstack $debug network create --internal int_net_$i --mtu 1442
  #openstack $debug network create --provider-network-type vxlan int_net_$i
  #openstack $debug network create --internal --share --provider-network-type $default_network_type --provider-physical-network "$default_physical_network" int_net_$i

  # Create sub-network with IPv4 and add it to the router
  prompt "Creating IPv4 Subnet on int_net_$i : subnet_ipv4_$i"
  openstack $debug subnet create --subnet-range 10.0.$i.0/24  --network int_net_$i --dhcp subnet_ipv4_$i
  prompt "Adding subnet_ipv4_$i to the router"
  openstack $debug router add subnet $router_id subnet_ipv4_$i

  # If requested - Create sub-network with IPv6 and add it to the router
  if [[ $ipv6_enable = YES ]]; then
    prompt "Creating ipv6 Subnet on int_net_$i - subnet_ipv6_$i"
    openstack $debug subnet create --subnet-range 200$i::/64 --network int_net_$i  --ipv6-address-mode slaac  --ipv6-ra-mode slaac --ip-version 6 subnet_ipv6_$i
    prompt "Adding subnet_ipv6_$i to the router"
    openstack $debug router add subnet $router_id subnet_ipv6_$i
  fi
done

# Create external gateway
prompt "Setting Router Gateway to the External Network \"$ext_net\""
if [[ $osp_version > 10 ]]; then
  openstack $debug router set --external-gateway $ext_net $router_id
  #openstack $debug router set --external-gateway $ext_net $router_id --fixed-ip ip-address=10.35.141.93
else
  neutron $debug router-gateway-set $router_id $ext_net
fi

####################################################################################

# Create security group
prompt "Creating security group rules for group \"sec_group\""
sec_id=$(openstack security group create sec_group | awk -F'[ \t]*\\|[ \t]*' '/ id / {print $3}')

# Create security group rules
openstack $debug security group rule create $sec_id --protocol tcp --dst-port 80 --remote-ip 0.0.0.0/0
openstack $debug security group rule create $sec_id --protocol tcp --dst-port 22 --remote-ip 0.0.0.0/0
openstack $debug security group rule create $sec_id --protocol tcp --dst-port 443 --remote-ip 0.0.0.0/0
openstack $debug security group rule create $sec_id --protocol icmp --dst-port -1 --remote-ip 0.0.0.0/0
# openstack $debug security group rule create $sec_id --protocol icmp --ingress --prefix 0.0.0.0/0
# openstack $debug security group rule create $sec_id --protocol tcp --ingress --prefix 0.0.0.0/0
# openstack $debug security group rule create $sec_id --protocol udp --ingress --prefix 0.0.0.0/0

# If requested - Create security group rules for IPv6
if [[ $ipv6_enable = YES ]]; then
  openstack $debug security group rule create $sec_id --protocol tcp --ingress --ethertype IPv6
  openstack $debug security group rule create $sec_id --protocol udp --ingress --ethertype IPv6
  openstack $debug security group rule create $sec_id --protocol icmp --ingress --ethertype IPv6
fi

openstack security group rule list

####################################################################################

# Create RSA private-key
prompt "Creating openstack key pair to easily login into VMs"
#openstack keypair create tester-key --private-key $KEY_FILE
openstack keypair list | grep tester-key || openstack $debug keypair create tester-key --private-key $KEY_FILE
chmod 400 $KEY_FILE
#chmod -R u+x ~/.ssh
#chmod 700 ~/.ssh
#chmod 600 ~/.ssh/authorized_keys
#restorecon -r -vv ~/.ssh/authorized_keys
#eval `ssh-agent -s`
#ssh-add ~/.ssh/id_rsa

openstack keypair list


####################################################################################

###### Creating VMs - Networks topology ######


# Create for each VM - multiple NICs (mni)
if  [[ $topology = mni ]];  then
  #Create VM instances:"
  prompt "Creating $inst_num VM instances:"
  for i in `seq 1 $inst_num`; do
     img_id=$(openstack image list | grep $img_name | head -1 | cut -d " " -f 2)
     vm_name="${img_name}-vm${i}"

     nics=""
     for n in `seq 1 $net_num`; do
       nics="$nics --nic net-id=int_net_$n"
     done

     prompt "Creating and booting VM instance with ${net_num} NICs: ${vm_name}"

     #openstack server create --flavor $flavor --image $img_name_id $nics --security-group $sec_id --key-name tester-key $vm_name
     #until openstack server show $vm_name | grep -E 'ACTIVE' -B 5; do sleep 1 ; done

     #openstack server create --flavor $flavor --image $img_name_id $nics --security-group $sec_id --key-name tester-key $vm_name |& tee _temp.out
     #vm_id=$(cat _temp.out | awk -F'[ \t]*\\|[ \t]*' '/ id / {print $3}')

     openstack $debug server create --flavor $flavor --image $img_id $nics --security-group $sec_id --key-name tester-key $vm_name

     test_new_vm_active;

     ip_addresses=$(openstack server show $vm_id -c addresses -f value)
     [[ $ipv6_enable = YES ]] && export int_ipv6=$(echo $ip_addresses | grep -Po '[\w:]+:+[\w:]+')

     ipv4s=$(echo $ip_addresses | sed -r "s/\w+:+//g" | sed -r "s/\w{4}(,|;)//g")
     prompt "Configuring Networks for each of the $net_num NICs: $ipv4s"

     # Loop over addresses of each NIC inside VM (int_net_1, int_net_2, etc.)
     # And create multiple floating ips in VM (FIP for each NIC)
     for n in `seq 1 $net_num`; do

       #create floating ip for each NIC on the VM
       create_floating_ip;

       int_ipv4=$(echo $ipv4s | awk -F int_net_${n}= '{print $2}' | cut -d ',' -f 1 | tr -d ' ')
       port_id=$(openstack port list | grep $int_ipv4 | cut -d ' ' -f 2)
       # port_id=$(openstack floating ip show $fip -c port_id -f value)

       prompt "Setting the floating ip $fip onto Port: $port_id (of the the internal IP $int_ipv4 on VM $vm_name)"
       openstack $debug floating ip set --port $port_id $fip
       sleep 10

       test_fip_port_active;

       test_vm_console_init;

       test_connectivity;
     done
  done
fi

####################################################################################

# Create for each Network - multiple VM instances (mvi)
if  [[ $topology = mvi ]];  then
  prompt "For each Network - creating $inst_num VM instances"
  for n in `seq 1 $net_num`; do
    # Create VM instances:
    for i in `seq 1 $inst_num`; do

      #create one floating ip for each VM instance
      create_floating_ip;

      img_id=$(openstack image list | grep $img_name | head -1 | cut -d " " -f 2)
      vm_name="${img_name}-vm${i}-net${n}"

      prompt "Creating and booting VM instance: ${vm_name}, connected to network int_net_${n}:"

      openstack $debug server create --flavor $flavor --image $img_id --nic net-id=int_net_$n --security-group $sec_id --key-name tester-key $vm_name

      test_new_vm_active;

      prompt "Adding the floating ip $fip to $vm_name"
      #openstack $debug server add floating ip $vm_name $fip --fixed-ip-address
      openstack $debug server add floating ip $vm_id $fip
      sleep 10

      ip_addresses=$(openstack server show $vm_id -c addresses -f value)
      [[ $ipv6_enable = YES ]] && export int_ipv6=$(echo $ip_addresses | grep -Po '[\w:]+:+[\w:]+')

      ipv4s=$(echo $ip_addresses | sed -r "s/\w+:+//g" | sed -r "s/\w{4}(,|;)//g")
      int_ipv4=$(echo $ipv4s | awk -F int_net_${n}= '{print $2}' | cut -d ',' -f 1 | tr -d ' ')
      #int_ipv4=$(openstack server list | grep $vm_id | awk '{ gsub(/[,=\|]/, " " ); print $6; }')

      port_id=$(openstack floating ip show $fip -c port_id -f value)
      # port_id=$(openstack port list | grep -A1 $int_ipv4 | cut -d " " -f 2)

      prompt "The floating ip $fip is set to Port: $port_id (of the the internal IP $int_ipv4 on VM $vm_name)"

      test_fip_port_active;

      test_vm_console_init;

      test_connectivity;
    done
  done
fi

####################################################################################

# Script completed - printing summary

openstack router list
openstack port list
openstack server list

echo -e "\n${PS1}----------------------------------------------------------------------------------------------------
Multiple VMs and Networks creation and tests completed. Please verify that the output contains no failures.
"

echo "To SSH into VM:
ssh -i $KEY_FILE ${ssh_user}@SERVER_FIP"

) |& tee $log_file

####################################################################################

# Comments
#
# Credentials for RHEL VMs: cloud-user OR root / 12345678
# ssh -i tester_key.pem cloud-user@SERVER_FIP
#
# Credentials for CirrOS VMs: cirros / cubswin:)
# ssh -i tester_key.pem cirros@SERVER_FIP
#
# Credentials for Windows 2019 VMs: Administrator / Aa123456
# ssh -i tester_key.pem administrator@SERVER_FIP

# You can find latest script here:
# https://code.engineering.redhat.com/gerrit/gitweb?p=Neutron-QE.git;a=blob;f=Scripts/create_multi_topology.sh
#
# To create a local file:
#        > create_multi_topology.sh; chmod +x create_multi_topology.sh; vi create_multi_topology.sh
#
# Execution example - recommended to run in screen:
# sudo yum install -y screen
# screen -r -d
#
# CirrOS VMs (2 instances) example:
# ./create_multi_topology.sh -x -i cirros40 -t mvi --no-ipv6 -e skip -n 2 -v 2 -c YES
#
# Windows VM (1 instance) example - Recommended for Baremetal compute nodes only:
# ./create_multi_topology.sh -x -i win2019 -t mvi --no-ipv6 -e skip -n 1 -v 1 -c YES
#
