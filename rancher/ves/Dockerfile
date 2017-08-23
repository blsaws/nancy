FROM ubuntu:xenial
ENV TERM=xterm

RUN apt-get update
RUN apt-get -y upgrade
RUN apt-get -y install git openssh-server python python-jsonschema python-requests

RUN mkdir /opt/att/
RUN git clone https://github.com/att/evel-test-collector.git /opt/att/evel-test-collector
RUN git clone https://github.com/blsaws/nancy.git /opt/att/nancy
RUN cp /opt/att/nancy/rancher/ves/monitor.py \
  /opt/att/evel-test-collector/code/collector/monitor.py
RUN mkdir /var/log/att/
RUN touch /var/log/att/collector.log

RUN /bin/bash

