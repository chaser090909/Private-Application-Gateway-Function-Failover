# Deployment guide

Step-by-step deployment of the private Application Gateway DR stack: two
private-only gateways (East US primary, Central US secondary), each with an Azure
Container Instances backend on a private IP, split across three resource groups,
with a watchdog Function App and a monitoring layer that repoint private DNS when
a region goes down.

For a description of every file, see [FILES.md](FILES.md).

## Contents

1. [Before you start](#1-before-you-start)
2. [Sign in and select the subscription](#2-sign-in-and-select-the-subscription)
3. [Register subscription prerequisites](#3-register-subscription-prerequisites)
4. [Configure variables](#4-configure-variables)
5. [Initialize Terraform](#5-initialize-terraform)
6. [Review the plan](#6-review-the-plan)
7. [Apply](#7-apply)
8. [Verify the infrastructure](#8-verify-the-infrastructure)
9. [Verify the watchdog and monitoring](#9-verify-the-watchdog-and-monitoring)
10. [Run a failover drill](#10-run-a-failover-drill)
11. [Optional: test from inside the VNet](#11-optional-test-from-inside-the-vnet)
12. [Troubleshooting](#12-troubleshooting)
13. [Teardown](#13-teardown)

---

## 1. Before you start

### Tooling

| Tool | Minimum | Check |
| --- | --- | --- |
| Terraform | 1.9 | `terraform version` |
| Azure CLI | 2.60 | `az version` |
| Python | 3.11 | `python --version` |
| `jq` | any | only for the Bash drill script |

The Azure CLI is required, not optional. Terraform shells out to it to publish
the watchdog code with an Oryx remote build, and both helper scripts are built on
it. Python is only needed if you want to lint the watchdog locally.

On Windows, run Terraform from PowerShell. The watchdog publish provisioner uses
PowerShell explicitly so it can operate from this UNC workspace; the default
`cmd.exe` interpreter cannot use UNC paths as its current directory.

### Permissions

You need three rights on the target subscription:

- **Contributor**, for the networking, gateway, container, app, and monitoring
  resources.
- **User Access Administrator** (or Owner, which includes it), for two reasons.
  The stack creates a *custom role definition* for the watchdog, which needs
  `Microsoft.Authorization/roleDefinitions/write`, and it creates five role
  assignments, which need `roleAssignments/write`.
- Permission to register resource providers and preview features, for step 3.

Contributor alone is not enough. The apply will get most of the way through and
then fail on `azurerm_role_definition.watchdog`.

### Quota

| Resource | Count | Notes |
| --- | --- | --- |
| Application Gateway v2 | 1 per region | 1 instance each |
| Container group | 1 per region | 1 vCPU / 1 GB |
| Standard public IP | 1 per region | NAT gateway |
| App Service plan | 1 | B1 Basic, shared region |
| Log Analytics workspace | 1 | shared region |
| VM cores | 2 | only if `deploy_test_vm = true` |

---

## 2. Sign in and select the subscription

```powershell
az login
az account set --subscription "<subscription-name-or-id>"
$env:ARM_SUBSCRIPTION_ID = (az account show --query id -o tsv)
```

```bash
az login
az account set --subscription "<subscription-name-or-id>"
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

Terraform reads `ARM_SUBSCRIPTION_ID` from the environment. If you would rather`ncommit the value, set `subscription_id` in the Terraform variables file (`terraform.tfvars`) instead.

---

## 3. Register subscription prerequisites

A private-only Application Gateway is a v2 gateway with no public frontend,
gated behind the `EnableApplicationGatewayNetworkIsolation` preview feature.
Feature and provider registration are subscription-wide one-time operations that
Terraform does not model, so they live in a script:

```powershell
./scripts/register-prereqs.ps1
```

```bash
chmod +x scripts/register-prereqs.sh
./scripts/register-prereqs.sh
```

Confirm before moving on:

```powershell
az feature show --namespace Microsoft.Network `
  --name EnableApplicationGatewayNetworkIsolation --query properties.state -o tsv
```

You want `Registered`. Applying while this says `Pending` fails gateway creation
with an error about the missing public frontend that does not obviously point
back at the feature flag.

---

## 4. Configure variables

```powershell\n# run from the terraform/ directory\nCopy-Item terraform.tfvars.example terraform.tfvars\n```\n\nEvery variable has a working default, so an empty `terraform.tfvars` file is valid.
The ones you are most likely to change:

| Variable | Default | Why you would change it |
| --- | --- | --- |
| `primary_resource_group_name` | `rg-appgw-primary-eus` | Naming standards |
| `secondary_resource_group_name` | `rg-appgw-secondary-cus` | Naming standards |
| `shared_resource_group_name` | `rg-appgw-shared-group` | Naming standards |
| `primary_location` / `secondary_location` | `eastus` / `centralus` | Different region pair |
| `private_dns_zone_name` | `internal.contoso.com` | Your own zone |
| `container_image` | `aci-helloworld` | Your own workload |
| `health_probe_path` | `/` | Your app's health endpoint |
| `watchdog_schedule` | `*/30 * * * * *` | Slower or faster detection |
| `app_service_plan_sku` | `B1` | Larger plan |
| `alert_email_address` | `""` | Get notified as well as failed over |
| `deploy_test_vm` | `false` | You want an in-VNet curl client |

Two constraints to keep in mind:

- `primary_appgw_private_ip` and `secondary_appgw_private_ip` must fall inside
  their region's gateway subnet prefix. Nothing validates this until Azure
  rejects the gateway, so check by hand if you change the addressing.
- `app_service_plan_sku` must be a tier that supports Always On. Basic and above
  qualify; a Consumption plan does not, and the 30-second timer would stall.

If you set `deploy_test_vm = true` you must also set `test_vm_ssh_public_key`. A
resource precondition fails the plan with a clear message if you forget.

---

## 5. Initialize Terraform

```powershell
terraform init
terraform fmt -recursive -check
terraform validate
```

State is local by default; point it at a remote backend before using this
anywhere shared.

---

## 6. Review the plan

```powershell
terraform plan -out tfplan
```

Expect roughly 50 resources. Read the plan for four things in particular:

- Both gateways show a `frontend_ip_configuration` with
  `private_ip_address_allocation = "Static"` and **no** `public_ip_address_id`.
  That absence is what makes them private-only.
- Backend pool `ip_addresses` are `(known after apply)`. They resolve to the
  container groups' private IPs, which Azure assigns at creation.
- `azurerm_linux_function_app.watchdog` has `storage_uses_managed_identity = true`
  and no `storage_account_access_key`, and its `app_settings` contain no
  `WEBSITE_RUN_FROM_PACKAGE`.
- `azurerm_role_definition.watchdog` grants exactly three actions.

---

## 7. Apply

```powershell
terraform apply tfplan
```

**Budget 25 to 35 minutes.** The two Application Gateways dominate and build in
parallel; each carries a 60-minute timeout. Rough ordering:

1. Three resource groups, workspace, App Insights (1-2 minutes)
2. VNets, subnets, NAT gateways (2-3 minutes)
3. Container groups, pulling their image out through the NAT gateway (2-4 minutes)
4. Application Gateways, in parallel (10-20 minutes each)
5. Private DNS zone, links, A record (1 minute)
6. Storage, B1 plan, Function App (2-3 minutes)
7. Custom role, five role assignments, then the code publish (2-4 minutes)
8. Action group, alerts, dashboard (1-2 minutes)

The publish step runs `az functionapp deployment source config-zip
--build-remote true` through a provisioner, and its output appears inline. It
must complete for anything to fail over, so do not ignore a failure here.

Give the watchdog a couple of minutes after apply. The timer does not run on
startup, and the role assignments it depends on take a moment to propagate.

---

## 8. Verify the infrastructure

```powershell
terraform output
./scripts/dr-drill.ps1 validate
```

```bash
chmod +x scripts/dr-drill.sh
./scripts/dr-drill.sh validate    # needs jq
```

**Three resource groups.** The `resource_groups` output names all three.

**Both gateways provisioned with private IPs.** The drill prints each gateway's
`provisioningState` and private frontend; you want `Succeeded` with `10.1.1.10`
and `10.2.1.10`.

**Backend pools on ACI private IPs, passing their custom probes.** The drill
prints backend health per gateway. You want one address per gateway reporting
healthy, in `10.1.2.0/24` and `10.2.2.0/24`, matching the `backend_aci_ip`
values in the outputs.

**Peering in both directions.** `vnet_peering_state` names both. To confirm they
actually connected:

```powershell
az network vnet peering list -g rg-appgw-dr-eus --vnet-name vnet-eus-dr `
  --query "[].{Name:name,State:peeringState}" -o table
```

You want `Connected`, not `Initiated`.

---

## 9. Verify the watchdog and monitoring

The drill's `validate` action covers most of this, but these are the checks worth
understanding individually.

**The watchdog indexed both triggers.** This is the single most important check,
because a failed remote build looks exactly like a healthy deployment until you
need it:

```powershell
$fn = (terraform output -json watchdog | ConvertFrom-Json).name
az functionapp function list -g rg-appgw-dr-shared -n $fn `
  --query "[].{Function:name,Trigger:config.bindings[0].type}" -o table
```

You want **two** rows: `watchdog` with `timerTrigger` and `region_failover` with
`httpTrigger`. An empty list or one row means the publish did not land or the
dependencies did not install.

**The identity can actually do its job.** Five assignments, all on the same
principal:

```powershell
$pid = (terraform output -json watchdog | ConvertFrom-Json).principal_id
az role assignment list --assignee $pid --all `
  --query "[].{Role:roleDefinitionName,Scope:scope}" -o table
```

Expect the custom watchdog role on both regional groups, `Private DNS Zone
Contributor` on the zone, and three storage data roles.

**The webhook responds.** This posts a synthetic alert; the watchdog re-reads
live state, so it reports the truth rather than forcing a failover:

```powershell
./scripts/dr-drill.ps1 webhook
```

You want JSON with `primary_up: true` and `active: "primary"`.

**The dashboard has data.** Open the **Private Application Gateway DR** workbook
in `rg-appgw-dr-shared`. Metric ingestion into the workspace lags a few minutes
after apply, so give it time before concluding the charts are broken. The
failover path does not depend on this pipeline.

**Watchdog decisions are being logged:**

```kusto
AppTraces
| where TimeGenerated > ago(30m)
| where Message has_any ("evaluated", "repointed", "unavailable")
| project TimeGenerated, SeverityLevel, Message
| order by TimeGenerated desc
```

You should see a `watchdog evaluated` line roughly every 30 seconds.

---

## 10. Run a failover drill

```powershell
./scripts/dr-drill.ps1 failover
```

The drill stops `aci-eus-dr` and polls DNS until it points at the secondary
gateway. On success it prints `PASS: app.internal.contoso.com now resolves to the
secondary region (10.2.1.10)`. It gives up after 10 minutes; override with
`-TimeoutMinutes`.

Expect the swap within about a minute. Three things race to trigger it and
whichever wins produces the same result: the 30-second timer sees the container
is not `Running`, the activity log alert fires on the stop operation, and
`UnhealthyHostCount` crosses its threshold once the gateway notices.

Fail back:

```powershell
./scripts/dr-drill.ps1 restore
```

This starts the container and then **waits for the watchdog** to move DNS rather
than setting the record itself, which is the honest test of the failback rule.
Failback needs the container to report `Running` *and* the gateway's backends to
be healthy again, so it takes a little longer than the failover did.

---

## 11. Optional: test from inside the VNet

The gateways have no public frontend, so you cannot reach them from your
workstation.

```hcl
deploy_test_vm         = true
test_vm_ssh_public_key = "ssh-rsa AAAA..."
```

```powershell
terraform apply
ssh azureuser@(terraform output -raw test_vm_public_ip)
```

From the VM:

```bash
dig +short app.internal.contoso.com   # the currently active gateway
curl -s http://app.internal.contoso.com/ | head -5
curl -s http://10.1.1.10/ | head -5   # primary gateway directly
curl -s http://10.2.1.10/ | head -5   # secondary, over the peering
```

All three should return the container's HTML. If the FQDN resolves but the direct
IPs do not, suspect the gateway; if nothing resolves, suspect the private DNS
zone VNet link.

---

## 12. Troubleshooting

**Gateway creation fails mentioning a required public IP or network isolation.**
The preview feature is not registered. Re-run step 3, wait for `Registered`, and
apply again.

**`AuthorizationFailed` on `azurerm_role_definition.watchdog` or any role
assignment.** You lack `Microsoft.Authorization/roleDefinitions/write` or
`roleAssignments/write`. Get User Access Administrator or Owner and re-apply;
the apply is resumable and everything before this point is already in state.

**`az functionapp function list` returns nothing.** The remote build did not
install the dependencies, so the module never imported and no triggers were
indexed. Check the publish output, confirm `SCM_DO_BUILD_DURING_DEPLOYMENT` and
`ENABLE_ORYX_BUILD` are `true` and `WEBSITE_RUN_FROM_PACKAGE` is absent, then
re-publish:

```powershell
az functionapp deployment source config-zip -g rg-appgw-dr-shared `
  -n $fn --src .artifacts/watchdog.zip --build-remote true
az functionapp restart -g rg-appgw-dr-shared -n $fn
```

**The watchdog logs `ManagedIdentityCredential` or authorization errors on its
first few ticks.** Role assignments take up to a few minutes to propagate. It
self-heals; if it persists past five minutes, verify the assignments as in step 9
and restart the app.

**The Function App will not start and complains about storage.** The three
storage data-plane roles had not propagated when the host first started. Restart
the app; it does not need re-deploying.

**Container group creation fails pulling the image.** A container group with a
private IP has no outbound path of its own; the NAT gateway provides one. The
module declares that dependency explicitly, so check that the NAT public IP is
`Succeeded` and the subnet association exists.

**DNS never fails over.** Work through it in order: confirm both triggers are
indexed (step 9), check `AppTraces` for what the watchdog decided, confirm the
role assignments exist, then call the webhook directly with
`./scripts/dr-drill.ps1 webhook` to see the decision synchronously. If the
webhook reports `primary_up: true` while the container is stopped, the identity
cannot read container state.

**The action group webhook returns 401.** The host key changed, which happens if
the app is recreated. Re-apply so the `azurerm_function_app_host_keys` data
source is re-read and the action group is rewritten.

**A plan after failover wants to change the DNS record.** It should not.
`azurerm_private_dns_a_record.app` carries `ignore_changes = [records]` precisely
so Terraform does not drag traffic back to a dead region.

**Dashboard charts are empty.** Metrics reach the workspace on a few minutes'
delay, and the workbook queries the workspace rather than the metrics API. Wait,
then confirm the diagnostic settings exist on both gateways.

---

## 13. Teardown

```powershell
terraform destroy
```

Deleting the two gateways takes the longest. The custom role definition is
subscription-scoped and is removed with everything else.

To abandon state and delete the infrastructure at once:

```powershell
az group delete -n rg-appgw-dr-eus --yes --no-wait
az group delete -n rg-appgw-dr-cus --yes --no-wait
az group delete -n rg-appgw-dr-shared --yes --no-wait
```

Note that deleting the groups leaves the custom role definition behind, since it
lives at subscription scope. Remove it with
`az role definition delete --name "Private AppGW DR Watchdog (<suffix>)"`.

Registered providers and the preview feature are subscription-level and survive
teardown, so you do not need to repeat step 3 for a rebuild.
