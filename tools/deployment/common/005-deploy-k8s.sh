#!/bin/bash

# Copyright 2017 The Openstack-Helm Authors.
# Copyright 2019, AT&T Intellectual Property
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

set -xe

: ${HELM_VERSION:="v2.14.1"}
: ${KUBE_VERSION:="v1.16.2"}
: ${MINIKUBE_VERSION:="v1.3.1"}
: ${CALICO_VERSION:="v3.9"}

: "${HTTP_PROXY:=""}"
: "${HTTPS_PROXY:=""}"

export DEBCONF_NONINTERACTIVE_SEEN=true
export DEBIAN_FRONTEND=noninteractive

function configure_resolvconf {
  # Setup resolv.conf to use the k8s api server, which is required for the
  # kubelet to resolve cluster services.
  sudo mv /etc/resolv.conf /etc/resolv.conf.backup

  # Create symbolic link to the resolv.conf file managed by systemd-resolved, as
  # the kubelet.resolv-conf extra-config flag is automatically executed by the
  # minikube start command, regardless of being passed in here
  sudo ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf

  sudo bash -c "echo 'nameserver 10.96.0.10' >> /etc/resolv.conf"

  # NOTE(drewwalters96): Use the Google DNS servers to prevent local addresses in
  # the resolv.conf file unless using a proxy, then use the existing DNS servers,
  # as custom DNS nameservers are commonly required when using a proxy server.
  if [ -z "${HTTP_PROXY}" ]; then
    sudo bash -c "echo 'nameserver 8.8.8.8' >> /etc/resolv.conf"
    sudo bash -c "echo 'nameserver 8.8.4.4' >> /etc/resolv.conf"
  else
    sed -ne "s/nameserver //p" /etc/resolv.conf.backup | while read -r ns; do
      sudo bash -c "echo 'nameserver ${ns}' >> /etc/resolv.conf"
    done
  fi

  sudo bash -c "echo 'search svc.cluster.local cluster.local' >> /etc/resolv.conf"
  sudo bash -c "echo 'options ndots:5 timeout:1 attempts:1' >> /etc/resolv.conf"

  sudo rm /etc/resolv.conf.backup
}

# NOTE: Clean Up hosts file
sudo sed -i '/^127.0.0.1/c\127.0.0.1 localhost localhost.localdomain localhost4localhost4.localdomain4' /etc/hosts
sudo sed -i '/^::1/c\::1 localhost6 localhost6.localdomain6' /etc/hosts

# Install required packages for K8s on host
wget -q -O- 'https://download.ceph.com/keys/release.asc' | sudo apt-key add -
RELEASE_NAME=$(grep 'CODENAME' /etc/lsb-release | awk -F= '{print $2}')
sudo add-apt-repository "deb https://download.ceph.com/debian-mimic/
${RELEASE_NAME} main"
sudo -E apt-get update
sudo -E apt-get install -y \
    docker.io \
    socat \
    jq \
    util-linux \
    ceph-common \
    rbd-nbd \
    nfs-common \
    bridge-utils \
    iptables

sudo -E tee /etc/modprobe.d/rbd.conf << EOF
install rbd /bin/true
EOF

configure_resolvconf

# Prepare tmpfs for etcd
sudo mkdir -p /data
sudo mount -t tmpfs -o size=512m tmpfs /data

# Install minikube and kubectl
URL="https://storage.googleapis.com"
sudo -E curl -sSLo /usr/local/bin/minikube \
  "${URL}"/minikube/releases/"${MINIKUBE_VERSION}"/minikube-linux-amd64

sudo -E curl -sSLo /usr/local/bin/kubectl \
  "${URL}"/kubernetes-release/release/"${KUBE_VERSION}"/bin/linux/amd64/kubectl

sudo -E chmod +x /usr/local/bin/minikube
sudo -E chmod +x /usr/local/bin/kubectl

# Install Helm
TMP_DIR=$(mktemp -d)
sudo -E bash -c \
  "curl -sSL ${URL}/kubernetes-helm/helm-${HELM_VERSION}-linux-amd64.tar.gz | \
    tar -zxv --strip-components=1 -C ${TMP_DIR}"

sudo -E mv "${TMP_DIR}"/helm /usr/local/bin/helm
rm -rf "${TMP_DIR}"

# NOTE: Deploy kubenetes using minikube. A CNI that supports network policy is
# required for validation; use calico for simplicity.
sudo -E minikube config set kubernetes-version "${KUBE_VERSION}"
sudo -E minikube config set vm-driver none
sudo -E minikube config set embed-certs true

export CHANGE_MINIKUBE_NONE_USER=true
export MINIKUBE_IN_STYLE=false
sudo -E minikube start \
  --docker-env HTTP_PROXY="${HTTP_PROXY}" \
  --docker-env HTTPS_PROXY="${HTTPS_PROXY}" \
  --docker-env NO_PROXY="${NO_PROXY},10.96.0.0/12" \
  --network-plugin=cni \
  --extra-config=controller-manager.allocate-node-cidrs=true \
  --extra-config=controller-manager.cluster-cidr=192.168.0.0/16

curl https://docs.projectcalico.org/"${CALICO_VERSION}"/manifests/calico.yaml -o /tmp/calico.yaml
kubectl apply -f /tmp/calico.yaml

# Note: Patch calico daemonset to enable Prometheus metrics and annotations
tee /tmp/calico-node.yaml << EOF
spec:
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9091"
    spec:
      containers:
        - name: calico-node
          env:
            - name: FELIX_PROMETHEUSMETRICSENABLED
              value: "true"
            - name: FELIX_PROMETHEUSMETRICSPORT
              value: "9091"
EOF
kubectl patch daemonset calico-node -n kube-system --patch "$(cat /tmp/calico-node.yaml)"

# NOTE: Wait for dns to be running.
END=$(($(date +%s) + 240))
until kubectl --namespace=kube-system \
        get pods -l k8s-app=kube-dns --no-headers -o name | grep -q "^pod/coredns"; do
  NOW=$(date +%s)
  [ "${NOW}" -gt "${END}" ] && exit 1
  echo "still waiting for dns"
  sleep 10
done
kubectl --namespace=kube-system wait --timeout=240s --for=condition=Ready pods -l k8s-app=kube-dns

# Deploy helm/tiller into the cluster
kubectl create -n kube-system serviceaccount helm-tiller
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: helm-tiller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: helm-tiller
    namespace: kube-system
EOF

# NOTE(srwilkers): Required due to tiller deployment spec using extensions/v1beta1
# which has been removed in Kubernetes 1.16.0.
# See: https://github.com/helm/helm/issues/6374
helm init --service-account helm-tiller --output yaml \
  | sed 's@apiVersion: extensions/v1beta1@apiVersion: apps/v1@' \
  | sed 's@  replicas: 1@  replicas: 1\n  selector: {"matchLabels": {"app": "helm", "name": "tiller"}}@' \
  | kubectl apply -f -

  # Patch tiller-deploy service to expose metrics port
  tee /tmp/tiller-deploy.yaml << EOF
  metadata:
    annotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "44135"
  spec:
    ports:
    - name: http
      port: 44135
      targetPort: http
  EOF
  kubectl patch service tiller-deploy -n kube-system --patch "$(cat /tmp/tiller-deploy.yaml)"

kubectl --namespace=kube-system wait \
  --timeout=240s \
  --for=condition=Ready \
  pod -l app=helm,name=tiller
EOF

helm init --client-only

# Set up local helm server
sudo -E tee /etc/systemd/system/helm-serve.service << EOF
[Unit]
Description=Helm Server
After=network.target

[Service]
User=$(id -un 2>&1)
Restart=always
ExecStart=/usr/local/bin/helm serve

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 0640 /etc/systemd/system/helm-serve.service

sudo systemctl daemon-reload
sudo systemctl restart helm-serve
sudo systemctl enable helm-serve

# Remove stable repo, if present, to improve build time
helm repo remove stable || true

# Set up local helm repo
helm repo add local http://localhost:8879/charts
helm repo update
make

# Set required labels on host(s)
kubectl label nodes --all openstack-control-plane=enabled
kubectl label nodes --all openstack-compute-node=enabled
kubectl label nodes --all openvswitch=enabled
kubectl label nodes --all linuxbridge=enabled
kubectl label nodes --all ceph-mon=enabled
kubectl label nodes --all ceph-osd=enabled
kubectl label nodes --all ceph-mds=enabled
kubectl label nodes --all ceph-rgw=enabled
kubectl label nodes --all ceph-mgr=enabled

# Add labels to the core namespaces
kubectl label --overwrite namespace default name=default
kubectl label --overwrite namespace kube-system name=kube-system
kubectl label --overwrite namespace kube-public name=kube-public
