======================
 Enabling in Devstack
======================

Devstack plugin for AMQP 1.0 olso.messaging driver

1. Download DevStack

2. Add this repo as an external repository::

     cat > local.conf
     [[local|localrc]]
     enable_plugin amqp1 https://git.openstack.org/openstack/devstack-plugin-amqp1

3. Set username and password variables if needed and they will be added to configuration::

     AMQP1_USERNAME=queueuser
     AMQP1_PASSWORD=queuepassword     

4. run ``stack.sh``

    
