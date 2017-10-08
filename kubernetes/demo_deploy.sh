#!/bin/bash
# Copyright 2017 Bryan Sullivan
#  
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#  
# http://www.apache.org/licenses/LICENSE-2.0
#  
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#. What this is: Complete scripted deployment of an experimental kubernetes + 
#. helm + prometheus + grafana platform. When complete, kubernetes will be setup
#. with dokuwiki installed as a demo app, and prometheus+grafana setup for 
#. cluster monitoring/stats, with some demo grafana dashboards installed.
#. Prometheus dashboard: http://<admin_public_ip>:9090
#. Grafana dashboard: http://<admin_public_ip>:3000
#. 
#. Prerequisites:
#. - Ubuntu server for kubernetes cluster nodes (admin/master and agent nodes)
#. - MAAS server as cluster admin for kubernetes master/agent nodes
#. - Password-less ssh key provided for node setup
#. Usage: on the MAAS server
#. $ git clone https://github.com/blsaws/nancy.git 
#. $ bash nancy/kubernetes/demo_deploy.sh <key> "<hosts>" <admin ip> 
#.     "<agent ips>" <pub-net> <priv-net> [<extras>]
#. <key>: name of private key for cluster node ssh (in current folder)
#. <hosts>: space separated list of hostnames managed by MAAS
#. <admin ip>: IP of cluster admin node
#. <agent_ips>: space separated list of agent node IPs
#. <pub-net>: CID formatted public network
#. <priv-net>: CIDR formatted private network (may be same as pub-net)
#. <extras>: optional name of script for extra setup functions as needed

function wait_node_status() {
  status=$(maas opnfv machines read hostname=$1 | jq -r ".[0].status_name")
  while [[ "x$status" != "x$2" ]]; do
    echo "$1 status is $status ... waiting for it to be $2"
    sleep 30
    status=$(maas opnfv machines read hostname=$1 | jq -r ".[0].status_name")
  done
  echo "$1 status is $status"
}

function release_nodes() {
  nodes=$1
  for node in $nodes; do
    echo "Releasing node $node"
    id=$(maas opnfv machines read hostname=$node | jq -r '.[0].system_id')
    maas opnfv machines release machines=$id
  done
}

function deploy_nodes() {
  nodes=$1
  for node in $nodes; do
    echo "Deploying node $node"
    id=$(maas opnfv machines read hostname=$node | jq -r '.[0].system_id')
    maas opnfv machines allocate system_id=$id
    maas opnfv machine deploy $id
  done
}

function wait_nodes_status() {
  nodes=$1
  for node in $nodes; do
    wait_node_status $node $2
  done
}

key=$1
nodes="$2"
admin_ip=$3
agent_ips="$4"
priv_net=$5
pub_net=$6
extras=$7

release_nodes "$nodes"
wait_nodes_status "$nodes" Ready
deploy_nodes "$nodes"
wait_nodes_status "$nodes" Deployed
ssh-keygen -f ~/.ssh/known_hosts -R $admin_ip
eval `ssh-agent`
ssh-add $key
if [[ "x$extras" != "x" ]]; then source $extras; fi
scp -o StrictHostKeyChecking=no $key ubuntu@$admin_ip:/home/ubuntu/$key
ssh -x ubuntu@$admin_ip <<EOF
exec ssh-agent bash
ssh-add $key
echo "Cloning nancy..."
git clone https://github.com/blsaws/nancy.git
echo "Setting up kubernetes..."
bash nancy/kubernetes/k8s-cluster.sh all "$agent_ips" $priv_net $pub_net
echo "Setting up prometheus..."
bash nancy/prometheus/prometheus-tools.sh all "$agent_ips"
echo "All done!"
EOF
