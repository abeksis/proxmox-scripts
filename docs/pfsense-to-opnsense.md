# Migrating from pfSense to OPNsense

This guide uses a parallel, isolated migration. Keep pfSense running as the production firewall until OPNsense has been installed, configured, and checked.

## Important limitations

OPNsense does not document direct restoration of a pfSense `config.xml` as a supported migration method. The configuration formats, package data, interface identifiers, and feature implementations can differ. Do not upload the complete pfSense backup through the OPNsense restore screen.

A firewall backup can contain passwords, private keys, VPN secrets, and other sensitive data. Store it securely, do not commit it to this repository, and delete temporary copies when the migration is complete.

## 1. Recover from an accidental network conflict

If the OPNsense VM was connected to the production LAN and connectivity was interrupted:

1. Stop the OPNsense VM.
2. Remove its virtual network adapters while it is stopped:

   ```bash
   qm set <VMID> --delete net0
   qm set <VMID> --delete net1
   qm config <VMID> | grep '^net'
   ```

3. Confirm that pfSense is the only active DHCP server and default gateway on the LAN.
4. Renew the DHCP lease on affected clients, or reconnect them to the network.

## 2. Back up and inventory pfSense

From pfSense, create a complete backup under **Diagnostics > Backup & Restore**. Keep an encrypted archival copy. If an unencrypted copy is needed for local inspection, protect it carefully.

Record or export the following items:

- Physical interfaces, VLAN IDs, interface names, MAC addresses, and IP subnets
- WAN type and provider details, including PPPoE or static settings
- DHCP ranges, static mappings, DNS overrides, and NTP settings
- Aliases, firewall rules, outbound NAT, port forwards, and 1:1 NAT
- Users, certificates, certificate authorities, and VPN configuration
- Dynamic DNS, routes, gateways, high availability, and installed packages

Take screenshots of critical pages. Treat the pfSense XML as a reference, not as an OPNsense restore file.

## 3. Install OPNsense in isolation

Run `install-opnsense.sh` and select the default option:

```text
Isolated installation (no network adapters)
```

Complete the installation through the Proxmox console. Detach the ISO and boot from disk using the commands printed by the installer.

For web-interface access during preparation, create a Proxmox bridge that has no physical port and is not connected to the production LAN or WAN. Attach one temporary VirtIO adapter to that bridge. Never use the live LAN bridge for this temporary interface.

## 4. Recreate the configuration in stages

Recreate and verify the configuration in this order:

1. System settings, DNS, NTP, users, certificate authorities, and certificates
2. VLAN definitions and the planned interface mapping
3. Aliases
4. DHCP scopes and static mappings
5. Gateways, routes, NAT, and port forwards
6. Firewall rules, starting with the minimum required access
7. VPNs, dynamic DNS, and optional plugins

Do not assume pfSense package settings are portable. Install the corresponding OPNsense plugins only when needed and configure them using OPNsense documentation.

## 5. Plan the production cutover

Before the maintenance window:

- Back up both firewalls.
- Confirm which Proxmox bridge or passed-through NIC is WAN and which is LAN.
- Confirm the intended VirtIO order. If created in this order, use `net0`/`vtnet0` for LAN and `net1`/`vtnet1` for WAN.
- Prepare a rollback plan and retain console access to Proxmox.

During the cutover:

1. Shut down pfSense so that two DHCP servers or duplicate gateway addresses cannot coexist.
2. Keep OPNsense powered off while attaching its production LAN and WAN adapters.
3. Start OPNsense and assign interfaces from its console before enabling services.
4. Verify LAN access, DHCP, DNS, outbound internet, NAT, firewall rules, and VPNs.
5. If critical checks fail, shut down OPNsense, disconnect its production adapters, and restart pfSense.

Do not run pfSense and OPNsense simultaneously on the same production LAN when both use the same gateway address or provide DHCP.
