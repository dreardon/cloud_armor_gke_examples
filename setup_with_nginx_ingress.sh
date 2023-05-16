#!/usr/bin/env bash
# Copyright 2023 Google LLC
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

export PROJECT_ID=$DEVSHELL_PROJECT_ID
export INITIATIVE=nginx-ingress
export GKE_CLUSTER=cloud-armor-demo-$INITIATIVE
export REGION=us-central1
export ZONE=us-central1-a
export NETWORK_NAME=ca-demo-$INITIATIVE-network
export SUBNET_RANGE=10.128.0.0/20 
export CLUSTER_MASTER_IP_CIDR=172.16.0.0/28
export MY_IP=$(curl ipinfo.io/ip)

#Setup Network
gcloud compute networks create $NETWORK_NAME \
    --subnet-mode=custom 
gcloud compute networks subnets create $NETWORK_NAME-subnet \
    --network=$NETWORK_NAME \
    --range=$SUBNET_RANGE \
    --region=$REGION

#Setup NAT
gcloud compute routers create nat-router-$INITIATIVE \
  --network $NETWORK_NAME \
  --region $REGION
gcloud compute routers nats create nat-config-$INITIATIVE \
  --router-region $REGION \
  --router nat-router-$INITIATIVE \
  --nat-all-subnet-ip-ranges \
  --auto-allocate-nat-external-ips

#Create Cluster
gcloud container clusters create $GKE_CLUSTER \
--project $PROJECT_ID  \
--num-nodes 1 \
--zone $ZONE \
--machine-type "n1-standard-1" \
--disk-size "10" \
--enable-private-nodes \
--enable-ip-alias \
--workload-pool $PROJECT_ID.svc.id.goog \
--network $NETWORK_NAME \
--subnetwork $NETWORK_NAME-subnet \
--master-ipv4-cidr $CLUSTER_MASTER_IP_CIDR

gcloud container clusters get-credentials $GKE_CLUSTER \
  --zone $ZONE \
  --project $PROJECT_ID

gcloud container clusters update $GKE_CLUSTER \
    --enable-master-authorized-networks \
    --master-authorized-networks $MY_IP/32 \
    --zone $ZONE

#Configure NEGS
#TODO Determine why nginx NEG only attaches to one zone, would like to make regional cluster
NGINX_NEG_PORT=80
NGINX_NEG_NAME=${GKE_CLUSTER}-ingress-nginx-${NGINX_NEG_PORT}-neg

cat <<EOF > ${GKE_CLUSTER}-nginx-ingress-controller-values.yaml
controller:
  service:
    enableHttp: true
    type: ClusterIP
    annotations:
      cloud.google.com/neg: '{"exposed_ports": {"${NGINX_NEG_PORT}":{"name": "${NGINX_NEG_NAME}"}}}'
  config:
    use-forwarded-headers: true
EOF
helm upgrade \
    --install ingress-nginx ingress-nginx \
    --repo https://kubernetes.github.io/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    -f ${GKE_CLUSTER}-nginx-ingress-controller-values.yaml

CLUSTER_FIREWALL_RULE_TAG=$(gcloud compute instances list \
  --filter="name~^gke-cloud-armor" --limit 1  \
  --format "value(tags.items[0])")

#Configure Backend
gcloud compute firewall-rules create k8s-masters-to-nodes-on-8443 \
    --network ${NETWORK_NAME} \
    --direction INGRESS \
    --source-ranges ${CLUSTER_MASTER_IP_CIDR} \
    --target-tags ${CLUSTER_FIREWALL_RULE_TAG} \
    --allow tcp:8443

gcloud compute firewall-rules create ${GKE_CLUSTER}-allow-tcp-loadbalancer \
    --network ${NETWORK_NAME} \
    --allow tcp:${NGINX_NEG_PORT} \
    --source-ranges 130.211.0.0/22,35.191.0.0/16 \
    --target-tags ${CLUSTER_FIREWALL_RULE_TAG}

gcloud compute health-checks create http ${GKE_CLUSTER}-ingress-nginx-health-check \
    --port ${NGINX_NEG_PORT} \
    --check-interval 60 \
    --unhealthy-threshold 3 \
    --healthy-threshold 1 \
    --timeout 5 \
    --request-path /healthz

gcloud compute backend-services create ${GKE_CLUSTER}-ingress-nginx-backend-service \
    --load-balancing-scheme EXTERNAL_MANAGED \
    --protocol HTTP \
    --port-name http \
    --health-checks ${GKE_CLUSTER}-ingress-nginx-health-check \
    --enable-logging \
    --global

gcloud compute backend-services add-backend ${GKE_CLUSTER}-ingress-nginx-backend-service \
    --network-endpoint-group ${NGINX_NEG_NAME} \
    --network-endpoint-group-zone ${ZONE} \
    --balancing-mode RATE \
    --capacity-scaler 1.0 \
    --max-rate-per-endpoint 100 \
    --global

# Configure Frontend
gcloud compute url-maps create ${GKE_CLUSTER}-ingress-nginx-loadbalancer \
    --default-service ${GKE_CLUSTER}-ingress-nginx-backend-service

gcloud compute target-http-proxies create ${GKE_CLUSTER}-ingress-nginx-http-proxy \
    --url-map ${GKE_CLUSTER}-ingress-nginx-loadbalancer

gcloud compute forwarding-rules create ${GKE_CLUSTER}-http-forwarding-rule \
  --global \
  --load-balancing-scheme EXTERNAL_MANAGED \
  --target-http-proxy=${GKE_CLUSTER}-ingress-nginx-http-proxy \
  --ports=80


# Deploy App
kubectl create deployment hello-${INITIATIVE} \
    --image us-docker.pkg.dev/google-samples/containers/gke/hello-app:1.0 \
    --port 8080

kubectl expose deployment hello-${INITIATIVE} \
    --port 80 \
    --target-port 8080 \
    --type ClusterIP

#Connect the App to the Ingress Controller
cat << EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-${INITIATIVE}
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - backend:
          service:
            name: hello-$INITIATIVE
            port:
              number: 80
        path: /
        pathType: Prefix
EOF

export LB_IP=$(gcloud compute forwarding-rules list --filter=target:${GKE_CLUSTER}-ingress-nginx-http-proxy | grep IP_ADDRESS | cut -d' ' -f2)

while : ; do
    curl http://$LB_IP
done

gcloud compute security-policies create ${GKE_CLUSTER}-security-policy

gcloud compute security-policies rules create 1000 \
--action=deny-403 \
--security-policy=${GKE_CLUSTER}-security-policy \
--description="deny $MY_IP" \
 --src-ip-ranges=$MY_IP

#Manually Apply to Target in GUI or
#Run the following gcloud

gcloud compute backend-services update ${GKE_CLUSTER}-ingress-nginx-backend-service \
--global \
--security-policy ${GKE_CLUSTER}-security-policy

#Clean up
echo 'Y' | gcloud container clusters delete $GKE_CLUSTER \
--project $PROJECT_ID  \
--zone $ZONE

echo 'Y' | gcloud compute routers delete nat-router-$INITIATIVE \
  --region $REGION


echo 'Y' | gcloud compute forwarding-rules delete ${GKE_CLUSTER}-http-forwarding-rule --global
echo 'Y' | gcloud compute target-http-proxies delete ${GKE_CLUSTER}-ingress-nginx-http-proxy 
echo 'Y' | gcloud compute url-maps delete ${GKE_CLUSTER}-ingress-nginx-loadbalancer
echo 'Y' | gcloud compute backend-services delete ${GKE_CLUSTER}-ingress-nginx-backend-service --global
echo 'Y' | gcloud compute firewall-rules delete k8s-masters-to-nodes-on-8443
echo 'Y' | gcloud compute firewall-rules delete ${GKE_CLUSTER}-allow-tcp-loadbalancer
echo 'Y' | gcloud compute health-checks delete ${GKE_CLUSTER}-ingress-nginx-health-check 


echo 'Y' | gcloud compute network-endpoint-groups delete $NGINX_NEG_NAME --zone $ZONE

echo 'Y' | gcloud compute networks subnets delete $NETWORK_NAME-subnet --region $REGION
echo 'Y' | gcloud compute networks delete $NETWORK_NAME 

echo 'Y' | gcloud compute security-policies delete ${GKE_CLUSTER}-security-policy
