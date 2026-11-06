# automated-android-vm-for-proxmox

One command on a Proxmox VE node and you get a working Android VM (Bliss OS / Android-x86), viewable straight from the Proxmox web console — no extra client, no SPICE setup.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/automated-android-vm-for-proxmox/main/install.sh)"
```

> The `bash -c "$(curl ...)"` form is deliberate — `curl | bash` eats stdin and the wizard's prompts stop working.

## What it builds

| | |
|---|---|
| Machine | q35 + OVMF (UEFI), Secure Boot keys not pre-enrolled |
| Disk | SATA (`sata0`) — widest driver support in Android-x86 kernels |
| Display | VirGL (`virtio-gl`) by default, falls back to `std` |
| NIC | `e1000` (shows up as "VirtWifi" inside Android) |
| CPU | `host`, balloon disabled (Android has no balloon driver) |
| Boot | `order=sata0;ide2` — empty disk falls through to the ISO, then boots itself once installed |
| Extras | virtio-rng for entropy, absolute-pointer tablet so the mouse tracks 1:1 in noVNC |

The wizard picks the next free VMID, lists your actual storages and bridges, installs `libgl1`/`libegl1` if you choose VirGL, and cleans up the half-built VM if anything fails partway.

## Options

Everything is promptable or flaggable, so it works unattended too:

```bash
./install.sh -y --vmid 150 --name android-test \
  --cores 6 --memory 8192 --disk 64 \
  --storage game_storage --iso-store local \
  --bridge vmbr0 --vga virtio-gl --start
```

`--help` lists the rest (`--iso-volid`, `--iso-url`, `--vlan`, `--nic`, `--cpu`, `--no-onboot`).

## About the ISO

Bliss OS **paused official public image releases** while they rebuild their tree. The archived 16.9 builds (Android 13) on SourceForge still download but get no updates and no support, and they won't OTA to whatever ships next.

So the script treats the ISO as an input, with no default URL:

1. If an ISO is already on your ISO storage, it offers it.
2. Otherwise it asks for a direct `.iso` URL (or take `--iso-url`) — any Android-x86 style image works.
3. Already uploaded through the UI? `--iso-volid local:iso/Bliss-v16.9.7-x86_64-OFFICIAL-gapps.iso`

**Which build to pick.** Bliss encodes this in the filename, and the wrong choice silently breaks app support:

| In the filename | Means |
|---|---|
| `gapps` | Google Play Services included — what you want for mainstream apps |
| `foss` | No Play Services; anything needing GMS fails |
| `houdini` / `libndk` | ARM translation layer, required for ARM-only apps (most of the Play Store). Neither keyword means no bridge |
| `Surface` | linux-surface kernel for Surface tablets — not what you want in a VM |
| `x86_64-v2` / `-v3` | v3 needs AVX2; v2 is the safer choice |

Aim for an **x86_64-v2 GApps 16.9.x** build. The script warns about each of these before it builds the VM. There's deliberately no default download URL, because SourceForge's "latest" link resolves to a Surface FOSS build that fails on all three counts.

Downloads are size- and ISO-9660-verified, so a mirror error page can't silently become your boot media.

## Finishing the install

Android-x86 images have no unattended answer file, so one pass through the installer is unavoidable — but it's fast:

1. Open the console. At GRUB choose **Auto Install to specified harddisk** and point it at the SATA disk. Blank disk, so it wipes and installs with no further input.
2. Reboot. Disk-first boot order means it comes straight up in Android.
3. Finish Android's setup wizard. Connect to **VirtWifi** for network.

Manual route instead of auto-install: `D` detect devices → `C` create partitions → GPT **Yes** → new primary, full size → write → quit → format ext4 → install **GRUB2 EFI** → `/system` writable **Yes**.

## Afterwards

```bash
qm set 150 --ide2 none,media=cdrom     # detach the ISO
qm resize 150 sata0 +16G               # grow the disk
qm stop 150 && qm destroy 150 --purge  # remove it
```

**ADB over the network:** Settings → About → tap Build number 7× → Developer options → Wireless debugging, then `adb connect <vm-ip>:5555`. `scrcpy` works over that too if you want a smoother screen than noVNC.

**Black screen on boot:** press `e` at GRUB and add `nomodeset` to the kernel line, or rebuild with `--vga std`. On a node with no GPU, VirGL falls back to software rendering — correct, just slow.

**Audio** doesn't pass through noVNC. It needs a SPICE display plus `virt-viewer`, and it's flaky on Android-x86; left out on purpose.

## License

MIT
