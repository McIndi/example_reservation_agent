# era-k8s Vagrant boxes: the same provisioning as the Lima template (provision/*.sh), as a pre-init image
# that initializes its cluster at the first `vagrant up`. One build, two providers:
#   packer init era-k8s.pkr.hcl
#   packer build -only='*.vmware'      era-k8s.pkr.hcl   # output/era-k8s-vmware.box      (Fusion, Workstation)
#   packer build -only='*.virtualbox'  era-k8s.pkr.hcl   # output/era-k8s-virtualbox.box
# Both boot the Fedora 44 Server netinst ISO (isos/, a symlink to the download), install unattended via
# http/ks.cfg, run scripts/vagrant-user.sh, upload provision/ ansible/ bin/era export/sanitize-guest.sh,
# run scripts/provision.sh (ERA_KUBEADM_INIT=false) and scripts/finish.sh, then package the box.
packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware = {
      version = ">= 1.1.3"
      source  = "github.com/hashicorp/vmware"
    }
    virtualbox = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/virtualbox"
    }
    vagrant = {
      version = ">= 1.1.5"
      source  = "github.com/hashicorp/vagrant"
    }
  }
}

variable "iso_path" {
  type    = string
  default = "isos/Fedora-Server-netinst-x86_64-44-1.7.iso"
}
variable "iso_checksum" {
  type    = string
  default = "sha256:ae20c06bea746913cadea7d80463e13f4bf55bee4df2918111c921c674b70283"
}
variable "cpus" {
  type    = number
  default = 8
}
variable "memory" {
  type    = number
  default = 16384
} # build-time only; the Vagrantfile sets the runtime size
variable "disk_size" {
  type    = number
  default = 102400
} # MB, thin; the Lima template uses 100 GiB too
variable "box_version" {
  type    = string
  default = "0.1.0"
}

locals {
  # The kickstart over Packer's HTTP server; Fedora 44 boots the installer through GRUB2, so drive its
  # command line explicitly (the <tab> trick of isolinux days does nothing). Proven by the fedora44 boxes.
  boot_command = [
    "<wait5>", "c<wait>",
    "linux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=Fedora-S-dvd-x86_64-44 inst.text ip=dhcp inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg<enter><wait>",
    "initrd /images/pxeboot/initrd.img<enter><wait>",
    "boot<enter>",
  ]
  execute_command = "echo 'vagrant' | {{ .Vars }} sudo -E -S bash '{{ .Path }}'"
  shutdown        = "echo 'vagrant' | sudo -S /sbin/shutdown -P now"
}

source "vmware-iso" "vmware" {
  vm_name              = "era-k8s"
  guest_os_type        = "fedora-64"
  headless             = true
  firmware             = "bios"
  network_adapter_type = "vmxnet3"
  iso_url              = "file://${abspath("${path.root}/${var.iso_path}")}"
  iso_checksum         = var.iso_checksum
  http_directory       = "${path.root}/http"
  boot_wait            = "8s"
  boot_key_interval    = "50ms"
  boot_command         = local.boot_command
  communicator         = "ssh"
  ssh_username         = "vagrant"
  ssh_password         = "vagrant"
  ssh_timeout          = "60m"
  shutdown_command     = local.shutdown
  cpus                 = var.cpus
  memory               = var.memory
  disk_size            = var.disk_size
  skip_compaction      = false
  output_directory     = "${path.root}/output-vmware"
  # No static MAC: VMware's auto-generated one is what Packer looks up in the DHCP leases (see the
  # fedora44 template's note).
}

source "virtualbox-iso" "virtualbox" {
  vm_name              = "era-k8s"
  guest_os_type        = "Fedora_64"
  headless             = true
  iso_url              = "file://${abspath("${path.root}/${var.iso_path}")}"
  iso_checksum         = var.iso_checksum
  iso_interface        = "sata"
  hard_drive_interface = "sata"
  http_directory       = "${path.root}/http"
  boot_wait            = "8s"
  boot_command         = local.boot_command
  communicator         = "ssh"
  ssh_username         = "vagrant"
  ssh_password         = "vagrant"
  ssh_timeout          = "60m"
  shutdown_command     = local.shutdown
  cpus                 = var.cpus
  memory               = var.memory
  disk_size            = var.disk_size
  guest_additions_mode = "disable" # no synced folders needed; the Vagrantfile disables /vagrant
  output_directory     = "${path.root}/output-virtualbox"
}

build {
  name    = "era-k8s"
  sources = ["source.vmware-iso.vmware", "source.virtualbox-iso.virtualbox"]

  provisioner "shell" {
    execute_command = local.execute_command
    script          = "${path.root}/scripts/vagrant-user.sh"
  }
  provisioner "shell" { inline = ["mkdir -p /tmp/era-k8s"] }
  provisioner "file" {
    source      = "${path.root}/../provision"
    destination = "/tmp/era-k8s/provision"
  }
  provisioner "file" {
    source      = "${path.root}/../ansible"
    destination = "/tmp/era-k8s/ansible"
  }
  provisioner "file" {
    source      = "${path.root}/../bin/era"
    destination = "/tmp/era-k8s/era"
  }
  provisioner "file" {
    source      = "${path.root}/../export/sanitize-guest.sh"
    destination = "/tmp/era-k8s/sanitize-guest.sh"
  }
  provisioner "shell" {
    execute_command = local.execute_command
    script          = "${path.root}/scripts/provision.sh"
    timeout         = "45m"
  }
  provisioner "shell" {
    execute_command = local.execute_command
    script          = "${path.root}/scripts/finish.sh"
    timeout         = "30m"
  }
  post-processor "vagrant" {
    output              = "${path.root}/output/era-k8s-{{ .Provider }}.box"
    keep_input_artifact = false
  }
}
