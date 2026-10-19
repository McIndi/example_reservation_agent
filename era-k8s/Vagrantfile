# -*- mode: ruby -*-
# era-k8s: a single-node Kubernetes VM with the rossoctl platform tooling, as a Vagrant box.
#   vagrant box add era-k8s packer/output/era-k8s-vmware.box      # or era-k8s-virtualbox.box
#   vagrant up                                                     # first boot initializes the cluster (~5 min)
#   vagrant ssh -c 'sudo journalctl -fu k8s-init'                  # watch it; "k8s-init: done" = ready
#   vagrant ssh -c 'sudo era verify'                               # then: era platform, era agent, era vault, era siematic (or era all)
# Sizes and networking come from the environment: ERA_CPUS (8), ERA_MEMORY in MiB (24576), ERA_BRIDGE
# (unset = NAT with the port forwards below; set to a host interface name for a LAN address as well).
Vagrant.configure("2") do |config|
  config.vm.box = "era-k8s"
  config.vm.hostname = "era-k8s"
  config.vm.boot_timeout = 600
  config.vm.synced_folder ".", "/vagrant", disabled: true   # nothing in the image depends on the host

  cpus   = (ENV["ERA_CPUS"]   || 8).to_i
  memory = (ENV["ERA_MEMORY"] || 24576).to_i

  # The platform's URLs carry port 8080 and 8443 (https://rossoctl-ui.localtest.me:8443 and friends; localtest.me
  # resolves to 127.0.0.1). firewalld in the guest forwards 8080/8443 to the gateway NodePorts; the API server
  # is on 6443 (kubeconfig: vagrant ssh -c 'sudo cat /root/.kube/config.localhost').
  # Host ports can be moved (ERA_HTTPS_PORT, ERA_HTTP_PORT, ERA_API_PORT) when something else owns them, e.g. a
  # Lima instance of this same template; auto_correct lets Vagrant pick a free one and say so, rather than fail.
  config.vm.network "forwarded_port", guest: 8443, host: (ENV["ERA_HTTPS_PORT"] || 8443).to_i, auto_correct: true
  config.vm.network "forwarded_port", guest: 8080, host: (ENV["ERA_HTTP_PORT"]  || 8080).to_i, auto_correct: true
  config.vm.network "forwarded_port", guest: 6443, host: (ENV["ERA_API_PORT"]   || 6443).to_i, auto_correct: true
  config.vm.network "public_network", bridge: ENV["ERA_BRIDGE"] if ENV["ERA_BRIDGE"] && !ENV["ERA_BRIDGE"].empty?

  config.vm.provider "vmware_desktop" do |v|
    v.vmx["numvcpus"] = cpus
    v.vmx["memsize"]  = memory
    v.vmx["ethernet0.pcislotnumber"] = "160"   # the box's value; Vagrant warns it will stop overwriting it
    v.gui = false
  end
  config.vm.provider "virtualbox" do |vb|
    vb.name   = "era-k8s"
    vb.cpus   = cpus
    vb.memory = memory
    vb.customize ["modifyvm", :id, "--nat-localhostreachable1", "on"]
  end

  config.vm.post_up_message = <<~MSG
    era-k8s is booting. The cluster initializes itself on this first boot (k8s-init.service, about 5 minutes):
      vagrant ssh -c 'sudo journalctl -fu k8s-init'      # until "k8s-init: done"
      vagrant ssh -c 'sudo era verify'                   # then era platform, era agent, era vault, era siematic (or era all)
    Settings for the platform install: vagrant ssh -c 'sudo era config'  (/etc/era-k8s/config.env)
    URLs once the platform is up: https://rossoctl-ui.localtest.me:8443 (the local CA is in /etc/era-k8s/era-ca.crt in the VM)
  MSG
end
