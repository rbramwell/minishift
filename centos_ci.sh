#!/bin/bash

# Copyright (C) 2016 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Output command before executing
set -x

# Exit on error
set -e

# Source environment variables of the jenkins slave
# that might interest this worker.
function load_jenkins_vars() {
  if [ -e "jenkins-env" ]; then
    cat jenkins-env \
      | grep -E "(JENKINS_URL|GIT_BRANCH|GIT_COMMIT|BUILD_NUMBER|ghprbSourceBranch|ghprbActualCommit|BUILD_URL|ghprbPullId|GH_TOKEN|CICO_API_KEY|JOB_NAME)=" \
      | sed 's/^/export /g' \
      > ~/.jenkins-env
    source ~/.jenkins-env
  fi

  echo 'CICO: Jenkins ENVs loaded'
}

function install_core_deps() {
  # We need to disable selinux for now, XXX
  /usr/sbin/setenforce 0

  # Get all the deps in
  yum -y install gcc \
                 make \
                 git \
                 curl

  echo 'CICO: Core dependencies installed'
}

function install_kvm_virt() {
  sudo yum -y install kvm \
                      qemu-kvm \
                      libvirt
  # Start Libvirt
  sudo systemctl start libvirtd
  echo 'CICO: KVM hypervisor installed and started'

  # Add minishift_ci to libvirt group
  gpasswd -a minishift_ci libvirt && systemctl restart libvirtd
}

function install_docker() {
  yum install -y docker
  systemctl start docker

  docker version
  echo 'CICO: Docker installed and started'

  # Add minishift_ci to docker group
  groupadd docker && gpasswd -a minishift_ci docker && systemctl restart docker
}

# Create a docs user which has NOPASSWD sudoer role
function prepare_ci_user() {
  groupadd -r minishift_ci && useradd -g minishift_ci minishift_ci
  chmod +w /etc/sudoers && echo "minishift_ci ALL=(ALL)    NOPASSWD: ALL" >> /etc/sudoers && chmod -w /etc/sudoers

  # Copy centos_ci.sh to newly created user home dir
  cp centos_ci.sh /home/minishift_ci/
  mkdir /home/minishift_ci/payload
  # Copy minishift repo content into minishift_ci user payload directory for later use
  cp -R . /home/minishift_ci/payload
  chown -R minishift_ci:minishift_ci /home/minishift_ci/payload

  # Copy the jenkins-env into minishift_ci home dir
  cp ~/.jenkins-env /home/minishift_ci/jenkins-env
}

####### Below functions are executed by minishift_ci user
function setup_kvm_docker_machine_driver() {
  curl -L https://github.com/dhiltgen/docker-machine-kvm/releases/download/v0.7.0/docker-machine-driver-kvm > docker-machine-driver-kvm && \
  chmod +x docker-machine-driver-kvm && sudo mv docker-machine-driver-kvm /usr/local/bin/docker-machine-driver-kvm
  echo 'CICO: Setup KVM docker-machine driver setup successfully'
}

function install_and_setup_golang() {
  # Install Go 1.7
  curl -LO https://storage.googleapis.com/golang/go1.7.linux-amd64.tar.gz
  tar -xf go1.7.linux-amd64.tar.gz
  sudo mv go /usr/local

  # Setup GOROOT
  export GOROOT=/usr/local/go
  # Setup GOPATH
  mkdir $HOME/gopath $HOME/gopath/src $HOME/gopath/bin $HOME/gopath/pkg
  export GOPATH=$HOME/gopath
  export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
}

function setup_repo() {
  # Setup minishift repo
  mkdir -p $GOPATH/src/github.com/minishift
  cp -r /home/minishift_ci/payload $GOPATH/src/github.com/minishift/minishift
}

function setup_glide() {
  # Setup Glide ("curl https://glide.sh/get | sh" not working due to https://github.com/Masterminds/glide/issues/708)
  GLIDE_OS_ARCH=`go env GOHOSTOS`-`go env GOHOSTARCH`
  GLIDE_TAG=v0.12.3
  GLIDE_LATEST_RELEASE_URL="https://github.com/Masterminds/glide/releases/download/${GLIDE_TAG}/glide-${GLIDE_TAG}-${GLIDE_OS_ARCH}.tar.gz"
  curl -LO ${GLIDE_LATEST_RELEASE_URL}
  mkdir /tmp/glide
  tar --directory=/tmp/glide -xvf glide-${GLIDE_TAG}-${GLIDE_OS_ARCH}.tar.gz
  export PATH=$PATH:/tmp/glide/${GLIDE_OS_ARCH}
}

function prepare() {
  echo "UID in prepare: $UID"
  install_and_setup_golang;
  setup_repo;
  setup_glide;

  echo "CICO: Preparation complete"
}

function run_tests() {
  cd $GOPATH/src/github.com/minishift/minishift
  make clean test cross fmtcheck prerelease
  # Run integration test with 'kvm' driver
  MINISHIFT_VM_DRIVER=kvm make integration

  echo "CICO: Tests ran successfully"
}

function artifacts_upload_on_pr_and_master_trigger() {
  set +x
  # For PR build, GIT_BRANCH is set to branch name other than origin/master
  if [[ "$GIT_BRANCH" = "origin/master" ]]; then
    # http://stackoverflow.com/a/22908437/1120530; Using --relative as --rsync-path not working
    mkdir -p minishift/master/$BUILD_NUMBER/
    cp -r out/*-amd64 minishift/master/$BUILD_NUMBER/
    RSYNC_PASSWORD=$1 rsync -a --delete --relative minishift/master/$BUILD_NUMBER/ minishift@artifacts.ci.centos.org::minishift/
    echo "Find Artifacts here http://artifacts.ci.centos.org/minishift/minishift/master/$BUILD_NUMBER ."
  else
    # http://stackoverflow.com/a/22908437/1120530; Using --relative as --rsync-path not working
    mkdir -p minishift/pr/$ghprbPullId/
    cp -r out/*-amd64 minishift/pr/$ghprbPullId/
    RSYNC_PASSWORD=$1 rsync -a --delete --relative minishift/pr/$ghprbPullId/ minishift@artifacts.ci.centos.org::minishift/
    echo "Find Artifacts here http://artifacts.ci.centos.org/minishift/minishift/pr/$ghprbPullId ."
  fi
}

function docs_tar_upload() {
  set -x

  version=$(cat docs/build/variables.adoc | cut -d' ' -f2 | head -n1)
  mkdir -p minishift/docs/$version
  cp docs/build/minishift-adoc.tar minishift/docs/$version/
  ln -s $(pwd)/minishift/docs/$version minishift/docs/latest
  # http://stackoverflow.com/a/22908437/1120530; Using --relative as --rsync-path not working
  RSYNC_PASSWORD=$1 rsync -aL --relative minishift/docs minishift@artifacts.ci.centos.org::minishift/
  echo "Find docs tar here http://artifacts.ci.centos.org/minishift/minishift/docs/latest."
}

if [[ "$UID" = 0 ]]; then
  load_jenkins_vars;
  prepare_ci_user;
  install_core_deps;
  install_kvm_virt;
  install_docker;
  runuser -l minishift_ci -c "/bin/bash centos_ci.sh"
else
  source ~/jenkins-env # Source environment variables for minishift_ci user
  PASS=$(echo $CICO_API_KEY | cut -d'-' -f1-2)

  if [[ "$JOB_NAME" = "minishift-docs" ]]; then
    prepare;
    cd gopath/src/github.com/minishift/minishift
    make gen_adoc_tar
    docs_tar_upload $PASS
  else
    setup_kvm_docker_machine_driver;
    prepare;
    run_tests;
    artifacts_upload_on_pr_and_master_trigger $PASS;
  fi
fi
