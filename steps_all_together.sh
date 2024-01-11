# Variables
RESOURCE_GROUP="tour-of-heroes-aca"
LOCATION="westeurope"
CONTAINERAPPS_ENVIRONMENT="tour-of-heroes-env"
VNET_NAME="heroes-vnet"
KEYVAULT_NAME="heroes-kv"
SQL_CONTAINER_APP_NAME="sqlserver"
API_CONTAINER_APP_NAME="api"
FRONTEND_CONTAINER_APP_NAME="frontend"
STORAGE_ACCOUNT_NAME="heroesdatos"
STORAGE_SHARE_NAME="sqldata"
STORAGE_MOUNT_NAME="sqlserver-data"

# Add container app extension
az extension add --name containerapp --upgrade

# Register namespaces
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.OperationalInsights --wait
az provider register --namespace Microsoft.ContainerService --wait

# Create a resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create a virtual network
az network vnet create \
  --name $VNET_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --address-prefixes 10.0.0.0/16 \
  --subnet-name containers-subnet \
  --subnet-prefixes 10.0.0.0/21

# Get subnet ID
SUBNET_ID=$(az network vnet subnet show \
  --name containers-subnet \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --query id \
  --output tsv)

# Delegate the subnet to Azure Container Apps
az network vnet subnet update --ids $SUBNET_ID --delegations Microsoft.App/environments

# Create Azure Key Vault
az keyvault create \
  --name $KEYVAULT_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

# Create a secret for SQL Server SA password
SA_PWD_ID=$(az keyvault secret set \
  --vault-name $KEYVAULT_NAME \
  --name "sqlserver-sa-password" \
  --value "P@ssword123" \
  --query id \
  --output tsv)

# Load connection string into Azure Key Vault using .env file
SQL_SECRET_ID=$(az keyvault secret set \
  --vault-name heroes-kv \
  --name "sqlserver-connection-string" \
  --file .env \
  --query id \
  --output tsv)

# Create an identity for the SQL Server container
SQL_IDENTITY_ID=$(az identity create \
  --name sqlserver \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --query id \
  --output tsv)

# Give permissions to the managed identity to read the secret
az keyvault set-policy \
  --name $KEYVAULT_NAME \
  --resource-group $RESOURCE_GROUP \
  --object-id $(az identity show --id $SQL_IDENTITY_ID --query principalId --output tsv) \
  --secret-permissions get

# Create user-assigned managed identity 
API_IDENTITY_ID=$(az identity create \
  --name heroes-api \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --query id \
  --output tsv)

# Give permissions to the managed identity to read the secret
az keyvault set-policy \
  --name $KEYVAULT_NAME \
  --resource-group $RESOURCE_GROUP \
  --object-id $(az identity show --id $API_IDENTITY_ID --query principalId --output tsv) \
  --secret-permissions get

# Create a container app environment
az containerapp env create \
  --name $CONTAINERAPPS_ENVIRONMENT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --infrastructure-subnet-resource-id $SUBNET_ID

# Create an Azure Storage account
az storage account create \
  --name $STORAGE_ACCOUNT_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS \
  --enable-large-file-share \
  --kind StorageV2

# Create an Azure File Share
az storage share-rm create \
  --resource-group $RESOURCE_GROUP \
  --storage-account $STORAGE_ACCOUNT_NAME \
  --name $STORAGE_SHARE_NAME \
  --quota 1024 \
  --enabled-protocols SMB \
  --output table

# Get storage account key
STORAGE_ACCOUNT_KEY=$(az storage account keys list \
  --resource-group $RESOURCE_GROUP \
  --account-name $STORAGE_ACCOUNT_NAME \
  --query "[0].value" \
  --output tsv)

# Create the storage mount
az containerapp env storage set \
  --access-mode ReadWrite \
  --azure-file-account-name $STORAGE_ACCOUNT_NAME \
  --azure-file-account-key $STORAGE_ACCOUNT_KEY \
  --azure-file-share-name $STORAGE_SHARE_NAME \
  --storage-name $STORAGE_MOUNT_NAME \
  --name $CONTAINERAPPS_ENVIRONMENT \
  --resource-group $RESOURCE_GROUP \
  --output table

# Create SQL Server container
az containerapp create \
  --name $SQL_CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image mcr.microsoft.com/mssql/server:latest \
  --min-replicas 1 \
  --max-replicas 1 \
  --env-vars 'ACCEPT_EULA=Y' 'SA_PASSWORD=secretref:sa-pwd' \
  --user-assigned $SQL_IDENTITY_ID \
  --secrets "sa-pwd=keyvaultref:$SA_PWD_ID,identityref:$SQL_IDENTITY_ID" \
  --ingress external \
  --transport tcp \
  --target-port 1433 \
  --exposed-port 1433 \
  --cpu 1.0 \
  --memory 2.0Gi \
  --output yaml > sqlserver.yaml

# Update SQL Server container

az containerapp update \
  --name $SQL_CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --yaml sqlserver.yaml \
  --output table

# Check SQL Server logs
az containerapp logs show -n $SQL_CONTAINER_APP_NAME -g $RESOURCE_GROUP --tail 100

# Deploy the API
API_FQDN=$(az containerapp create \
  --name $API_CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --max-replicas 10 \
  --image ghcr.io/0gis0/tour-of-heroes-dotnet-api/tour-of-heroes-api:fd0c343 \
  --ingress external \
  --target-port 5000 \
  --scale-rule-name azure-http-rule \
  --scale-rule-type http \
  --scale-rule-http-concurrency 5 \
  --user-assigned $API_IDENTITY_ID \
  --secrets "connection-string=keyvaultref:$SQL_SECRET_ID,identityref:$API_IDENTITY_ID" \
  --env-vars "ConnectionStrings__DefaultConnection=secretref:connection-string" \
  --query "properties.configuration.ingress.fqdn" \
  --output tsv)

# Get API FQDN
API_FQDN=$(az containerapp show \
  --name $API_CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query "properties.configuration.ingress.fqdn" \
  --output tsv)

# Use this to call the API with the client.http file
echo "https://$API_FQDN/api/hero"

# Split your terminal and execute this command to watch how the replicas are scaled
watch -n 5 az containerapp replica count --name $API_CONTAINER_APP_NAME --resource-group $RESOURCE_GROUP

# Execute a load test
brew install hey
hey -z 60s -c 5 https://$API_FQDN

# After load test finishes, wait for a while to see how replicas are scaled down
# Check this doc about scale behaviour: https://learn.microsoft.com/en-us/azure/container-apps/scale-app?pivots=azure-cli#scale-behavior

# Check API logs
az containerapp logs show -n $API_CONTAINER_APP_NAME -g $RESOURCE_GROUP

# Attach the API container
az containerapp exec -n $API_CONTAINER_APP_NAME -g $RESOURCE_GROUP --command bash
ls

# Deploy Angular app
FRONTEND_FQDN=$(az containerapp create \
  --name frontend \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image ghcr.io/0gis0/tour-of-heroes-angular/tour-of-heroes-angular:d39626e \
  --min-replicas 1 \
  --ingress external \
  --target-port 80 \
  --exposed-port 80 \
  --revisions-mode multiple \
  --revision-suffix basic \
  --env-vars "API_URL=https://$API_FQDN/api/hero" \
  --query "properties.configuration.ingress.fqdn" \
  --output tsv)

# Create a new revision of the frontend
FRONTEND_FQDN=$(az containerapp create \
  --name frontend \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image ghcr.io/0gis0/tour-of-heroes-angular:heroes-with-pics \
  --min-replicas 1 \
  --ingress external \
  --target-port 80 \
  --exposed-port 80 \
  --env-vars "API_URL=https://$API_FQDN/api/hero" \
  --revisions-mode multiple \
  --revision-suffix pics \
  --query "properties.configuration.ingress.fqdn" \
  --output tsv)

# Traffic Split
az containerapp ingress traffic set \
  --name $FRONTEND_CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --revision-weight frontend--basic=20 frontend--pics=80

az containerapp ingress traffic show \
  --name $FRONTEND_CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP
  
echo "https://$FRONTEND_FQDN"

# Check frontend logs
az containerapp logs show -n $FRONTEND_CONTAINER_APP_NAME -g $RESOURCE_GROUP

# List container apps
az containerapp list \
--resource-group $RESOURCE_GROUP \
--environment $CONTAINERAPPS_ENVIRONMENT \
-o table

az group delete -n $RESOURCE_GROUP --yes