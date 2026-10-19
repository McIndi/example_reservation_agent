# shared by the image tests: ssh as vagrant with Vagrant's insecure key, wait for the first-boot init, verify
SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)
for k in "$HOME/.vagrant.d/insecure_private_keys/vagrant.key.ed25519" "$HOME/.vagrant.d/insecure_private_keys/vagrant.key.rsa" "$HOME/.vagrant.d/insecure_private_key"; do
  [ -f "$k" ] && SSHOPTS+=(-i "$k")
done
vssh() { ssh "${SSHOPTS[@]}" "$@"; }   # vssh [-p PORT] vagrant@HOST CMD
wait_ssh() { # wait_ssh HOST PORT
  for i in $(seq 1 90); do vssh -p "$2" "vagrant@$1" true 2>/dev/null && return 0; sleep 5; done
  echo "no ssh to $1:$2 after 450 s" >&2; return 1
}
wait_init() { # wait_init HOST PORT: until k8s-init.service has finished
  for i in $(seq 1 60); do
    st=$(vssh -p "$2" "vagrant@$1" 'systemctl is-active k8s-init.service' 2>/dev/null || true)
    case "$st" in active) echo "k8s-init: active (done)"; return 0 ;; failed) echo "k8s-init FAILED"; vssh -p "$2" "vagrant@$1" 'sudo journalctl -u k8s-init --no-pager | tail -40'; return 1 ;; esac
    sleep 10
  done; echo "k8s-init not finished after 600 s" >&2; return 1
}
verify() { # verify HOST PORT
  vssh -p "$2" "vagrant@$1" 'hostname; agetty --show-issue 2>/dev/null | grep -m1 era-k8s || head -1 /etc/issue.d/era-k8s.issue; sudo kubectl get nodes -o wide; sudo era verify 2>&1 | tail -6'
}
wait_api() { # wait_api HOST PORT: after a reboot, until the API server answers and the node is Ready again
  for i in $(seq 1 36); do
    out=$(vssh -p "$2" "vagrant@$1" 'sudo kubectl get nodes --no-headers 2>/dev/null' || true)
    case "$out" in *" Ready "*) echo "after reboot: $out"; return 0 ;; esac
    sleep 5
  done; echo "node not Ready within 180 s of the reboot" >&2; return 1
}
reboot_check() { # reboot_check HOST PORT
  vssh -p "$2" "vagrant@$1" 'sudo systemctl reboot' 2>/dev/null || true; sleep 20
  wait_ssh "$1" "$2"; wait_api "$1" "$2"
  vssh -p "$2" "vagrant@$1" 'sudo kubectl get pods -A --no-headers | grep -v -E " (Running|Completed) " || echo "all pods Running"'
}
