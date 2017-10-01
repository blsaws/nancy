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

#. Usage:
#. $ git clone https://github.com/blsaws/nancy.git 
#. $ cd nancy/kubernetes
#. $ source k8s-cluster.sh master
#. run "watch kubectl get pods --all-namespaces" until kube-dns pod is "ready"
#. $ source k8s-cluster.sh agents "<space-separated list of agent IPs>"
#.   e.g source k8s-cluster.sh agents "10.5.62.3 10.5.62.4 10.5.62.5"
#. $ source k8s-cluster.sh ceph <ceph_dev> "<nodes>" <cluster-net> <public-net>
#.     ceph_dev: disk to use for ceph. ***MUST NOT BE USED FOR ANY OTHER PURPOSE***
#.     nodes: space-separated list of ceph node IPs
#.     cluster-net: CIDR of ceph cluster network (typically private)
#.     public-net: CIDR of public network
#.   e.g source k8s-cluster.sh ceph "10.5.62.3 10.5.62.4 10.5.62.5" 10.5.62.2/24 204.178.3.195/27
#.   The master node will be setup as ceph-mon and the agents as ceph-osd
#. If you want to setup helm as app kubernetes orchestration tool:
#. $ source k8s-cluster.sh helm
#

function setup_prereqs() {
  echo "$0: Create prerequisite setup script"
  cat <<'EOG' >/tmp/prereqs.sh
#!/bin/bash
# Basic server pre-reqs
sudo apt-get -y remove kubectl kubelet kubeadm
sudo apt-get update
sudo apt-get upgrade -y
# Set hostname on agent nodes
if [[ "$1" == "agent" ]]; then
  echo $(ip route get 8.8.8.8 | awk '{print $NF; exit}') $HOSTNAME | sudo tee -a /etc/hosts
fi
# Install docker 1.12 (default for xenial is 1.12.6)
sudo apt-get install -y docker.io
sudo service docker start
export KUBE_VERSION=1.7.5
# per https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/
# Install kubelet, kubeadm, kubectl per https://kubernetes.io/docs/setup/independent/install-kubeadm/
sudo apt-get update && sudo apt-get install -y apt-transport-https
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
sudo apt-get update
# Next command is to workaround bug resulting in "PersistentVolumeClaim is not bound" for pod startup (remain in Pending)
sudo apt-get -y install ceph-common
sudo apt-get -y install --allow-downgrades kubectl=${KUBE_VERSION}-00 kubelet=${KUBE_VERSION}-00 kubeadm=${KUBE_VERSION}-00
EOG
}

function setup_k8s_master() {
  echo "$0: Setting up kubernetes master"

  # Install master 
  bash /tmp/prereqs.sh master
  # per https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/
  # If the following command fails, run "kubeadm reset" before trying again
  # --pod-network-cidr=192.168.0.0/16 is required for calico; this should not conflict with your server network interface subnets
  sudo kubeadm init --pod-network-cidr=192.168.0.0/16 >>/tmp/kubeadm.out
  cat /tmp/kubeadm.out
  export k8s_joincmd=$(grep "kubeadm join" /tmp/kubeadm.out)
  echo "$0: Cluster join command for manual use if needed: $k8s_joincmd"

  # Start cluster
  echo "$0: Start the cluster"
  mkdir -p $HOME/.kube
  sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  # Deploy pod network
  echo "$0: Deploy calico as CNI"
  sudo kubectl apply -f http://docs.projectcalico.org/v2.4/getting-started/kubernetes/installation/hosted/kubeadm/1.6/calico.yaml
}

function setup_k8s_agents() {
  export k8s_joincmd=$(grep "kubeadm join" /tmp/kubeadm.out)
  echo "$0: Installing agents at $1 with joincmd: $k8s_joincmd"
  agents="$1"
  for agent in $agents; do
    echo "$0: Install agent at $agent"
    scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no /tmp/prereqs.sh ubuntu@$agent:/tmp/prereqs.sh
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$agent bash /tmp/prereqs.sh agent
    # Workaround for "[preflight] Some fatal errors occurred: /var/lib/kubelet is not empty" per https://github.com/kubernetes/kubeadm/issues/1
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$agent sudo kubeadm reset
    ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$agent sudo $k8s_joincmd
  done
}

function setup_ceph() {
  ceph_dev=$1
  ceph_dev="sdb"
  node_ips=$2
  node_ips="10.5.62.3 10.5.62.4 10.5.62.5"
  cluster_net=$3
  cluster_net="10.5.62.2/24"
  public_net=$4
  public_net="204.178.3.195/27"
  # Also caches the server fingerprints so ceph-deploy does not prompt the user
  for node_ip in $node_ips; do
    echo "$0: Install ntp and ceph on $node_ip"
    ssh -x -o StrictHostKeyChecking=no ubuntu@$node_ip <<EOF
sudo timedatectl set-ntp no
wget -q -O- 'https://download.ceph.com/keys/release.asc' | sudo apt-key add -
echo deb https://download.ceph.com/debian/ $(lsb_release -sc) main | sudo tee /etc/apt/sources.list.d/ceph.list
sudo apt update
sudo apt-get install -y ntp ceph ceph-deploy
EOF
  done
  mon_ip=$(echo $node_ips | cut -d ' ' -f 1)
  mon_host=$(ssh -x -o StrictHostKeyChecking=no ubuntu@$mon_ip hostname)
  echo "$0: Deploying ceph-mon on localhost $HOSTNAME"
  echo "$0: Deploying ceph-osd on nodes $node_ips"
  echo "$0: Setting cluster-network=$cluster_net and public-network=$public_net"

  # per http://docs.ceph.com/docs/master/start/quick-ceph-deploy/
  sudo timedatectl set-ntp no
  wget -q -O- 'https://download.ceph.com/keys/release.asc' | sudo apt-key add -
  echo deb https://download.ceph.com/debian/ $(lsb_release -sc) main | sudo tee /etc/apt/sources.list.d/ceph.list
  sudo apt update
  sudo apt-get install -y ceph ceph-deploy ntp
  mkdir ~/ceph-cluster
  cd ~/ceph-cluster
  ceph-deploy new --cluster-network $cluster_net --public-network $public_net --no-ssh-copykey $HOSTNAME
  ceph-deploy install $node_ips
  ceph-deploy mon create-initial
  ceph-deploy admin $node_ips
  for node_ip in $node_ips; do
    echo "$0: Create ceph osd on $node_ip using $ceph_dev"
    ceph-deploy osd create $node_ip:$ceph_dev
  done
  ssh -x -o StrictHostKeyChecking=no ubuntu@$mon_ip sudo ceph health
  ssh -x -o StrictHostKeyChecking=no ubuntu@$mon_ip sudo ceph -s
}

function setup_helm() {
  echo "$0: Setup helm"
  # Install Helm
  cd ~
  curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get > get_helm.sh
  chmod 700 get_helm.sh
  ./get_helm.sh
  helm init
  helm repo update
  # Workaround for bug https://github.com/kubernetes/helm/issues/2224
  # For testing use only!
  kubectl create clusterrolebinding permissive-binding --clusterrole=cluster-admin --user=admin --user=kubelet --group=system:serviceaccounts;
  # Install services via helm charts from https://kubeapps.com/charts
  # e.g. helm install stable/dokuwiki
}

export WORK_DIR=$(pwd)
case "$1" in
  master)
    setup_prereqs
    setup_k8s_master
    ;;
  agents)
    kubedns=$(kubectl get pods --all-namespaces | grep kube-dns | awk '{print $4}')
    while [[ "$kubedns" != "Running" ]]; do
      echo "$0: kube-dns status is $kubedns. Waiting 60 seconds for it to be 'Running'" 
      sleep 60
      kubedns=$(kubectl get pods --all-namespaces | grep kube-dns | awk '{print $4}')
    done
    echo "$0: kube-dns status is $kubedns" 
    setup_prereqs
    setup_k8s_agents "$2"
    echo "$0: All done. Kubernetes cluster is ready when all nodes in the output of 'kubectl get nodes' show as 'Ready'."
    echo "$0: In the meantime, you can run this cmd to setup helm as app orchestrator: bash $WORK_DIR/k8s-cluster.sh helm"
    echo "$0: Then to test helm: helm install --name minecraft --set minecraftServer.eula=true stable/minecraft"
    ;;
  ceph)
    setup_ceph $2 $3 $4 $5
    ;;
  helm)
    setup_helm
    ;;
  clean)
    # TODO
    ;;
  *)
    grep '#. ' $0
esac
