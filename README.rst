======================
 Enabling in Devstack
======================

Devstack plugin for AMQP 1.0 olso.messaging driver - This plugin supports the QPID C++ broker for RPC and Notification backends  and the QPID Dispatch Router messaging system for the RPC backend. Additional information on these messaging systems can be found at the Apache QPID homepage (https://qpid.apache.org).

1. Download DevStack

2. Add this repo as an external repository::

     cat > local.conf
     [[local|localrc]]
     enable_plugin amqp1 https://git.openstack.org/openstack/devstack-plugin-amqp1

3. Set username and password variables if needed and they will be added to configuration::

     AMQP1_USERNAME=queueuser
     AMQP1_PASSWORD=queuepassword     

4. Optionally set the service variable for the configuration. The default is for the broker to provide both the RPC and Notification backends. If dual backends are to be used as an alternative AMQP1 service::

     AMQP1_SERVICE=qpid-dual
   
5. Optionally set the network ports used to connect to the messaging service. If dual backends are to be configured, a separate Notify port must be used::

     AMQP1_DEFAULT_PORT=5672
     AMQP1_NOTIFY_PORT=5671

5. run ``stack.sh``

    
