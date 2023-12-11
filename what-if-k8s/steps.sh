# Variables
RESOURCE_GROUP="what-if-k8s"
LOCATION="westeurope"
AKS_NAME="k8s-vs-aca"

# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create AKS cluster
az aks create \
--resource-group $RESOURCE_GROUP \
--name $AKS_NAME \
--node-vm-size Standard_B4ms \
--enable-keda \
--network-plugin azure \
--enable-oidc-issuer \
--enable-workload-identity \
--generate-ssh-keys

# Get AKS credentials
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME --overwrite-existing

##########################################################################################
################################## App Gw for Containers ############################
##########################################################################################

# Configure Traffic Splitting

# Register required resource providers on Azure.
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.NetworkFunction
az provider register --namespace Microsoft.ServiceNetworking

# Install Azure CLI extensions.
az extension add --name alb

# Install the ALB Controller
ALB_IDENTITY_NAME="azure-alb-identity"

ALB_IDENTITY_PRINCIPAL_ID=$(az identity create \
--name $ALB_IDENTITY_NAME \
--resource-group $RESOURCE_GROUP \
--location $LOCATION \
--query principalId \
--output tsv)

echo "Waiting 60 seconds to allow for replication of the identity..."
sleep 60

AKS_RESOURCE_GROUP=$(az aks show \
--resource-group $RESOURCE_GROUP \
--name $AKS_NAME \
--query nodeResourceGroup \
--output tsv)

AKS_RESOURCE_GROUP_ID=$(az group show \
--resource-group $AKS_RESOURCE_GROUP \
--query id \
--output tsv)

# Apply Reader role to the AKS managed cluster resource group for the newly provisioned identity
az role assignment create \
--assignee-object-id $ALB_IDENTITY_PRINCIPAL_ID \
--assignee-principal-type ServicePrincipal \
--scope $AKS_RESOURCE_GROUP_ID \
--role "acdd72a7-3385-48ef-bd42-f606fba81ae7" # Reader role

# Echo setup federation with AKS OIDC issuer
AKS_OIDC_ISSUER="$(az aks show -n "$AKS_NAME" -g "$RESOURCE_GROUP" --query "oidcIssuerProfile.issuerUrl" -o tsv)"
#ALB Controller requires a federated credential with the name of azure-alb-identity. Any other federated credential name is unsupported.
az identity federated-credential create --name "azure-alb-identity" \
--identity-name "$ALB_IDENTITY_NAME" \
--resource-group $RESOURCE_GROUP \
--issuer "$AKS_OIDC_ISSUER" \
--subject "system:serviceaccount:azure-alb-system:alb-controller-sa"

# Install ALB Controller
helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller \
--version 0.6.3 \
--set albController.namespace=azure-alb-system \
--set albController.podIdentity.clientID=$(az identity show -g $RESOURCE_GROUP -n azure-alb-identity --query clientId -o tsv)

# Verify the ALB Controller is running
watch kubectl get pods -n azure-alb-system

# Get AKS vnet name from the node resource group
AKS_VNET_NAME=$(az network vnet list -g $AKS_RESOURCE_GROUP --query "[].name" -o tsv)

# Create a subnet for App Gw for containers
SUBNET_ADDRESS_PREFIX="10.225.0.0/24"
ALB_SUBNET_NAME="subnet-alb"
az network vnet subnet create \
  --resource-group $AKS_RESOURCE_GROUP \
  --vnet-name $AKS_VNET_NAME \
  --name $ALB_SUBNET_NAME \
  --address-prefixes $SUBNET_ADDRESS_PREFIX \
  --delegations 'Microsoft.ServiceNetworking/trafficControllers'

ALB_SUBNET_ID=$(az network vnet subnet show --name $ALB_SUBNET_NAME --resource-group $AKS_RESOURCE_GROUP --vnet-name $AKS_VNET_NAME --query '[id]' --output tsv)

# ALB Controller needs the ability to provision new Application Gateway for Containers resources and to join the subnet intended for the Application Gateway for Containers association resource.
# Delegate AppGw for Containers Configuration Manager role to AKS Managed Cluster RG
az role assignment create --assignee-object-id $ALB_IDENTITY_PRINCIPAL_ID --assignee-principal-type ServicePrincipal --scope $AKS_RESOURCE_GROUP_ID --role "AppGw for Containers Configuration Manager" 

# Delegate Network Contributor permission for join to association subnet
az role assignment create --assignee-object-id $ALB_IDENTITY_PRINCIPAL_ID --assignee-principal-type ServicePrincipal --scope $ALB_SUBNET_ID --role "Network Contributor" 


# Create ApplicationLoadBalancer Kubernetes resource
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: tour-of-heroes
EOF

# create the Application Gateway for Containers resource and association.
kubectl apply -f - <<EOF
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata:
  name: alb-for-heroes
  namespace: tour-of-heroes
spec:
  associations:
  - $ALB_SUBNET_ID
EOF


# It can take 5-6 minutes for the Application Gateway for Containers resources to be created.
kubectl get applicationloadbalancer alb-for-heroes -n tour-of-heroes -o yaml -w

# Now test with tour of heroes
kubectl apply -f what-if-k8s/. --recursive -n tour-of-heroes

watch kubectl get pods -n tour-of-heroes 

# Generate a frontend in the App Gw for containers for the frontend
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: tour-of-heroes-gateway
  namespace: tour-of-heroes
  annotations:
    alb.networking.azure.io/alb-namespace: tour-of-heroes
    alb.networking.azure.io/alb-name: alb-for-heroes
spec:
  gatewayClassName: azure-alb-external
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
EOF

watch kubectl get gateway tour-of-heroes-gateway -n tour-of-heroes -o yaml


# Create an HTTPRoute to route traffic to the frontend with and without pics
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: traffic-split-route
  namespace: tour-of-heroes
spec:
  parentRefs:
  - name: tour-of-heroes-gateway
  rules:
  - backendRefs:
    - name: tour-of-heroes-web
      port: 80
      weight: 50
    - name: tour-of-heroes-web-with-pics
      port: 80
      weight: 50
EOF

kubectl get httproute traffic-split-route -n tour-of-heroes -o yaml

kubectl get httproute

# Test the application
fqdn=$(kubectl get gateway tour-of-heroes-gateway -n default -o jsonpath='{.status.addresses[0].value}')

echo "https://$fqdn"

kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: tour-of-heroes-api-gateway
  namespace: tour-of-heroes
  annotations:
    alb.networking.azure.io/alb-namespace: tour-of-heroes
    alb.networking.azure.io/alb-name: alb-for-heroes
spec:
  gatewayClassName: azure-alb-external
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
EOF

# Create a route to the API
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: api-route
  namespace: tour-of-heroes
spec:
  parentRefs:
  - name: tour-of-heroes-api-gateway
  rules:
  - backendRefs:
    - name: tour-of-heroes-api
      port: 80
EOF

# Check http route
kubectl get httproute api-route -n tour-of-heroes -o yaml

# Get the API FQDN
api_fqdn=$(kubectl get gateway tour-of-heroes-api-gateway -n tour-of-heroes -o jsonpath='{.status.addresses[0].value}')

echo "http://$api_fqdn/api/hero"

##########################################################################################
############################## Configure KEDA for autoscaling ############################
##########################################################################################

# Check if KEDA is installed
kubectl get pods -n kube-system | grep keda

# Install http-add-on (https://keda.sh/blog/2021-06-24-announcing-http-add-on/)
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install -n kube-system http-add-on kedacore/keda-add-ons-http

# Scale based on HTTP requests to the API
kubectl apply -f - <<EOF
apiVersion: http.keda.sh/v1alpha1
kind: HTTPScaledObject
metadata:
  name: http-scaledobject
  namespace: tour-of-heroes
spec:
  hosts: 
  - tour-of-heroes.com    
  scaleTargetRef:
    deployment: tour-of-heroes-api
    service: tour-of-heroes-api
    port: 80
  targetPendingRequests: 10
  replicas:
    min: 0
    max: 10
EOF

kubectl get httpscaledobject -n tour-of-heroes
kubectl describe httpscaledobject -n tour-of-heroes
kubectl get hpa -n tour-of-heroes

kubectl get pods -n kube-system | grep keda

# Check logs of a pod with these labels: app.kubernetes.io/component=operator and app.kubernetes.io/instance=http-add-on
kubectl logs -n kube-system -l app.kubernetes.io/component=operator,app.kubernetes.io/instance=http-add-on -c keda-add-ons-http-operator

# Watch tour of heroes api replicas
watch kubectl get pods  -n tour-of-heroes

# Load test the application
brew install hey
# 
# curl  http://20.54.216.159/api/hero -H 'Host: tour-of-heroes.com'

# Port forward to the KEDA http interceptor
kubectl port-forward svc/keda-add-ons-http-interceptor-proxy 8080:8080 -n kube-system

curl  http://localhost:8080/api/hero -H 'Host: tour-of-heroes.com'
echo "http://localhost:8080/api/hero" | xargs -I % -P 10 curl -H 'Host: tour-of-heroes.com' %

hey -n 100000 -host "tour-of-heroes.com" http://localhost:8080/api/hero

kubectl proxy -p 8002
watch curl -L localhost:8002/api/v1/namespaces/kube-system/services/keda-add-ons-http-interceptor-admin:9090/proxy/queue

# Check the HPA
kubectl get hpa -n tour-of-heroes

# Check the pods
kubectl get pods -n tour-of-heroes

# Check KEDA logs
kubectl logs -n kube-system -l app=keda-operator