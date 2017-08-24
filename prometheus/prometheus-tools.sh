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
# What this is: Functions for testing with Prometheus. 
# Prerequisites: 
# - Ubuntu server for master and agent nodes
# Usage:
# $ source prometheus-tools.sh
# See below for function-specific usage
#

# Prometheus
# https://prometheus.io/download/
# https://prometheus.io/docs/introduction/getting_started/
# https://github.com/prometheus/prometheus
# https://prometheus.io/docs/instrumenting/exporters/
# https://github.com/prometheus/node_exporter
# https://github.com/prometheus/haproxy_exporter
# https://github.com/prometheus/collectd_exporter

# Prerequisites
sudo apt install -y golang-go

# Install Prometheus server
mkdir ~/prometheus
cd  ~/prometheus
wget https://github.com/prometheus/prometheus/releases/download/v2.0.0-beta.2/prometheus-2.0.0-beta.2.linux-amd64.tar.gz
tar xvfz prometheus-*.tar.gz
cd prometheus-*
# Customize prometheus.yml below for your server IPs
# This example assumes the node_exporter and haproxy_exporter will be installed on each node
cat <<'EOF' >prometheus.yml
global:
  scrape_interval:     15s # By default, scrape targets every 15 seconds.

  # Attach these labels to any time series or alerts when communicating with
  # external systems (federation, remote storage, Alertmanager).
  external_labels:
    monitor: 'codelab-monitor'

# A scrape configuration containing exactly one endpoint to scrape:
# Here it's Prometheus itself.
scrape_configs:
  # The job name is added as a label `job=<job_name>` to any timeseries scraped from this config.
  - job_name: 'prometheus'

    # Override the global default and scrape targets from this job every 5 seconds.
    scrape_interval: 5s

    static_configs:
      - targets: ['172.16.0.7:9100']
      - targets: ['172.16.0.7:9101']
      - targets: ['172.16.0.8:9100']
      - targets: ['172.16.0.8:9101']
      - targets: ['172.16.0.9:9100']
      - targets: ['172.16.0.9:9101']
EOF
# Start Prometheus
nohup ./prometheus -config.file=prometheus.yml &
# Browse to http://localhost:9090

# Install exporters
# https://github.com/prometheus/node_exporter
cd ~/prometheus
wget https://github.com/prometheus/node_exporter/releases/download/v0.14.0/node_exporter-0.14.0.linux-amd64.tar.gz
tar xvfz node*.tar.gz
# https://github.com/prometheus/haproxy_exporter
wget https://github.com/prometheus/haproxy_exporter/releases/download/v0.7.1/haproxy_exporter-0.7.1.linux-amd64.tar.gz
tar xvfz haproxy*.tar.gz

# The scp and ssh actions below assume you have key-based access enabled to the nodes
nodes="172.16.0.7 172.16.0.8 172.16.0.9" 
for node in $nodes; do
  scp -r -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    node_exporter-0.14.0.linux-amd64/node_exporter ubuntu@$node:/home/ubuntu/node_exporter
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    ubuntu@$node "nohup ./node_exporter > /dev/null 2>&1 &"
  scp -r -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    haproxy_exporter-0.7.1.linux-amd64/haproxy_exporter ubuntu@$node:/home/ubuntu/haproxy_exporter
  ssh -x -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    ubuntu@$node "nohup ./haproxy_exporter > /dev/null 2>&1 &"
done

# Setup Prometheus datasource for Grafana
# This assumes you have installed Grafana e.g. per https://etherpad.opnfv.org/p/bryan-rancher
cd ~/prometheus/
id=$(rancher ps | grep " grafana/grafana " | awk "{print \$1}")
grafana_ip=$(rancher inspect $id | jq -r ".publicEndpoints[0].ipAddress")
cat >datasources.json <<EOF
{"name":"Prometheus", "type":"prometheus", "access":"proxy", \
"url":"http://172.16.0.2:9090/", "basicAuth":false,"isDefault":true }
EOF
curl -X POST -u admin:password -H "Accept: application/json" \
  -H "Content-type: application/json" \
  -d @datasources.json http://admin:admin@$grafana_ip:3000/api/datasources

# Setup Prometheus dashboards
# https://grafana.com/dashboards?dataSource=prometheus
# Browse the dashboard and import the dashboard via the id displayed for the dashboard
# Select the home icon (upper left), Dashboards / Import, enter the id, select load, and select the Prometheus datasource
# Docker\ and\ system\ monitoring-1503539436994.json
# Docker\ Dashboard-1503539375161.json
# Docker\ Host\ &\ Container\ Overview-1503539411705.json
# Node\ Exporter\ Server\ Metrics-1503539692670.json
# Node\ exporter\ single\ server-1503539807236.json

# Scripted API import is not working at the moment - some json file formatting issue as downlloaded
mkdir ~/prometheus/dashboards
cd ~/prometheus/dashboards
boards=$(ls)
for board in $boards; do
  sed -i -- 's/  "id": null,\a
  curl -X POST -u admin:password -H "Accept: application/json" \
    -H "Content-type: application/json" \
    -d @${board} http://admin:admin@$grafana_ip:3000/api/dashboards/db
done
