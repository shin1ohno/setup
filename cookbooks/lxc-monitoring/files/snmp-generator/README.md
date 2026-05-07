# snmp-generator

Inputs to regenerate `cookbooks/lxc-monitoring/files/snmp.yml.tmpl` for the
RTX `snmp-exporter` scrape jobs.

## Regenerate

```
cd cookbooks/lxc-monitoring/files/snmp-generator/
make snmp.yml
```

This downloads `prom/snmp-generator:v0.26.0`, parses YAMAHA-RT MIBs from
`mibs/`, generates `snmp.yml`, replaces the community line with
`@@RTX_SNMP_COMMUNITY@@`, and copies the result to `../snmp.yml.tmpl`.
The mitamae cookbook reads the SSM-fetched community at deploy time and
substitutes the placeholder.

## Why a template, not a runtime env var?

`snmp_exporter` does not expand environment variables in its YAML config.
The community string is therefore baked into the file at deploy time via
`sed` substitution. The placeholder pattern keeps the committed artifact
free of secrets.

## MIB sources

All MIBs are downloaded from <https://www.rtpro.yamaha.co.jp/RT/docs/mib/>.
License: Yamaha Corporation (free redistribution permitted for monitoring).

| File | Module | Provides |
|------|--------|----------|
| `mibs/yamaha-smi.mib` | YAMAHA-SMI | Root OID for YAMAHA private MIBs |
| `mibs/yamaha-rt.mib` | YAMAHA-RT | Sub-OIDs (Hardware, Firmware, Interfaces, IP, Switch) |
| `mibs/yamaha-rt-hardware.mib` | YAMAHA-RT-HARDWARE | `yrhCpuUtil*`, `yrhMemoryUtil`, `yrhInboxTemperature` |
| `mibs/yamaha-rt-firmware.mib` | YAMAHA-RT-FIRMWARE | `yrfRevision`, `yrfFirmwareFile`, `yrfUpTime` |
| `mibs/yamaha-rt-interfaces.mib` | YAMAHA-RT-INTERFACES | (referenced for OID resolution; not currently walked) |
| `mibs/yamaha-rt-ip.mib` | YAMAHA-RT-IP | (referenced for OID resolution; not currently walked) |

## Re-downloading MIBs

If a MIB version bumps upstream (Yamaha publishes new RTX firmware features),
re-fetch the four-or-more files directly:

```
cd mibs/
for m in yamaha-smi yamaha-rt yamaha-rt-hardware yamaha-rt-firmware \
         yamaha-rt-interfaces yamaha-rt-ip; do
  curl -fsSL -o $m.mib https://www.rtpro.yamaha.co.jp/RT/docs/mib/$m.mib.txt
done
```

Then `make snmp.yml` to regenerate.
