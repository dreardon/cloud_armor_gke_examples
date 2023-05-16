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
export INITIATIVE=default-ingress
export GKE_CLUSTER=cloud-armor-demo-$INITIATIVE
export REGION=us-central1
export ZONE=us-central1-c
export NETWORK_NAME=ca-demo-$INITIATIVE-network
export SUBNET_RANGE=10.128.0.0/20 
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
--region $REGION \
--num-nodes 1 \
--machine-type "n1-standard-1" \
--disk-size "10" \
--enable-private-nodes \
--enable-ip-alias \
--workload-pool $PROJECT_ID.svc.id.goog \
--network $NETWORK_NAME \
--subnetwork $NETWORK_NAME-subnet \
--master-ipv4-cidr "172.16.0.0/28"

gcloud container clusters get-credentials $GKE_CLUSTER \
  --region $REGION \
  --project $PROJECT_ID

gcloud container clusters update $GKE_CLUSTER \
    --enable-master-authorized-networks \
    --master-authorized-networks $MY_IP/32 \
    --region $REGION

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world-deployment-$INITIATIVE
  labels: 
    app: hello-$INITIATIVE
spec:
  selector:
    matchLabels:
      app: hello-$INITIATIVE
  replicas: 1 
  template:
    metadata:
      labels:
        app: hello-$INITIATIVE
    spec:
      containers:
        - name: hello-world-deployment-$INITIATIVE-pod
          image: us-docker.pkg.dev/google-samples/containers/gke/hello-app:1.0
          ports: 
          - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: hello-$INITIATIVE
  labels:
    app: hello-app-$INITIATIVE
  annotations:
    cloud.google.com/neg: '{"ingress": true}'
spec:
  type: ClusterIP
  selector:
    app: hello-$INITIATIVE
  ports:
    - port: 8080
      protocol: TCP
      targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-$INITIATIVE
spec:
  defaultBackend:
    service:
      name: hello-$INITIATIVE
      port:
        number: 8080
EOF

kubectl get ingress

gcloud compute security-policies create ${GKE_CLUSTER}-security-policy

gcloud compute security-policies rules create 1000 \
--action=deny-403 \
--security-policy=${GKE_CLUSTER}-security-policy \
--description="deny $MY_IP" \
 --src-ip-ranges=$MY_IP

export INGRESS_IP=$(kubectl get ingress hello-$INITIATIVE -ojson | jq -r '.status.loadBalancer.ingress[].ip')

while : ; do
    curl http://$INGRESS_IP
done


#Manually Apply to Target in GUI or
#Run the below Terraform
kubectl apply -f - <<EOF
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  namespace: default
  name: cloudarmor-block-my-ip
spec:
  securityPolicy:
    name: ${GKE_CLUSTER}-security-policy
---
apiVersion: v1
kind: Service
metadata:
  name: hello-$INITIATIVE
  labels:
    app: hello-app-$INITIATIVE
  annotations:
    cloud.google.com/backend-config: '{"ports": {"8080":"cloudarmor-block-my-ip"}}'
    cloud.google.com/neg: '{"ingress": true}'
spec:
  type: ClusterIP
  selector:
    app: hello-$INITIATIVE
  ports:
    - port: 8080
      protocol: TCP
      targetPort: 8080
EOF

#Clean up and Destroy
export NEGS=$(kubectl get svc hello-$INITIATIVE -o jsonpath='{.metadata.annotations.cloud\.google\.com/neg-status}' | jq '.network_endpoint_groups."8080"' -r)

echo 'Y' | gcloud container clusters delete $GKE_CLUSTER \
--project $PROJECT_ID  \
--region $REGION

echo 'Y' | gcloud compute routers delete nat-router-$INITIATIVE \
  --region $REGION

#TODO Add real logic to iterate and delete NGINX_NEG_NAME in zones
CurZones="us-central1-a us-central1-c us-central1-b us-central1-f"
for zone in $CurZones; do
echo 'Y' | gcloud compute network-endpoint-groups delete $NEGS --zone $zone
done

echo 'Y' | gcloud compute networks subnets delete $NETWORK_NAME-subnet --region $REGION
echo 'Y' | gcloud compute networks delete $NETWORK_NAME 

echo 'Y' | gcloud compute security-policies delete ${GKE_CLUSTER}-security-policy
