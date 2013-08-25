#!/bin/bash

OPENSTACK_PASSWORD=c1oudc0w
OPENSTACK_FLOATING_RANGE=10.39.39.0/24
HOST_IP=$(ip addr | grep 'inet .*global' | cut -f 6 -d ' ' | cut -f1 -d '/' | head -n 1)
PUBLIC_INTERFACE=$(ip addr | grep 'inet .*global' | cut -f 11 -d ' ' | head -n 1)
SECURITY_GROUP=cf
CF_DOMAIN_NAME=${HOST_IP}.xip.io

sudo apt-get update
sudo apt-get install -y git-core ruby1.9.3 nginx build-essential zlib1g-dev libssl-dev openssl libreadline-dev libxslt-dev libxml2-dev libsqlite3-dev


#= Ruby
if [ ! -d ~/.rbenv ]; then
    git clone https://github.com/sstephenson/rbenv.git ~/.rbenv
    git clone https://github.com/sstephenson/ruby-build.git ~/.rbenv/plugins/ruby-build
    echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.profile
    echo 'eval "$(rbenv init -)"' >> ~/.profile
fi
. ~/.profile
if ! (rbenv versions | grep -q 1.9.3-p448); then
    rbenv install 1.9.3-p448
fi
rbenv global 1.9.3-p448
gem install bosh_cli -v "~> 1.5.0.pre" --source https://s3.amazonaws.com/bosh-jenkins-gems/ --no-ri --no-rdoc
gem install bosh-bootstrap bundler --no-ri --no-rdoc
rbenv rehash

#= DevStack
git clone git://github.com/openstack-dev/devstack.git
(
    cd devstack

    # Using Grizlly
    git checkout -t origin/stable/grizzly

    cat <<EOF > localrc
DATABASE_PASSWORD=${OPENSTACK_PASSWORD}
RABBIT_PASSWORD=${OPENSTACK_PASSWORD}
SERVICE_TOKEN=${OPENSTACK_PASSWORD}
SERVICE_PASSWORD=${OPENSTACK_PASSWORD}
ADMIN_PASSWORD=${OPENSTACK_PASSWORD}

VOLUME_BACKING_FILE_SIZE=70000M
API_RATE_LIMIT=False

FLOATING_RANGE=${OPENSTACK_FLOATING_RANGE}
FLAT_INTERFACE=""
PUBLIC_INTERFACE=${PUBLIC_INTERFACE}
HOST_IP=${HOST_IP}
EOF

    ./stack.sh
)

export OS_USERNAME=admin
export OS_PASSWORD=${OPENSTACK_PASSWORD}
export OS_TENANT_NAME=demo
export OS_AUTH_URL=http://${HOST_IP}:5000/v2.0/

OS_TENANT_ID=$(keystone tenant-list | awk '/\ demo\ / {print $2}')
nova quota-update --ram 999999 ${OS_TENANT_ID}
CF_ROUTER_IP=$(nova floating-ip-create | awk '/\ public\ / {print $2}')

nova secgroup-create ${SECURITY_GROUP} "Cloud Foundry"
for port in 22 80 443 4222; do
    nova secgroup-add-rule ${SECURITY_GROUP} tcp ${port} ${port} 0.0.0.0/0
done
nova secgroup-add-group-rule cf ${SECURITY_GROUP} tcp 1 65535
nova secgroup-add-group-rule cf ${SECURITY_GROUP} udp 1 65535

nova flavor-create m1.microbosh 20 1024 10 2
nova flavor-create m1.onvm 21 1024 10 1

sudo service apache2 stop


#= bosh-bootstrap
rm -rf ~/.microbosh
bosh-bootstrap deploy <<EOF
2
demo
${OPENSTACK_PASSWORD}
demo
http://${HOST_IP}:5000/v2.0/

EOF

#= bosh-cloudfoundry
bosh target $(cat ~/.microbosh/settings.yml | awk '/\ ip:\ / {print $2}') <<EOF
admin
admin
EOF

git clone https://github.com/yudai/bosh-cloudfoundry.git
(
    cd bosh-cloudfoundry
    git checkout aio
    gem build bosh-cloudfoundry.gemspec
    gem install bosh-cloudfoundry-0.7.0.gem
)

bosh prepare cf
echo $CF_ROUTER_IP
bosh create cf --ip ${CF_ROUTER_IP} --security-group ${SECURITY_GROUP} --dns ${CF_DOMAIN_NAME} --deployment-size small --skip-dns-validation <<EOF
yes
yes
yes
1EOF

#= nginx
sudo cat <<EOF | sudo tee /etc/nginx/sites-available/cf
server {
    listen 80;
    location / {
        proxy_pass        http://${CF_ROUTER_IP}:80;
        proxy_buffering   off;
        proxy_set_header  X-Real-IP  \$remote_addr;
        proxy_set_header  Host       \$host;
    }
}
EOF

sudo rm /etc/nginx/sites-enabled/default
sudo ln -fs /etc/nginx/sites-available/cf /etc/nginx/sites-enabled/cf
sudo service nginx restart