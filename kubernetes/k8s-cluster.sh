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
# What this is: script to setup a kubernetes cluster with calico as sni
# Prerequisites: 
# - Ubuntu xenial server for master and agent nodes
# - key-based auth setup for ssh/scp between master and agent nodes
# - 192.168.0.0/16 should not be used on your server network interface subnets

# Usage:
# $ source k8s-cluster.sh "<space-separated list of agent IPs>"
#   e.g "172.16.0.5 172.16.0.6 172.16.0.7 172.16.0.8"
#

cat <<'EOG' >/tmp/prereqs.sh
#!/bin/bash
  # Basic server pre-reqs
  sudo apt-get update
  sudo apt-get upgrade -y
  # Set hostname on agent nodes
  if [[ "$1" == "agent" ]]; then
    echo $(ip route get 8.8.8.8 | awk '{print $NF; exit}') $HOSTNAME | sudo tee -a /etc/hosts
  fi
  # Install docker 1.12 (default for xenial is 1.12.6)
  sudo apt-get install -y docker.io
  sudo service docker start
  # Install kubectl per https://kubernetes.io/docs/tasks/tools/install-kubectl/        
  curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
  chmod +x ./kubectl 
  sudo mv ./kubectl /usr/local/bin/kubectl
  # Install kubelet & kubeadm per https://kubernetes.io/docs/setup/independent/install-kubeadm/
  sudo apt-get update && sudo apt-get install -y apt-transport-https
  curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
  cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
  sudo apt-get update
  sudo apt-get install -y kubelet kubeadm
EOG

# Install master 
bash /tmp/prereqs.sh master
# If the following command fails, run "kubeadm reset" before trying again
#  --pod-network-cidr=192.168.0.0/16 is required for calico; this should not conflict with your server network interface subnets
sudo kubeadm init --pod-network-cidr=192.168.0.0/16 >>/tmp/kubeadm.out
cat /tmp/kubeadm.out
joincmd=$(grep "kubeadm join" /tmp/kubeadm.out)

# Start cluster
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
# Deploy pod network
sudo kubectl apply -f http://docs.projectcalico.org/v2.4/getting-started/kubernetes/installation/hosted/kubeadm/1.6/calico.yaml

# Install agents
agents=$1
for agent in $agents; do
scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no /tmp/prereqs.sh ubuntu@$agent:/tmp/prereqs.sh
ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$agent bash /tmp/prereqs.sh agent
# Workaround for "[preflight] Some fatal errors occurred: /var/lib/kubelet is not empty" per https://github.com/kubernetes/kubeadm/issues/1
ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$agent sudo kubeadm reset
ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$agent sudo $joincmd
done