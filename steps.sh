# Variables
RESOURCE_GROUP="tour-of-heroes-aca"
LOCATION="westeurope"
CONTAINERAPPS_ENVIRONMENT="tour-of-heroes-env"

SQL_SERVER_NAME="sqlserver-for-tour-of-heroes"
SQL_USER_NAME="hero"
SQL_PASSWORD="Password1"

# Add container app extension
az extension add --name containerapp --upgrade

# Register namespaces
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.OperationalInsights
az provider register --namespace Microsoft.ContainerService

# Create a resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create a container app environment
az containerapp env create \
  --name $CONTAINERAPPS_ENVIRONMENT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

############# SQL Database #############

# Create SQL Server
az sql server create \
  --name $SQL_SERVER_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --admin-user $SQL_USER_NAME \
  --admin-password $SQL_PASSWORD

#Enable firewall to access locally
az sql server firewall-rule create \
  --resource-group $RESOURCE_GROUP \
  --server $SQL_SERVER_NAME \
  --name AllowHomeIP \
  --start-ip-address $(curl ifconfig.me) \
  --end-ip-address $(curl ifconfig.me)

# FQDN
SQL_SERVER_FQDN=$(az sql server show \
  --name $SQL_SERVER_NAME \
  --resource-group $RESOURCE_GROUP \
  --query fullyQualifiedDomainName \
  --output tsv)

echo $SQL_SERVER_FQDN

# Allow Azure services to access the SQL Server
az sql server firewall-rule create \
  --resource-group $RESOURCE_GROUP \
  --server $SQL_SERVER_NAME \
  --name AllowAzureServices \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0

# Check firewall rules
az sql server firewall-rule list \
  --resource-group $RESOURCE_GROUP \
  --server $SQL_SERVER_NAME

# Deploy the API
API_FQDN=$(az containerapp create \
  --name api \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image ghcr.io/0gis0/tour-of-heroes-dotnet-api/tour-of-heroes-api:fd0c343 \
  --ingress external \
  --target-port 5000 \
  --env-vars "ConnectionStrings__DefaultConnection=Server=tcp:$SQL_SERVER_NAME.database.windows.net,1433;Initial Catalog=heroes;Persist Security Info=False;User ID=$SQL_USER_NAME;Password=$SQL_PASSWORD;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;" \
  --query "properties.configuration.ingress.fqdn" \
  --output tsv)

# Check API logs
az containerapp logs show -n api -g $RESOURCE_GROUP

# Attach the API container
az containerapp exec -n api -g $RESOURCE_GROUP --command bash
ls

# Deploy Angular app
FRONTEND_FQDN=$(az containerapp create \
  --name frontend \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image ghcr.io/0gis0/tour-of-heroes-angular/tour-of-heroes-angular:d39626e \
  --min-replicas 1 \
  --max-replicas 5 \
  --ingress external \
  --target-port 80 \
  --exposed-port 80 \
  --env-vars "API_URL=https://$API_FQDN/api/hero" --query "properties.configuration.ingress.fqdn" \
  --output tsv)

echo "https://$FRONTEND_FQDN"

# Check frontend logs
az containerapp logs show -n angular -g $RESOURCE_GROUP

# List container apps
az containerapp list \
--resource-group $RESOURCE_GROUP \
--environment $CONTAINERAPPS_ENVIRONMENT \
-o table

az group delete -n $RESOURCE_GROUP --yes