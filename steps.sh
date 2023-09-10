# Variables
RESOURCE_GROUP=tour-of-heroes-aca
LOCATION=westeurope
CONTAINERAPPS_ENVIRONMENT=tour-of-heroes-env

# Add container app extension
az extension add --name containerapp --upgrade

# Register namespaces
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.OperationalInsights

# Create a resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create a container app environment
az containerapp env create \
  --name $CONTAINERAPPS_ENVIRONMENT \
  --resource-group $RESOURCE_GROUP \
  --location "$LOCATION"


# Deploy SQL Server database
az containerapp create \
  --name sqlserver \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image mcr.microsoft.com/mssql/server:latest \
  --min-replicas 1 \
  --max-replicas 1 \
  --env-vars 'ACCEPT_EULA=Y' 'SA_PASSWORD=Password1!' 'MSSQL_PID=Express' \
  --ingress internal \
  --target-port 1433



# Check SQL Server logs
az containerapp logs show -n sqlserver -g $RESOURCE_GROUP

# Deploy the API
az containerapp create \
  --name api \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image ghcr.io/0gis0/tour-of-heroes-dotnet-api/tour-of-heroes-api:f0a9419 \
  --ingress external \
  --target-port 5000 \
  --env-vars 'ConnectionStrings__DefaultConnection=Server=tcp:sqlserver,1433;Initial Catalog=heroes;Persist Security Info=False;User ID=sa;Password=Password1!;MultipleActiveResultSets=False;Encrypt=False;TrustServerCertificate=False;Connection Timeout=30;'

# Check API logs
az containerapp logs show -n api -g $RESOURCE_GROUP

# Attach the API container
az containerapp exec -n api -g $RESOURCE_GROUP --command bash
ls

# Get API FQDN
API_FQDN=$(az containerapp show -n api -g $RESOURCE_GROUP --query 'properties.configuration.ingress.fqdn' -o tsv)

# Deploy Angular app
az containerapp create \
  --name frontend \
  --resource-group $RESOURCE_GROUP \
  --environment $CONTAINERAPPS_ENVIRONMENT \
  --image ghcr.io/0gis0/tour-of-heroes-angular/tour-of-heroes-angular:d39626e \
  --min-replicas 1 \
  --max-replicas 5 \
  --ingress external \
  --target-port 80 \
  --exposed-port 80 \
  --env-vars "API_URL=https://$API_FQDN/api/hero"

# Check frontend logs
az containerapp logs show -n angular -g $RESOURCE_GROUP

# List container apps
az containerapp list \
--resource-group $RESOURCE_GROUP \
--environment $CONTAINERAPPS_ENVIRONMENT \
-o table