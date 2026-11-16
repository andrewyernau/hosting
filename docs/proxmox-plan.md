# Proxmox — plan aplazado

> Estado: aplazado. El MVP vuelve a Ubuntu bare metal para evitar una migración
> completa antes de tener el primer servidor de juego. Este documento se
> conserva como referencia para una futura transición planificada; no ejecutar
> su plan de migración ahora.

# Arquitectura Proxmox de la primera máquina

Esta es la arquitectura elegida antes de instalar Pelican o Wings. Proxmox VE
ocupará el bare metal y no alojará cargas de aplicación directamente. El cambio
requiere reinstalar el NVMe actual: no se inicia hasta tener backup externo
verificado y acceso físico a la máquina.

## Distribución inicial

| ID | Rol | Tipo | vCPU | RAM | Disco | Exposición |
|---:|---|---|---:|---:|---:|---|
| 100 | Edge | VM KVM Ubuntu | 1 | 1 GiB | 16 GiB | 80/443 desde Internet |
| 110 | Control | VM KVM Ubuntu | 2 | 4 GiB | 48 GiB | Solo Edge y administración |
| 120 | Game node 01 | VM KVM Ubuntu | 6 | 18 GiB | 32 + 240 GiB | puertos de juego; Wings restringido |
| 130 | Apps privadas | VM KVM Ubuntu | 2 | 4 GiB | 80 GiB | Solo Edge y administración |

La RAM no se sobreasigna: quedan aproximadamente 3 GiB para Proxmox y margen.
Las cuotas de Pelican se calculan sobre un máximo inicial de 15 GiB de RAM en
la VM de juegos, reservando margen para Docker, caché y el sistema operativo.
El segundo disco de la VM 120 se monta en `/srv/pelican`, separando los datos
de juego de la partición raíz. Ningún disco local sustituye el backup externo.

No usar LXC para Wings ni Docker de clientes. Wings tendrá Docker dentro de la
VM KVM 120. Un escape desde un juego tendría que atravesar primero el
contenedor y después la VM, y no obtendría los secretos del Panel ni acceso a
las aplicaciones privadas.

## Red

Usar una única red LAN inicialmente sobre `vmbr0`; las IPs se reservan en DHCP
o se configuran estáticamente fuera del rango dinámico. Direcciones de ejemplo:

```text
Proxmox             192.168.0.111  — 8006 y SSH solo LAN/VPN
vm-100 Edge         192.168.0.120  — NAT router: 80, 443 TCP y 443 UDP
vm-110 Control      192.168.0.121  — no NAT público
vm-120 Game node    192.168.0.122  — NAT: rango TCP/UDP de juegos; SFTP si se habilita
vm-130 Apps          192.168.0.123  — sin NAT directo
```

El router deja de enviar 80/443 al host actual y los envía a `vm-100`. El Edge
envía `panel.yernau.com` al Control y dominios de otras aplicaciones a `vm-130`.
Los puertos de juego se envían directamente a `vm-120`, nunca a Caddy. No se
publica Proxmox (`8006`), SSH de las VMs, MariaDB, ni la API Wings (`8080`).

El firewall se aplica en tres capas: router, firewall de Proxmox/VM y firewall
del sistema invitado. Al inicio no se crean VLANs: se pueden incorporar cuando
el router/switch lo justifique, sin cambiar roles ni rutas de servicio.

## Almacenamiento Proxmox

En este NVMe único, usar LVM-thin/ext4 durante la instalación de Proxmox. No
usar ZFS: no aporta redundancia con un solo disco y consume memoria adicional.
Los snapshots son una ayuda operativa, no una copia de seguridad. Configurar
un destino externo para backup antes de guardar datos de clientes.

## Plan de migración seguro

1. No ejecutar `03-deploy-pelican-panel.sh`; estaba destinado al diseño
   bare-metal y queda archivado como referencia.
2. Inventariar y hacer copia externa verificable de Gambito: compose,
   `.env`, configuraciones Caddy, certificados Origin CA, datos PostgreSQL y
   MinIO, y cualquier volumen Docker. Hacer además copia de llaves SSH y
   configuración de red relevante.
3. Probar restaurar Gambito en una ubicación temporal u otra máquina. Mantener
   fuera de Git las claves privadas de Caddy.
4. Descargar la ISO oficial Proxmox, comprobar su SHA-256 y preparar USB de
   arranque. La instalación borra el NVMe actual; realizarla con acceso físico.
5. Instalar Proxmox, configurar `vmbr0` y asegurar que 8006 solo es accesible
   desde LAN/VPN. Actualizar el sistema y configurar el almacenamiento de
   backups externo.
6. Crear VMs 100, 110, 120 y 130 con discos y firewall descritos arriba;
   instalar Ubuntu LTS actualizado en ellas.
7. Restaurar Gambito primero en VM 130 y cambiar el NAT 80/443 hacia VM 100
   solo tras verificar el proxy. Después desplegar Panel en VM 110 y Wings en
   VM 120.

## Evolución

Cuando llegue una segunda máquina física, se incorpora como otro nodo Wings
(sin necesidad de cluster Proxmox). El Panel en VM 110 registra `node-02` y
los nuevos juegos se asignan allí. Un clúster Proxmox/HA se valora únicamente
cuando haya tres nodos o un qdevice y almacenamiento/backup adecuados.
