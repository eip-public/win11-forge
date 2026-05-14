#!/usr/bin/env python3
# Rewrite the first <devices><disk device='disk'> source file in a libvirt
# domain XML.
#
#   usage: set-disk-source.py <xml-path> <disk-path>
#
# Edits xml-path in place. Used by setup.sh's cmd_reset (swap working
# overlay) and seal-vm-gold.sh's set_vm_disk_source (point at flattened
# gold + restore-verify overlay).
import sys
import xml.etree.ElementTree as ET

xml_path, disk_path = sys.argv[1], sys.argv[2]
tree = ET.parse(xml_path)
root = tree.getroot()

for disk in root.findall("./devices/disk"):
    if disk.get("device") != "disk":
        continue
    source = disk.find("source")
    if source is None:
        raise SystemExit("primary disk source not found")
    source.set("file", disk_path)
    break
else:
    raise SystemExit("primary disk not found")

tree.write(xml_path, encoding="unicode")
