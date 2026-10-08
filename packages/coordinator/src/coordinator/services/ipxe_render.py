from jinja2 import Template

WIPE_TEMPLATE = Template("""#!ipxe
echo
echo ========================================================================
echo  STORAGE WIPE | SANITIZING LOCAL STORAGE ({{ name }})
echo ========================================================================
echo   MAC Address : {{ mac }}
echo   Target Host : {{ name }}
echo   Coordinator : {{ server_ip }}:{{ port }}
echo   Action      : BOOTING INTO INSPECTOR RAMDISK TO WIPE LOCAL DISKS
echo ========================================================================
echo
sleep 3
set cmdline coordinator.server=http://{{ server_ip }}:{{ port }} inspector.server=http://{{ server_ip }}:{{ port }} inspector.wipe=1
chain http://{{ server_ip }}/default/netboot.ipxe
""")

DISCOVER_TEMPLATE = Template("""#!ipxe
echo
echo ========================================================================
echo  AI VILLAGE HARDWARE INSPECTOR | STATELESS DISCOVERY ({{ name }})
echo ========================================================================
echo   MAC Address : {{ mac }}
echo   Status      : UNREGISTERED / HARDWARE DISCOVERY
echo   Coordinator : {{ server_ip }}:{{ port }}
echo   Action      : BOOTING INTO INSPECTOR RAMDISK TO REPORT HARDWARE
echo ========================================================================
echo
sleep 2
set cmdline coordinator.server=http://{{ server_ip }}:{{ port }} inspector.server=http://{{ server_ip }}:{{ port }}
chain http://{{ server_ip }}/default/netboot.ipxe
""")

TALOS_TEMPLATE = Template("""#!ipxe
echo
echo ========================================================================
echo  TALOS OS | BARE-METAL KUBERNETES INSTALL ({{ name }})
echo ========================================================================
echo   Role        : {{ role_desc }}
echo   MAC Address : {{ mac }}
echo   RAMDisk     : {{ ramdisk_desc }}
echo   Config URI  : {{ config_url }}
echo ========================================================================
echo
sleep 1
:boot_loop
kernel http://{{ server_ip }}/{{ name }}/vmlinuz talos.config={{ config_url }} talos.platform=metal console=tty0 init_on_alloc=1 slab_nomerge pti=on consoleblank=0 nvme_core.io_timeout=4294967295 printk.devkmsg=on selinux=1 module.sig_enforce=1 || goto boot_retry
initrd http://{{ server_ip }}/{{ name }}/initrd || goto boot_retry
boot || goto boot_retry

:boot_retry
echo Network transfer interrupted. Retrying in 2 seconds...
sleep 2
goto boot_loop
""")


def render_wipe_script(name: str, mac: str, server_ip: str, port: int) -> str:
    """Renders iPXE boot script for Inspector Wipe mode."""
    return WIPE_TEMPLATE.render(name=name, mac=mac, server_ip=server_ip, port=port)


def render_discover_script(name: str, mac: str, server_ip: str, port: int) -> str:
    """Renders iPXE boot script for Inspector Discover mode."""
    return DISCOVER_TEMPLATE.render(name=name, mac=mac, server_ip=server_ip, port=port)


def render_talos_script(
    name: str,
    mac: str,
    server_ip: str,
    port: int,
    is_control_plane: bool,
    is_nvidia: bool,
    config_url: str,
) -> str:
    """Renders iPXE boot script for Talos OS install/boot."""
    node_role = "CONTROL PLANE" if is_control_plane else "WORKER"
    role_desc = f"{node_role} (nvidia = true)" if is_nvidia else node_role
    ramdisk_desc = (
        "TALOS OS + NVIDIA GPU DRIVERS (506 MB)"
        if is_nvidia
        else "TALOS OS KERNEL & INITRAMFS (103 MB)"
    )
    return TALOS_TEMPLATE.render(
        name=name,
        mac=mac,
        server_ip=server_ip,
        port=port,
        role_desc=role_desc,
        ramdisk_desc=ramdisk_desc,
        config_url=config_url,
    )
