// Private DNS zone, VNet links, and the failover A record. Mirrors terraform/dns.tf.
//
// Terraform ignores later changes to the A record so a failover is not undone
// on the next plan. Bicep has no ignore_changes. seedDnsRecord creates the
// record on the first deployment. Set it to false before a later deployment
// if the watchdog has already moved the record.
targetScope = 'resourceGroup'

param location string = 'global'
param tags object
param privateDnsZoneName string
param dnsRecordName string
param dnsRecordTtl int
param primaryVnetId string
param secondaryVnetId string
param primaryAppgwPrivateIp string
param seedDnsRecord bool

resource zone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: location
  tags: tags
}

resource linkPrimary 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: zone
  name: 'link-eus'
  location: location
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: primaryVnetId
    }
  }
}

resource linkSecondary 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: zone
  name: 'link-cus'
  location: location
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: secondaryVnetId
    }
  }
}

resource record 'Microsoft.Network/privateDnsZones/A@2020-06-01' = if (seedDnsRecord) {
  parent: zone
  name: dnsRecordName
  properties: {
    ttl: dnsRecordTtl
    aRecords: [
      {
        ipv4Address: primaryAppgwPrivateIp
      }
    ]
  }
}

output zoneName string = zone.name
output zoneId string = zone.id
