FROM ubuntu:xenial

RUN apt-get update
RUN apt-get -y upgrade
RUN apt-get -y install git openssh-server python python-jsonschema

RUN git clone https://github.com/att/evel-test-collector.git
RUN git clone https://github.com/blsaws/nancy.git

RUN cp nancy/rancher/ves/monitor.py \
  evel-test-collector/code/collector/monitor.py

RUN top

