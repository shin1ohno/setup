# snmp_exporter generator Makefile.
# Run `make snmp.yml` to regenerate the snmp.yml.tmpl from YAMAHA MIBs.
# This is a developer-only build step — the generated snmp.yml.tmpl is
# committed to the repository as the deployable artifact.

GENERATOR_IMG := prom/snmp-generator:v0.26.0

.PHONY: snmp.yml clean

snmp.yml:
	docker run --rm -v $(CURDIR):/work -w /work $(GENERATOR_IMG) generate \
		-m /work/mibs \
		-g /work/generator.yml \
		-o /work/snmp.yml
	sed -i 's/community: .*/community: "@@RTX_SNMP_COMMUNITY@@"/' snmp.yml
	cp snmp.yml ../snmp.yml.tmpl
	rm snmp.yml

clean:
	rm -f snmp.yml ../snmp.yml.tmpl
