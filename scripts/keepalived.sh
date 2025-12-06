#!/bin/bash
# Setup Keepalived for High Availability on Control Plane Nodes and listen for 6443 port
set -euxo pipefail

sudo apt-get update
sudo apt-get install -y keepalived


cat <<EOF | sudo tee /etc/keepalived/check_apiserver.sh
#!/bin/bash
BIND_PORT=6443
if ! (ip addr | grep -q '$VIP_ADDRESS/'); then
  if grep -zo 'unicast_peer[[:space:]]*{[[:space:]]*}' /etc/keepalived/keepalived.conf; then
    if arping -f -I $(ip route get $VIP_ADDRESS | cut -d' ' -f3 | head -1) -c 3 $VIP_ADDRESS; then
      if curl -k https://$VIP_ADDRESS:$BIND_PORT; then
        exit 1
      fi
    fi
  fi
fi

PORTS=\$(ss -nltp)
echo \$PORTS | grep -q \$BIND_PORT
if [ $? -ne 0 ]; then
  echo $(date): keepalived failed to find kube-apiserver bound to port >> /etc/keepalived/log
  exit 1
fi
EOF

cat <<EOF | sudo tee /etc/keepalived/keepalived_state.sh
#!/bin/bash
echo \$(date): keepalived state: "\$@" >> /etc/keepalived/log
EOF

sudo useradd -r -s /sbin/nologin keepalived_script
chmod 755 /etc/keepalived/check_apiserver.sh
chmod 755 /etc/keepalived/keepalived_state.sh
chown -R keepalived_script:keepalived_script /etc/keepalived/*.sh

cat <<EOF | sudo tee /etc/keepalived/keepalived.conf
global_defs {
  router_id LVS_DEVEL
  enable_script_security
}
vrrp_script chk_kube_apiserver {
    script "/etc/keepalived/check_apiserver.sh"
    interval 5
    weight 0
    fall 10
    rise 2
}
vrrp_instance VI_1 {
    state MASTER
    interface $(ip route | grep $SUBNET | awk '{print $3'} | head -n 1) 

    virtual_router_id 51
    priority 101
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass keepalivedpassword
    }
    virtual_ipaddress {
        $VIP_ADDRESS
    }
    track_script {
        chk_kube_apiserver
    }
    notify /etc/keepalived/keepalived_state.sh
}
EOF

sudo systemctl enable keepalived
sudo systemctl start keepalived
echo "Keepalived setup completed on Control Plane Node"
