# Cloud Armor Integration Examples with GKE

Google Cloud Armor helps you protect your Google Cloud deployments from multiple types of threats, including distributed denial-of-service (DDoS) attacks and application attacks like cross-site scripting (XSS) and SQL injection (SQLi). [Kubernetes Ingress](https://cloud.google.com/kubernetes-engine/docs/how-to/ingress-configuration) can be [configured](https://cloud.google.com/armor/docs/integrating-cloud-armor#with_ingress) to work with Cloud Armor.

The scripts in this project can be used to stand up a sample cluster defended by Cloud Armor using one of the following GKE ingress options:
- Default GKE Ingress or 
- Nginx Ingress 

## Google Disclaimer
This is not an officially supported Google product

## For More Detail
- https://cloud.google.com/kubernetes-engine/docs/how-to/ingress-configuration#cloud_armor
- https://cloud.google.com/armor/docs/security-policy-overview
- https://medium.com/google-cloud/secure-your-nginx-ingress-controller-behind-cloud-armor-805d6109af86
- https://stackoverflow.com/questions/72476714/global-load-balancer-https-loadbalancer-in-front-of-gke-nginx-ingress-controll/72940666#72940666
