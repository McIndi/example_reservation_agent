# Running the exported Kubernetes image

What you have: a Fedora 44 disk image with CRI-O, kubeadm/kubelet/kubectl, podman/buildah/skopeo,
firewalld (6443, 10250, 30000-32767/tcp and Calico's ports open) and the control-plane, Calico and
storage images already pulled. The cluster is NOT initialized yet: `k8s-init.service` does that on the
first boot, using whatever address the VM gets (every IPv4 on the machine goes into the API certificate).

1. Create a VM from the image: 8 vCPU, 24 GB RAM recommended (4 / 16 GB minimum), UEFI boot, one NIC.
   qcow2: KVM/libvirt, Proxmox. vmdk: VMware Fusion/Workstation/ESXi (import, or wrap in an OVA).
   vdi: VirtualBox. vhdx: Hyper-V.
2. Settings live in `/etc/era-k8s/config.env` (hostnames domain, LLM endpoint and model, TLS). Change
   them before the first boot through the same cloud-init user-data, for example:

       #cloud-config
       users:
         - name: you
           groups: wheel
           sudo: ALL=(ALL) NOPASSWD:ALL
           ssh_authorized_keys: ["ssh-ed25519 AAAA..."]
       write_files:
         - path: /etc/era-k8s/config.env
           content: |
             ERA_DOMAIN=10-0-0-50.sslip.io
             ERA_LLM_PROVIDER=external
             ERA_LLM_API_BASE=https://api.openai.com/v1
             ERA_LLM_MODEL=gpt-4o-mini
             ERA_TLS=true
             ERA_REGISTRY=in-cluster

3. Give cloud-init a datasource so you get a login: a NoCloud seed (user-data with your user and SSH key)
   on KVM/VirtualBox/Hyper-V, or VMware guestinfo on Fusion/ESXi. Without one, there is no way in:
   the image ships with no passwords and no SSH keys.
4. Boot. Watch the initialization: `sudo journalctl -fu k8s-init` (6 to 10 minutes with internet access;
   the Calico operator and local-path manifests are fetched from GitHub at that point).
5. Use it: `sudo kubectl get nodes`, or copy `/etc/kubernetes/admin.conf` out. `/root/.kube/config.lan`
   points at the VM's LAN address for use from your workstation.

Re-running: `sudo /usr/local/sbin/k8s-init.sh` is idempotent (exits if the cluster exists).
Reset to empty: `sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d /var/lib/calico && sudo reboot`.
