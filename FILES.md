# File reference

Every file in this stack, what it does, and when you would edit it. For
deployment steps see [DEPLOYMENT.md](DEPLOYMENT.md).

## Contents

- [Layout at a glance](#layout-at-a-glance)
- [Root configuration](#root-configuration)
  - [versions.tf](#versionstf)
  - [variables.tf](#variablestf)
  - [main.tf](#maintf)
  - [dns.tf](#dnstf)
  - [function_app.tf](#function_apptf)
  - [rbac.tf](#rbactf)
  - [monitoring.tf](#monitoringtf)
  - [test_vm.tf](#test_vmtf)
  - [outputs.tf](#outputstf)
- [The regional module](#the-regional-module)
  - [modules/region/variables.tf](#modulesregionvariablestf)
  - [modules/region/main.tf](#modulesregionmaintf)
  - [modules/region/outputs.tf](#modulesregionoutputstf)
- [The watchdog function](#the-watchdog-function)
  - [function/function_app.py](#functionfunction_apppy)
  - [function/host.json](#functionhostjson)
  - [function/requirements.txt](#functionrequirementstxt)
- [Scripts](#scripts)
  - [scripts/register-prereqs.ps1 and .sh](#scriptsregister-prereqsps1-and-sh)
  - [scripts/dr-drill.ps1 and .sh](#scriptsdr-drillps1-and-sh)
- [Configuration and documentation](#configuration-and-documentation)
- [Generated paths](#generated-paths)
- [Files outside this directory](#files-outside-this-directory)
- [Appendix: variable reference](#appendix-variable-reference)
- [Appendix: output reference](#appendix-output-reference)
- [Appendix: resource inventory](#appendix-resource-inventory)

---

## Layout at a glance

```
terraform/
├── versions.tf                  Provider requirements and provider config
├── variables.tf                 Every input, with working defaults
├── main.tf                      Three resource groups, both regions, peering, client subnet
├── dns.tf                       Private DNS zone, VNet links, failover A record
├── function_app.tf              Storage, B1 plan, watchdog app, code publish
├── rbac.tf                      Custom watchdog role and every role assignment
├── monitoring.tf                Workspace, App Insights, action group, alerts, dashboard
├── test_vm.tf                   Optional in-VNet client, gated on deploy_test_vm
├── outputs.tf                   Verification surface
├── terraform.tfvars.example     Copy to terraform.tfvars
├── .gitignore                   Keeps state, secrets, and build artifacts out of git
├── README.md                    Overview, topology, and design notes
├── DEPLOYMENT.md                Step-by-step deployment guide
├── FILES.md                     This file
├── modules/region/              One region's worth of infrastructure, called twice
├── function/                    Python watchdog: timer plus HTTP webhook
└── scripts/                     Subscription prerequisites and the drill
```

Two organizing ideas. Everything that exists once per region lives in
`modules/region`; everything that exists once for the whole stack lives at the
root. And the root splits along resource group lines: regional resources go into
the two regional groups so a region can be destroyed on its own, while DNS, the
watchdog, and monitoring go into a shared group that survives losing either
region.

---

## Root configuration

### versions.tf

Pins `azurerm` to 5.x, plus `random` for the name suffix and dashboard UUID, and
`archive` for zipping the function source. The Terraform 1.9 floor is
conservative; the newest feature actually used is the built-in `terraform_data`
resource, which landed in 1.4.

The provider block reads `subscription_id` from the variable of the same name,
which defaults to `null` so it falls back to `ARM_SUBSCRIPTION_ID`.

**Edit when:** you move to a remote backend, or bump the provider.

### variables.tf

All 38 inputs with working defaults, so an empty `terraform.tfvars` is valid.
Grouped into resource groups, addressing, workload, DNS, watchdog, monitoring, and
the optional test client. See the [variable reference](#appendix-variable-reference).

**Edit when:** you need a new knob, or want to change a default for your
environment rather than overriding it in every tfvars file.

### main.tf

The composition root. In order:

- `data.azurerm_client_config`, `data.azurerm_subscription`, and
  `random_string.suffix`, which supplies the 8-character suffix for globally
  unique names.
- The three resource groups: `primary`, `secondary`, and `shared`.
- Two calls to `./modules/region`. This is where the region-specific names
  (`vnet-eus-dr` versus `vnet-cus-dr`) and the regional resource group are
  supplied.
- `azurerm_virtual_network_peering` in both directions. Note that the watchdog
  does *not* depend on peering — it reads state from ARM rather than probing the
  private frontends. Peering is there so one test VM can reach both gateways.
- `azurerm_subnet.client` for the optional test VM.

**Edit when:** you add a region, or need another subnet.

### dns.tf

The private DNS zone in the shared group, a VNet link per region with
autoregistration off, and the `app` A record.

The record is the failover mechanism: clients only ever resolve
`app.internal.contoso.com`, so repointing it moves traffic. Terraform seeds it at
the primary gateway and hands ownership to the watchdog, which is why it carries
`ignore_changes = [records]`. Without that, the first plan after a failover would
propose dragging traffic back to the dead region.

**Edit when:** you change the zone or record name, or add records.

### function_app.tf

The watchdog and its hosting:

- `azurerm_storage_account`, with no key ever read into the Function App config.
- `azurerm_service_plan` on `B1`. Basic is the smallest tier that supports Always
  On, and Always On is what keeps the 30-second timer warm on a dedicated plan.
- `azurerm_linux_function_app` with Python 3.11, a system-assigned identity, and
  `storage_uses_managed_identity = true` so even `AzureWebJobsStorage` is
  keyless. There is no VNet integration, because the watchdog only talks to ARM.
- `app_settings` carrying both build flags and every identifier the watchdog
  reads. `WEBSITE_RUN_FROM_PACKAGE` is deliberately absent, and because Terraform
  owns the whole map it will remove the setting if anything adds it.
- `data.archive_file.watchdog` and `terraform_data.publish_watchdog`, which
  publishes via `az functionapp deployment source config-zip --build-remote true`.
  The remote build is the point: a prebuilt package leaves `azure-identity`
  uninstalled, the module never imports, and no triggers get indexed. The
  provisioner depends on all five role assignments so the first tick has the
  access it needs.
- `data.azurerm_function_app_host_keys`, deferred until the app exists, used to
  build the action group's webhook URL.

**Edit when:** you change the plan size, the runtime, or the settings the
watchdog reads.

### rbac.tf

Everything the watchdog is allowed to do, and nothing else. Five assignments on
one principal:

- `azurerm_role_definition.watchdog`, a custom role with exactly three
  operations: read container groups, read Application Gateways, and call
  `backendhealth`. Reader covers the two reads but not `backendhealth`, which is
  a POST action; Network Contributor covers it but grants far too much. Hence the
  purpose-built role.
- Two assignments of that role, one per regional resource group.
- `Private DNS Zone Contributor` on the single zone. This is the watchdog's only
  write permission anywhere.
- Three storage data-plane roles, which are what make keyless
  `AzureWebJobsStorage` work.

**Edit when:** the watchdog needs to read something new. Prefer extending the
custom role over reaching for a built-in one.

### monitoring.tf

The dashboard, the action group, and the alerts:

- `azurerm_log_analytics_workspace` and a workspace-based
  `azurerm_application_insights`, so gateway metrics and watchdog traces land in
  one place the dashboard can query together.
- `azurerm_monitor_action_group.failover`, with a webhook receiver pointing at
  `/api/region-failover` and an optional email receiver. The URL carries the host
  key, so the endpoint is not anonymous.
- `azurerm_monitor_metric_alert.unhealthy_hosts`, one per gateway:
  `UnhealthyHostCount >= 1` over a one-minute window. Each gateway has a single
  backend member, so one unhealthy host means that region serves nothing.
- `azurerm_monitor_activity_log_alert.container_stopped`, scoped to both regional
  groups, firing on `containerGroups/stop/action`. The activity log surfaces a
  stopped container faster than any metric can.
- `azurerm_monitor_scheduled_query_rules_alert_v2.watchdog_failing`, which alerts
  on unhandled exceptions in the watchdog. A watchdog that throws every tick
  cannot fail anything over and nothing else would notice, and an exception is
  exactly how a missing dependency shows up.
- `azurerm_application_insights_workbook.dashboard`, built with `jsonencode` so
  the JSON is valid by construction. Five panels: a header, current host counts,
  healthy hosts over time, unhealthy hosts over time, and the watchdog's own
  decisions.

The workbook queries the workspace rather than the metrics API, which costs a few
minutes of ingestion lag but puts metrics, gateway access logs, and function
traces on one page. The failover path does not depend on that pipeline.

**Edit when:** you add panels, change thresholds, or add receivers.

### test_vm.tf

A public IP, NIC, and Ubuntu 24.04 VM in the primary VNet's client subnet, gated
on `count = var.deploy_test_vm ? 1 : 0` and off by default because of core quota.

It exists because the gateways have no public frontend, so this is the only way to
curl them. A `lifecycle.precondition` fails the plan with a clear message if you
enable the VM without supplying `test_vm_ssh_public_key`.

### outputs.tf

The verification surface. `primary_appgw` and `secondary_appgw` bundle each
region's resource group, gateway name, private IP, and backend container name and
IP, so one output answers "is the gateway private and pointed at the right
backend". `watchdog` includes the identity's `principal_id` for auditing role
assignments, and `monitoring` lists everything in the monitoring layer.
`failover_webhook_uri` is marked sensitive because it embeds a host key.

---

## The regional module

Called twice from `main.tf`. Everything in it exists once per region, which is why
it takes names and a resource group as inputs rather than deriving them.

### modules/region/variables.tf

Twenty-one inputs: resource group and location, VNet and subnet names and
prefixes, NAT gateway names, container settings, gateway settings, and the shared
workspace ID for diagnostics. No defaults on the naming inputs, deliberately, so
the caller must be explicit about which region it is building.

### modules/region/main.tf

The substance of the stack:

- `azurerm_virtual_network`.
- `azurerm_subnet.appgw`, delegated to `Microsoft.Network/applicationGateways`.
  That delegation is part of what permits a gateway with no public frontend.
- `azurerm_subnet.aci`, delegated to `Microsoft.ContainerInstance/containerGroups`.
- `azurerm_public_ip.nat`, `azurerm_nat_gateway`, and both associations. A
  container group with `ip_address_type = "Private"` has no outbound path of its
  own, so this is what lets it pull its image.
- `azurerm_container_group`, with an explicit `depends_on` covering both NAT
  associations. Without that ordering the image pull races the outbound path.
- `azurerm_application_gateway`. The important part is the
  `frontend_ip_configuration`: a static private address, a subnet, and **no**
  `public_ip_address_id`. The custom probe sends an explicit `host = "127.0.0.1"`
  header because the backend pool holds bare IPs with no FQDN to derive one from,
  and matches `200-399`. Timeouts are raised to 60 minutes since v2 gateways
  routinely take 10 to 20.
- `azurerm_monitor_diagnostic_setting`, feeding metrics and access logs to the
  shared workspace for the dashboard.

**Edit when:** you change listeners, routing, or probe behavior, or swap the
backend for something other than a container group. Changes here apply to both
regions at once, which is the point.

### modules/region/outputs.tf

Eight outputs: the VNet's ID and name (consumed by peering, DNS links, and the
client subnet), the gateway's name, ID, and private frontend IP, and the container
group's name, ID, and private IP. The container's private IP is read back from the
resource rather than assumed, because Azure assigns it at creation.

---

## The watchdog function

A Python v2 programming model app: two triggers, one decision function.

### function/function_app.py

Reads configuration from app settings at import time, authenticates with
`ManagedIdentityCredential`, and exposes:

- `watchdog`, a timer on `%WATCHDOG_SCHEDULE%` (every 30 seconds), and
- `region_failover`, an HTTP POST endpoint at `/api/region-failover` with
  function-level auth, which the action group calls.

Both call `evaluate()`, which reads live state from ARM: container group state
first, then the gateway's `backendhealth`. A container that is not `Running` is
treated as down immediately with no grace period. Failing back to the primary
requires the primary to be genuinely up *now* — that is the rule that stops a
lagging `HealthyHostCount` sample from returning traffic to a dead region. If
neither region is up it logs at critical severity and changes nothing, on the
reasoning that repointing at a second dead region buys nothing and hides the
outage.

The webhook logs the alert payload but does not trust it; it re-evaluates and
reaches the same decision the timer would. That makes a spurious or stale alert
harmless and repeated calls idempotent.

`point_dns_at` reads the current record first and returns early when it already
matches, so steady-state ticks perform no writes.

**Edit when:** you want different health semantics — weighted probes, a
consecutive-failure threshold before flipping, or a manual override switch.

### function/host.json

Runtime configuration: schema version 2.0, extension bundle 4.x (which supplies
the timer and HTTP triggers), and Application Insights sampling with `Request`
excluded.

### function/requirements.txt

`azure-functions`, `azure-identity`, `azure-mgmt-containerinstance`,
`azure-mgmt-network`, and `azure-mgmt-privatedns`. These are installed by the
Oryx build on the platform, which is the whole reason the code is published
through the CLI rather than the provider. If this restore fails, the app imports
nothing and no triggers are indexed.

---

## Scripts

Both come in a PowerShell and a Bash version with identical behavior, so the stack
works from a Windows workstation or Azure Cloud Shell.

### scripts/register-prereqs.ps1 and .sh

Run once per subscription, before the first apply. Registers seven resource
providers, requests the `EnableApplicationGatewayNetworkIsolation` preview
feature, polls until it reports `Registered`, then re-registers
`Microsoft.Network` to propagate it. Exits non-zero on a 15-minute timeout.

This is a script rather than Terraform because provider and feature registration
are subscription-wide, one-time, and effectively irreversible — a poor fit for
resources Terraform expects to own and destroy.

### scripts/dr-drill.ps1 and .sh

Four actions, reading the Terraform outputs so they need no configuration of
their own:

| Action | What it does |
| --- | --- |
| `validate` | Resource groups, container and gateway state, backend health, DNS target, alert status, and which triggers the watchdog indexed |
| `failover` | Stops the primary container and polls until DNS moves to the secondary |
| `restore` | Starts both containers and waits for the *watchdog* to fail back, rather than setting the record itself |
| `webhook` | Posts a synthetic common-alert-schema payload and prints the decision |

`restore` waiting for the watchdog is deliberate: setting the record directly
would skip the failback rule, which is the part most worth testing.

The Bash version needs `jq`. The PowerShell version needs nothing beyond the
Azure CLI.

---

## Configuration and documentation

| File | Purpose |
| --- | --- |
| `terraform.tfvars.example` | Annotated starting point. Copy to `terraform.tfvars`, which is gitignored. |
| `.gitignore` | Excludes `.terraform/`, state, `terraform.tfvars`, `.artifacts/`, and `__pycache__/`. |
| `README.md` | Overview, topology, failover sequence, and the design decisions worth knowing before reading the code. |
| `DEPLOYMENT.md` | Step-by-step deployment, verification, drill, and troubleshooting. |
| `FILES.md` | This file. |

---

## Generated paths

Not in source control; safe to delete.

| Path | Created by | Contents |
| --- | --- | --- |
| `.terraform/` | `terraform init` | Provider binaries and module cache |
| `.terraform.lock.hcl` | `terraform init` | Provider checksums. Commit this in a shared repo. |
| `.artifacts/watchdog.zip` | `terraform plan` | Zipped function source, rebuilt when the source changes |
| `terraform.tfstate` | `terraform apply` | Local state. Move to a remote backend for shared use. |
| `function/__pycache__/` | Running Python locally | Bytecode cache |

---

## Files outside this directory

| File | Relationship to this stack |
| --- | --- |
| `../Instructions.md` | The original requirement: private-only gateways in East US and Central US, private frontends, ACI private backend pools, passing probes, VNet peering, and a Function App to handle failover. |
| `../Create 3 Separate Resource Group.txt` | The revision this stack currently implements: three resource groups, dashboard and alerts, action group, a B1 Python 3.11 Function App on managed identity, and the ARM-based watchdog with its failback rule. |
| `../deploy_private_appgw_dr_from_scratch.sh` | The original Azure CLI script. Kept for reference; superseded by `terraform apply` and `scripts/dr-drill`. Note that its topology used 10.10/10.20 addressing, a single resource group, and Flex Consumption. |

---

## Appendix: variable reference

### Resource groups and regions

| Variable | Default |
| --- | --- |
| `subscription_id` | `null`, falls back to `ARM_SUBSCRIPTION_ID` |
| `primary_resource_group_name` | `rg-appgw-dr-eus` |
| `secondary_resource_group_name` | `rg-appgw-dr-cus` |
| `shared_resource_group_name` | `rg-appgw-dr-shared` |
| `primary_location` | `eastus` |
| `secondary_location` | `centralus` |
| `shared_location` | `null`, defaults to `primary_location` |
| `tags` | `businessUnit`, `costCenter`, `env`, `owner` |

### Addressing

| Variable | Default |
| --- | --- |
| `primary_vnet_address_space` | `["10.1.0.0/16"]` |
| `secondary_vnet_address_space` | `["10.2.0.0/16"]` |
| `primary_appgw_subnet_prefix` | `10.1.1.0/24` |
| `secondary_appgw_subnet_prefix` | `10.2.1.0/24` |
| `primary_aci_subnet_prefix` | `10.1.2.0/24` |
| `secondary_aci_subnet_prefix` | `10.2.2.0/24` |
| `client_subnet_prefix` | `10.1.10.0/24` |
| `primary_appgw_private_ip` | `10.1.1.10` |
| `secondary_appgw_private_ip` | `10.2.1.10` |

### Workload

| Variable | Default |
| --- | --- |
| `container_image` | `mcr.microsoft.com/azuredocs/aci-helloworld` |
| `container_port` | `80` |
| `container_cpu` | `1` |
| `container_memory_in_gb` | `1` |
| `appgw_capacity` | `1` |
| `health_probe_path` | `/` |

### DNS

| Variable | Default |
| --- | --- |
| `private_dns_zone_name` | `internal.contoso.com` |
| `dns_record_name` | `app` |
| `dns_record_ttl` | `30` |

### Watchdog

| Variable | Default |
| --- | --- |
| `app_service_plan_sku` | `B1`, must support Always On |
| `python_version` | `3.11` |
| `watchdog_schedule` | `*/30 * * * * *` (six fields, so the first is seconds) |
| `backend_healthy_states` | `["Up", "Healthy"]` |
| `deploy_function_code` | `true` |

### Monitoring

| Variable | Default |
| --- | --- |
| `log_retention_in_days` | `30` |
| `alert_email_address` | `""`, webhook only when empty |
| `unhealthy_host_threshold` | `1` |

### Optional test client

| Variable | Default |
| --- | --- |
| `deploy_test_vm` | `false` |
| `test_vm_size` | `Standard_B2s_v2` |
| `test_vm_admin_username` | `azureuser` |
| `test_vm_ssh_public_key` | `""`, required when `deploy_test_vm` is true |

---

## Appendix: output reference

| Output | Type | Use |
| --- | --- | --- |
| `resource_groups` | object | All three group names |
| `primary_appgw` | object | `resource_group`, `name`, `private_ip`, `backend_aci_ip`, `backend_aci_name` |
| `secondary_appgw` | object | Same shape as above |
| `application_fqdn` | string | `app.internal.contoso.com`, the only name clients resolve |
| `watchdog` | object | `name`, `hostname`, `plan_sku`, `principal_id`, `schedule` |
| `monitoring` | object | Workspace, App Insights, action group, dashboard, and alert names |
| `vnet_peering_state` | object | Peering names in both directions |
| `test_vm_public_ip` | string | `null` unless `deploy_test_vm` is true |
| `failover_webhook_uri` | string | Sensitive; embeds the host key |

---

## Appendix: resource inventory

Around 50 resources. `<suffix>` is the random 8-character string.

### Regional groups

| Resource | `rg-appgw-dr-eus` | `rg-appgw-dr-cus` |
| --- | --- | --- |
| Virtual network | `vnet-eus-dr` | `vnet-cus-dr` |
| Gateway subnet | `snet-appgw-eus` | `snet-appgw-cus` |
| Backend subnet | `snet-aci-eus` | `snet-aci-cus` |
| Client subnet | `snet-client` | — |
| Peering | `peer-eus-to-cus` | `peer-cus-to-eus` |
| NAT public IP | `pip-nat-eus` | `pip-nat-cus` |
| NAT gateway | `nat-aci-eus` | `nat-aci-cus` |
| Container group | `aci-eus-dr` | `aci-cus-dr` |
| Application Gateway | `agw-eus-dr` at 10.1.1.10 | `agw-cus-dr` at 10.2.1.10 |
| Diagnostic setting | `to-log-analytics` | `to-log-analytics` |
| Test client (optional) | `pip-vm-test`, `nic-vm-test`, `vm-test` | — |

### Shared group

| Category | Resources |
| --- | --- |
| DNS | `internal.contoso.com`, `link-eus`, `link-cus`, `app` A record |
| Storage | `stagwdr<suffix>` |
| Telemetry | `law-appgw-dr-<suffix>`, `appi-appgw-dr-<suffix>` |
| Watchdog | `plan-appgw-dr-<suffix>` (B1), `func-appgw-dr-<suffix>` |
| Action group | `ag-appgw-dr-failover` |
| Alerts | `alert-unhealthy-hosts-primary`, `alert-unhealthy-hosts-secondary`, `alert-aci-stopped`, `alert-watchdog-exceptions` |
| Dashboard | `Private Application Gateway DR` workbook |

### Subscription scope

| Resource | Notes |
| --- | --- |
| `Private AppGW DR Watchdog (<suffix>)` | Custom role definition. Survives resource group deletion. |
