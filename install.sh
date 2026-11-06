#!/usr/bin/env bash
# automated-android-vm-for-proxmox — spin up an Android (Bliss OS / Android-x86) VM
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/automated-android-vm-for-proxmox/main/install.sh)"
#
# Run on the Proxmox host as root. Self-contained: no second script to fetch.
# License: MIT

set -euo pipefail

SCRIPT_VERSION="1.1.3"

# ---------------------------------------------------------------- defaults ---
VMID=""
VMNAME="android"
CORES=4
MEMORY=4096
DISK_GB=32
STORAGE=""
ISO_STORE=""
ISO_VOLID=""
ISO_URL=""
BRIDGE="vmbr0"
VLAN=""
NIC_MODEL="e1000"
VGA="virtio-gl"
CPU_TYPE="host"
ONBOOT=1
START_AFTER=0
ASSUME_YES=0

# Bliss OS public images are paused upstream. There is deliberately no default
# URL: SourceForge's "latest" link points at whatever was uploaded last, which
# is a linux-surface FOSS build — no Play Services, no ARM translation layer,
# and a kernel meant for Surface tablets. Pick a build explicitly.
SF_PROJECT="https://sourceforge.net/projects/blissos-x86/files/"
SF_EXAMPLE="${SF_PROJECT}Official/BlissOS16/Gapps/Generic/Bliss-v16.9.7-x86_64-OFFICIAL-gapps-20241011.iso/download"

# ------------------------------------------------------------------- output ---
if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; D=""; N=""
fi
msg()  { echo -e "  ${B}•${N} $*"; }
ok()   { echo -e "  ${G}✔${N} $*"; }
warn() { echo -e "  ${Y}!${N} $*"; }
die()  { echo -e "  ${R}✘${N} $*" >&2; exit 1; }
hdr()  { echo; echo -e "${B}── $* ──${N}"; }

# True only if every named package is fully installed. 'dpkg -s' is not usable
# here: it exits 0 for a package in "config-files" state (removed, not purged),
# whose shared libraries are gone — which is exactly what makes qemu refuse to
# start with "missing libraries for 'virtio-gl'".
have_pkgs() {
  local p
  for p in "$@"; do
    [[ $(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null) == installed ]] || return 1
  done
}

# Bliss encodes a lot in the ISO filename. Flag the choices that quietly break
# mainstream app support, before the VM is built rather than after.
warn_iso_name() {
  local n=${1,,}
  if [[ $n == *foss* ]]; then
    warn "'foss' build: no Google Play Services. Apps needing GMS will fail."
  fi
  if [[ $n != *houdini* && $n != *libndk* ]]; then
    warn "Filename names no ARM translation layer (houdini/libndk). ARM-only"
    warn "apps may not run at all — check after install with: getprop | grep isa"
  fi
  if [[ $n == *surface* ]]; then
    warn "'Surface' build: linux-surface kernel, meant for Surface hardware."
  fi
  if [[ $n == *-v14.* || $n == *-v15.* ]]; then
    warn "Bliss 14/15 are Android 11/12. A 16.9.x build (Android 13) is newer."
  fi
  return 0
}

banner() {
  echo
  echo -e "${B}  ANDROID VM on PROXMOX VE${N}"
  echo -e "${D}  proxmox-android-vm v${SCRIPT_VERSION}${N}"
}

usage() {
  cat <<EOF
Usage: install.sh [options]

  --vmid N             VM ID            (default: next free)
  --name STR           VM name          (default: ${VMNAME})
  --cores N            vCPUs            (default: ${CORES})
  --memory MB          RAM in MB        (default: ${MEMORY})
  --disk GB            Disk in GB       (default: ${DISK_GB})
  --storage NAME       Storage for disk + EFI disk
  --iso-store NAME     Storage holding ISOs (directory-type, e.g. local)
  --iso-volid VOLID    Use an ISO already uploaded, e.g. local:iso/Bliss.iso
  --iso-url URL        Direct .iso URL to download
  --bridge NAME        Network bridge   (default: ${BRIDGE})
  --vlan N             VLAN tag         (default: none)
  --nic MODEL          e1000 | virtio   (default: ${NIC_MODEL})
  --vga TYPE           virtio-gl | std | vmware  (default: ${VGA})
  --cpu TYPE           CPU type         (default: ${CPU_TYPE})
  --no-onboot          Do not start the VM at host boot
  --start              Start the VM when the script finishes
  -y, --yes            Non-interactive; accept defaults, no prompts
  -h, --help           This text

Display notes:
  virtio-gl  VirGL, best desktop feel in the web console. Pulls in libgl1/libegl1
             on the host. Software-rendered if the node has no GPU.
  std        Safest fallback. Add 'nomodeset' to the GRUB line if you get a
             black screen.
  vmware     vmwgfx driver; a good middle ground when VirGL misbehaves.
EOF
}

# -------------------------------------------------------------------- args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)       VMID="$2"; shift 2 ;;
    --name)       VMNAME="$2"; shift 2 ;;
    --cores)      CORES="$2"; shift 2 ;;
    --memory)     MEMORY="$2"; shift 2 ;;
    --disk)       DISK_GB="$2"; shift 2 ;;
    --storage)    STORAGE="$2"; shift 2 ;;
    --iso-store)  ISO_STORE="$2"; shift 2 ;;
    --iso-volid)  ISO_VOLID="$2"; shift 2 ;;
    --iso-url)    ISO_URL="$2"; shift 2 ;;
    --bridge)     BRIDGE="$2"; shift 2 ;;
    --vlan)       VLAN="$2"; shift 2 ;;
    --nic)        NIC_MODEL="$2"; shift 2 ;;
    --vga)        VGA="$2"; shift 2 ;;
    --cpu)        CPU_TYPE="$2"; shift 2 ;;
    --no-onboot)  ONBOOT=0; shift ;;
    --start)      START_AFTER=1; shift ;;
    -y|--yes)     ASSUME_YES=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "Unknown option: $1  (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- prompting ---
ask() { # ask VAR "Prompt" "default"
  local __var=$1 __prompt=$2 __default=$3 __reply
  if (( ASSUME_YES )); then printf -v "$__var" '%s' "$__default"; return; fi
  read -r -p "  ${__prompt} [${__default}]: " __reply </dev/tty || __reply=""
  printf -v "$__var" '%s' "${__reply:-$__default}"
}

confirm() { # confirm "Question" -> 0/1
  (( ASSUME_YES )) && return 0
  local r
  read -r -p "  $1 [y/N]: " r </dev/tty || r=""
  [[ ${r,,} == y* ]]
}

pick() { # pick VAR "Prompt" item1 item2 ...
  local __var=$1 __prompt=$2; shift 2
  local -a items=("$@")
  (( ${#items[@]} == 0 )) && die "Nothing to choose from for: ${__prompt}"
  if (( ${#items[@]} == 1 )) || (( ASSUME_YES )); then
    printf -v "$__var" '%s' "${items[0]}"; return
  fi
  echo "  ${__prompt}"
  local i
  for i in "${!items[@]}"; do printf "    %2d) %s\n" "$((i+1))" "${items[$i]}"; done
  # PICK_NO_DEFAULT=1 forces a deliberate answer, for choices where a reflexive
  # Enter is expensive to undo (picking the wrong Android ISO means reinstalling).
  local sel default_sel="1" hint="[1]"
  if (( ${PICK_NO_DEFAULT:-0} )); then default_sel=""; hint="(1-${#items[@]})"; fi
  while :; do
    # A failed read (no tty, or stdin at EOF) must not spin: with no default
    # there is nothing to fall back to, so stop and say what to do instead.
    read -r -p "  Choice ${hint}: " sel </dev/tty \
      || die "No terminal available to answer that. Re-run with explicit flags (--help)."
    sel="${sel:-$default_sel}"
    [[ $sel =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#items[@]} )) && break
    warn "Enter a number between 1 and ${#items[@]}."
  done
  printf -v "$__var" '%s' "${items[$((sel-1))]}"
}

# --------------------------------------------------------------- preflight ---
banner
hdr "Checks"

[[ $EUID -eq 0 ]] || die "Run this as root on the Proxmox host."
command -v qm   >/dev/null || die "'qm' not found — this does not look like a Proxmox VE node."
command -v pvesm >/dev/null || die "'pvesm' not found — this does not look like a Proxmox VE node."
command -v curl >/dev/null || die "curl is required."
ok "Proxmox VE $(pveversion | head -n1 | sed 's/pve-manager\///;s/ .*//')"

if [[ -e /dev/kvm ]]; then
  ok "KVM acceleration available"
else
  warn "/dev/kvm is missing. Android will be unusably slow (or will not boot)."
  confirm "Continue anyway?" || exit 1
fi

if ! grep -qE '^flags.*(vmx|svm)' /proc/cpuinfo; then
  warn "No vmx/svm CPU flag — hardware virtualisation looks disabled in BIOS."
fi

NODE=$(hostname)

# ----------------------------------------------------------------- vm ident ---
hdr "VM identity"

if [[ -z $VMID ]]; then
  NEXTID=$(pvesh get /cluster/nextid 2>/dev/null || echo 100)
  ask VMID "VM ID" "$NEXTID"
fi
[[ $VMID =~ ^[0-9]+$ ]] || die "VM ID must be a number."
if qm status "$VMID" &>/dev/null || pct status "$VMID" &>/dev/null; then
  die "ID $VMID is already taken by a VM or container."
fi

ask VMNAME "VM name" "$VMNAME"
VMNAME="${VMNAME//[^a-zA-Z0-9-]/-}"
ok "Will create VM ${VMID} (${VMNAME}) on node ${NODE}"

# ------------------------------------------------------------------ storage ---
hdr "Storage"

mapfile -t IMG_STORES < <(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
(( ${#IMG_STORES[@]} )) || die "No active storage that can hold VM disks."
if [[ -n $STORAGE ]]; then
  printf '%s\n' "${IMG_STORES[@]}" | grep -qx "$STORAGE" || die "Storage '$STORAGE' cannot hold VM disks (or is not active)."
else
  pick STORAGE "Storage for the VM disk and EFI disk:" "${IMG_STORES[@]}"
fi
ok "Disk storage: ${STORAGE}"

ask CORES   "vCPU cores" "$CORES"
ask MEMORY  "RAM in MB"  "$MEMORY"
ask DISK_GB "Disk in GB" "$DISK_GB"
for v in CORES MEMORY DISK_GB; do
  [[ ${!v} =~ ^[0-9]+$ ]] || die "$v must be a number."
done
(( MEMORY >= 2048 )) || warn "Under 2 GB of RAM, Android will struggle."

# ---------------------------------------------------------------------- iso ---
hdr "Android ISO"

if [[ -z $ISO_VOLID ]]; then
  mapfile -t ISO_STORES < <(pvesm status --content iso 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
  (( ${#ISO_STORES[@]} )) || die "No active storage with ISO content enabled."
  if [[ -z $ISO_STORE ]]; then
    pick ISO_STORE "Storage for ISO images:" "${ISO_STORES[@]}"
  fi

  mapfile -t EXISTING < <(pvesm list "$ISO_STORE" --content iso 2>/dev/null | awk 'NR>1 {print $1}')
  CHOICES=()
  for v in "${EXISTING[@]}"; do CHOICES+=("$v"); done
  CHOICES+=("Download an ISO now")

  if (( ASSUME_YES )) && [[ -z $ISO_URL ]] && (( ${#EXISTING[@]} == 0 )); then
    die "No ISO on ${ISO_STORE} and none given. Pass --iso-url or --iso-volid."
  fi

  if [[ -n $ISO_URL ]]; then
    PICKED="Download an ISO now"
  else
    PICK_NO_DEFAULT=1 pick PICKED "Which ISO?" "${CHOICES[@]}"
  fi

  if [[ $PICKED == "Download an ISO now" ]]; then
    echo
    warn "Bliss OS has paused official public images. The SourceForge archive"
    warn "still downloads but gets no updates or support:"
    warn "  ${SF_PROJECT}"
    echo
    msg "For app compatibility pick an x86_64-v2 GApps build (16.9.x is newest)."
    msg "Avoid 'foss' (no Play Services) and 'Surface' (Surface-hardware kernel)."
    msg "Any other Android-x86 style ISO URL works here too."
    echo
    msg "Known-good pick (16.9.7, Android 13, GApps, generic - not Surface):"
    msg "  ${SF_EXAMPLE}"
    echo
    [[ -z $ISO_URL ]] && ask ISO_URL "Direct .iso URL" ""
    [[ -n $ISO_URL ]] || die "No ISO URL given. Upload one through the Proxmox UI and re-run with --iso-volid."

    ISO_PATH_PROBE=$(pvesm path "${ISO_STORE}:iso/probe.iso" 2>/dev/null || true)
    ISO_DIR=""
    [[ $ISO_PATH_PROBE == /* ]] && ISO_DIR=$(dirname "$ISO_PATH_PROBE")
    [[ -n $ISO_DIR && -d $ISO_DIR ]] || die "Could not resolve a filesystem path for '${ISO_STORE}'. Use a directory-type storage, or upload the ISO through the UI and re-run with --iso-volid."

    # Follow redirects (SourceForge mirrors) to learn the real filename.
    EFFECTIVE_URL=$(curl -sIL -o /dev/null -w '%{url_effective}' "$ISO_URL" 2>/dev/null || true)
    ISO_NAME=$(basename -- "${EFFECTIVE_URL%%\?*}" 2>/dev/null || true)
    ISO_NAME="${ISO_NAME//[^A-Za-z0-9._-]/_}"
    [[ $ISO_NAME == *.iso ]] || ISO_NAME="android-${VMID}.iso"

    if [[ -f "${ISO_DIR}/${ISO_NAME}" ]]; then
      ok "Already present: ${ISO_NAME}"
    else
      msg "Downloading ${ISO_NAME} → ${ISO_DIR}"
      curl -fL --progress-bar -o "${ISO_DIR}/${ISO_NAME}.part" "$ISO_URL" \
        || die "Download failed. Upload the ISO through the Proxmox UI and re-run with --iso-volid."
      SIZE=$(stat -c%s "${ISO_DIR}/${ISO_NAME}.part")
      if (( SIZE < 300000000 )); then
        rm -f "${ISO_DIR}/${ISO_NAME}.part"
        die "Downloaded file is only $((SIZE/1024/1024)) MB — that is a mirror/error page, not an Android ISO."
      fi
      if command -v file >/dev/null && ! file -b "${ISO_DIR}/${ISO_NAME}.part" | grep -qi 'iso 9660'; then
        rm -f "${ISO_DIR}/${ISO_NAME}.part"
        die "Downloaded file is not an ISO 9660 image."
      fi
      mv "${ISO_DIR}/${ISO_NAME}.part" "${ISO_DIR}/${ISO_NAME}"
      ok "Downloaded $(( SIZE / 1024 / 1024 )) MB"
    fi
    ISO_VOLID="${ISO_STORE}:iso/${ISO_NAME}"
  else
    ISO_VOLID="$PICKED"
  fi
fi
ok "ISO: ${ISO_VOLID}"
warn_iso_name "${ISO_VOLID##*/}"

# ------------------------------------------------------------------ network ---
hdr "Network and display"

mapfile -t BRIDGES < <(ip -br link show type bridge 2>/dev/null | awk '{print $1}')
if (( ${#BRIDGES[@]} )) && ! printf '%s\n' "${BRIDGES[@]}" | grep -qx "$BRIDGE"; then
  pick BRIDGE "Network bridge:" "${BRIDGES[@]}"
fi
NET0="${NIC_MODEL},bridge=${BRIDGE}"
[[ -n $VLAN ]] && NET0="${NET0},tag=${VLAN}"
ok "Network: ${NET0}"

case "$VGA" in
  virtio-gl|std|vmware) ;;
  *) die "--vga must be one of: virtio-gl, std, vmware" ;;
esac

if [[ $VGA == virtio-gl ]]; then
  if have_pkgs libgl1 libegl1; then
    ok "VirGL prerequisites present"
  else
    msg "VirGL needs libgl1 and libegl1 on the host."
    if confirm "Install them now with apt?"; then
      # A broken extra repo (e.g. an enterprise repo with no subscription)
      # makes 'update' exit non-zero; that must not abort the install.
      apt-get update -qq || warn "apt-get update reported errors — continuing"
      apt-get install -y -qq libgl1 libegl1 >/dev/null 2>&1 || true
      if have_pkgs libgl1 libegl1; then
        ok "Installed libgl1 libegl1"
      else
        warn "Install did not succeed — falling back to the 'std' display."
        VGA="std"
      fi
    else
      warn "Falling back to the 'std' display."
      VGA="std"
    fi
  fi
fi
VGA_ARG="$VGA"
[[ $VGA == std ]] && VGA_ARG="std,memory=32"
ok "Display: ${VGA_ARG}"

# ------------------------------------------------------------------- create ---
hdr "Creating VM ${VMID}"

cleanup_failed() {
  warn "Creation failed — removing the partial VM."
  qm destroy "$VMID" --purge --destroy-unreferenced-disks 1 &>/dev/null || true
}
trap cleanup_failed ERR

qm create "$VMID" \
  --name "$VMNAME" \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0" \
  --cpu "$CPU_TYPE" \
  --sockets 1 \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --balloon 0 \
  --scsihw virtio-scsi-single \
  --sata0 "${STORAGE}:${DISK_GB}" \
  --ide2 "${ISO_VOLID},media=cdrom" \
  --net0 "$NET0" \
  --vga "$VGA_ARG" \
  --tablet 1 \
  --rng0 source=/dev/urandom \
  --agent 0 \
  --onboot "$ONBOOT" \
  --boot "order=sata0;ide2" \
  --tags "android,blissos" \
  --description "Android VM created by proxmox-android-vm v${SCRIPT_VERSION}
ISO: ${ISO_VOLID}
Boot order is disk-first, so once Android is installed it boots itself and the
ISO can stay attached. Detach it with: qm set ${VMID} --ide2 none,media=cdrom"

trap - ERR
ok "VM ${VMID} created"

if (( START_AFTER )) || { (( ! ASSUME_YES )) && confirm "Start the VM now?"; }; then
  qm start "$VMID"
  ok "Started"
  START_AFTER=1
fi

# -------------------------------------------------------------------- finish ---
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
cat <<EOF

${G}Done.${N}

  Console:  https://${HOST_IP:-your-node}:8006/?console=kvm&novnc=1&vmid=${VMID}&node=${NODE}
            or Proxmox UI → ${VMID} (${VMNAME}) → Console

${B}Finish the Android install (one time, in the console):${N}

  1. At the GRUB menu pick ${Y}Auto Install to specified harddisk${N} and point it at
     the ${DISK_GB} GB SATA disk. That wipes the blank disk and does the whole
     install unattended.
     Prefer to drive it yourself? Pick "Installation", then: D to detect devices,
     C to create partitions, GPT ${Y}Yes${N}, new primary partition at full size,
     write, quit, format ext4, install ${Y}GRUB2 EFI${N}, make /system writable.
  2. Reboot. Boot order is disk-first, so it comes up in Android on its own.
  3. Walk through Android setup. "VirtWifi" is the virtual ethernet link.

${B}Handy afterwards:${N}

  Detach the ISO     qm set ${VMID} --ide2 none,media=cdrom
  Black screen?      In GRUB press 'e' and add ${Y}nomodeset${N} to the kernel line,
                     or rebuild with --vga std
  ADB over the LAN   Android Settings → About → tap Build number 7x →
                     Developer options → Wireless debugging, then
                     adb connect <vm-ip>:5555
  Resize the disk    qm resize ${VMID} sata0 +16G
  Remove it all      qm stop ${VMID} && qm destroy ${VMID} --purge

EOF
