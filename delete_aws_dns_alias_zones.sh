#!/bin/sh

### Input & Constants ###

MY_CLUSTER_NAME="$1"
MAIN_ZONE_ID=Z3URY6TWQ91KVV
MY_DNS_ALIAS1="api.${MY_CLUSTER_NAME}.devcluster.openshift.com."
MY_DNS_ALIAS2="\052.apps.${MY_CLUSTER_NAME}.devcluster.openshift.com."
JSON_FILE=`mktemp`


### Functions ###

function create_json_for_dns_delete() {
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
  for s in $(grep -E '": [^\{]' "$1" | sed -e 's/: /=/' -e 's/^\s*//' -e "s/\(\,\)$//"); do
    echo "export $s"
    eval export $s
  done
}

function delete_aws_record_set() {
  echo -e "\nSearching in Hosted Zone [$1] - for a DNS record set: [$2]"
  aws route53 list-resource-record-sets --hosted-zone-id $MAIN_ZONE_ID --query "ResourceRecordSets[?Name == '$2']" --out json > $JSON_FILE

  cat $JSON_FILE

  if [[ $(< $JSON_FILE) == '[]' ]]; then
    echo -e "The DNS record set was not found. Did you specify correct cluster name [${MY_CLUSTER_NAME}] ? "
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
    aws route53 change-resource-record-sets --hosted-zone-id $MAIN_ZONE_ID --change-batch file://$JSON_FILE
  else
      echo -e "Delete was canceled."
  fi
}

### MAIN ###

delete_aws_record_set "$MAIN_ZONE_ID" "$MY_DNS_ALIAS1"
delete_aws_record_set "$MAIN_ZONE_ID" "$MY_DNS_ALIAS2"

### Execution example ###
# ./delete.sh "nmanos-cluster-a"

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
