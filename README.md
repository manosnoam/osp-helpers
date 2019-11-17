# shift-stack-helpers
OpenStack and OpenShift bash scripts for testers / admins.

#### find_openstack_errors.sh
An interactive script to easily search for OpenStack errors on all Overcloud nodes.
  
#### delete_aws_dns_alias_zones.sh
An interactive script to delete DNS Record-sets from AWS Route53.
  
#### osp_create_multi_topology.sh
An interactive script to create and test OpenStack topologies, including:
* Multiple VM instances of following Operating Systems: RHEL (8.0, 7.6, 7.5, 7.4), Cirros and Windows.
* Multiple Networks and NICs with IPv4 & IPv6 subnets and Floating IPs, connected to external networks (Flat / Vlan)
* Tests includes: SSH Keypair, non-admin Tenant, Security group for HTTP/S, North-South, East-West, SNAT, and more.

Feel free to contact me: nmanos@redhat.com
