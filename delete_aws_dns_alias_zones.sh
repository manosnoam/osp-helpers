#!/bin/sh

### An interactive script to delete DNS Record-sets from AWS Route53. ###
#
# Currently supports deleting Alias Hosted Zones,
# that were created by Openshift Installer, on devcluster.openshift.com:
#
# DNS Alias Record-set 1: api.${YOUR_CLUSTER_NAME}.devcluster.openshift.com.
# DNS Alias Record-set 2: *.apps.${YOUR_CLUSTER_NAME}.devcluster.openshift.com.
#
# Execution example ###
# ./delete_aws_dns_alias_zones.sh "nmanos-cluster-a"
#

### Input & Constants ###

YOUR_CLUSTER_NAME="$1"
MAIN_ZONE_NAME="devcluster.openshift.com"
MAIN_ZONE_ID="Z3URY6TWQ91KVV"
YOUR_DNS_ALIAS1="api.${YOUR_CLUSTER_NAME}.${MAIN_ZONE_NAME}."
YOUR_DNS_ALIAS2="\052.apps.${YOUR_CLUSTER_NAME}.${MAIN_ZONE_NAME}."
JSON_FILE=`mktemp`


### Functions ###

function create_json_for_dns_delete() {
  # Input $1 : File to write the json output to
  (
  cat <<EOF
  {
      "Comment": "Delete single record set",
      "Changes": [
          {
              "Action": "DELETE",
              "ResourceRecordSet": {
                  "Name": "$(echo ${Name/\\052/*})",
                  "Type": "$Type",
                  "AliasTarget": {
                    "HostedZoneId": "$HostedZoneId",
                    "DNSName": "$DNSName",
                    "EvaluateTargetHealth": $EvaluateTargetHealth
                    }}
                }]
    }
EOF
  ) > $1
}

function export_vars_from_json() {
  # Input $1 : Json file to read variables from
  for s in $(grep -E '": [^\{]' "$1" | sed -e 's/: /=/' -e 's/^\s*//' -e "s/\(\,\)$//"); do
    echo "export $s"
    eval export $s
  done
}

function delete_aws_record_set() {
  # Input $1 : Hosted Zone ID
  # Input $2 : DNS record-set (name) to delete
  echo -e "\nSearching in Hosted Zone [$1] - for a DNS record set: [$2]"
  aws route53 list-resource-record-sets --hosted-zone-id $1 --query "ResourceRecordSets[?Name == '$2']" --out json > $JSON_FILE

  cat $JSON_FILE

  if [[ $(< $JSON_FILE) == '[]' ]]; then
    echo -e "The DNS record set was not found. Did you specify correct cluster name [${YOUR_CLUSTER_NAME}] ? "
    return
  fi

  echo -e "\nExporting DNS record set variables:"
  export_vars_from_json "$JSON_FILE"

  echo -e "\nCreating json file for DNS record set delete command:"
  create_json_for_dns_delete "$JSON_FILE"
  cat "$JSON_FILE"

  read -r -p $'\nDELETE this DNS record - Are you sure? [y/N]' response
  if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo -e "\nDeleting the DNS record set:"
    aws route53 change-resource-record-sets --hosted-zone-id $1 --change-batch file://$JSON_FILE
  else
      echo -e "Delete was canceled."
  fi
}

### MAIN ###

delete_aws_record_set "$MAIN_ZONE_ID" "$YOUR_DNS_ALIAS1"
delete_aws_record_set "$MAIN_ZONE_ID" "$YOUR_DNS_ALIAS2"

### Output example ###
#
# Searching in Hosted Zone [Z3URY6TWQ91KVV] - for a DNS record set: [api.nmanos-cluster-a.devcluster.openshift.com.]
# []
# The DNS record set was not found. Did you specify correct cluster name [nmanos-cluster-a] ?
#
# Searching in Hosted Zone [Z3URY6TWQ91KVV] - for a DNS record set: [*.apps.nmanos-cluster-a.devcluster.openshift.com.]
# [
#     {
#         "Name": "\\052.apps.nmanos-cluster-a.devcluster.openshift.com.",
#         "Type": "A",
#         "AliasTarget": {
#             "HostedZoneId": "Z35SXDOTRQ7X7K",
#             "DNSName": "a24096707046511ea91d50270ec04a49-1391380692.us-east-1.elb.amazonaws.com.",
#             "EvaluateTargetHealth": false
#         }
#     }
# ]
#
# Exporting DNS record set variables:
# export "Name"="\\052.apps.nmanos-cluster-a.devcluster.openshift.com."
# export "Type"="A"
# export "HostedZoneId"="Z35SXDOTRQ7X7K"
# export "DNSName"="a24096707046511ea91d50270ec04a49-1391380692.us-east-1.elb.amazonaws.com."
# export "EvaluateTargetHealth"=false
#
# Creating json file for DNS record set delete command:
#   {
#       "Comment": "Delete single record set",
#       "Changes": [
#           {
#               "Action": "DELETE",
#               "ResourceRecordSet": {
#                   "Name": "*.apps.nmanos-cluster-a.devcluster.openshift.com.",
#                   "Type": "A",
#                   "AliasTarget": {
#                     "HostedZoneId": "Z35SXDOTRQ7X7K",
#                     "DNSName": "a24096707046511ea91d50270ec04a49-1391380692.us-east-1.elb.amazonaws.com.",
#                     "EvaluateTargetHealth": false
#                     }}
#                 }]
#     }
#
# DELETE this DNS record - Are you sure? [y/N]y
#
# Deleting the DNS record set:
# CHANGEINFO	Delete single record set	/change/C10NWUAXPBFIJ3	PENDING	2019-11-17T10:42:38.862Z
#
