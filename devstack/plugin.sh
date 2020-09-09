#!/bin/bash
#
#    Licensed to the Apache Software Foundation (ASF) under one
#    or more contributor license agreements.  See the NOTICE file
#    distributed with this work for additional information
#    regarding copyright ownership.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
#

# Sets up the messaging backend service needed by the AMQP 1.0
# transport (amqp://)
#
# Environment Configuration
#
# AMQP1_SERVICE - This plugin can deploy one of several different
#   message bus configurations.  This variable identifies the message
#   bus configuration that will be used. Should be one of:
#     'qpid' - use the qpidd broker for both RPC and Notifications
#     'qpid-dual' - use qpidd for Notifications, qdrouterd for RPC
#     'qpid-hybrid' - use rabbitmq for Notifications, qdrouterd for RPC
#     'external' - use a pre-provisioned message bus.  This prevents
#       this plugin from creating the message bus.  Instead it assumes
#       the bus has already been set up and simply connects to it.
# AMQP1_RPC_TRANSPORT_URL - Transport URL to use for RPC service.
#    A virtual host may be added at run time.
# AMQP1_NOTIFY_TRANSPORT_URL - Transport URL to use for Notification
#    service. A virtual host may be added at run time.
#
# If the above AMQP1_*_TRANSPORT_URL env vars are not defined, this
# plugin will construct these urls using the following env vars:
#
# AMQP1_HOST - the host used to connect to the messaging service.
#    Defaults to $SERVICE_HOST
# AMQP1_{DEFAULT_PORT, NOTIFY_PORT} - the port used to connect to the
#    messaging service. AMQP1_NOTIFY_PORT defaults to 5672.
#    AMQP_DEFAULT_PORT also defaults to 5672 for the 'qpid'
#    configuration, otherwise 45672 to avoid port# clashes with the
#    Notification port.
# AMQP1_{USERNAME,PASSWORD} - for authentication with AMQP1_HOST (optional)
#
# The RPC transport url will be defined as:
# "amqp://$AMQP1_USERNAME:$AMQP1_PASSWORD@$AMQP1_HOST:${AMQP1_DEFAULT_PORT}/"
#
# The notify transport url will be defined as:
# "amqp://$AMQP1_USERNAME:$AMQP1_PASSWORD@$AMQP1_HOST:${AMQP1_NOTIFY_PORT}/"
#

# parse URL, extracting host, port, username, password
function _parse_transport_url {
    local uphp    # user+password+host+port
    local user    # username
    local passwd  # password
    local hostport  # host+port
    local host    # hostname
    local port    # port #

    # extract [user:pass@]host:port
    uphp=$(echo $1 | sed -e "s#^[^:]*://\([^/]*\).*#\1#")
    # parse out username + password if present:
    user=""
    passwd=""
    if [[ "$uphp" =~ .+@.+ ]]; then
        local passhostport
        user=$(echo $uphp | sed -e "s#^\([^:]*\).*#\1#")
        passhostport=$(echo $uphp | sed -e "s#$user:##")
        passwd=$(echo $passhostport | sed -e "s#^\([^@]*\).*#\1#")
        hostport=$(echo $passhostport | sed -e "s#$passwd@##")
    else
        hostport=$uphp
    fi
    host=$(echo $hostport | cut -d: -f1)
    port=$(echo $hostport | cut -d: -f2)

    # field 1   2     3     4
    echo "$host $port $user $passwd"
}


# default transport url string
function _get_amqp1_default_transport_url {
    local virtual_host
    virtual_host=$1
    echo "$AMQP1_RPC_TRANSPORT_URL/$virtual_host"
}

# notify transport url string
function _get_amqp1_notify_transport_url {
    local virtual_host
    virtual_host=$1

    if [ "$AMQP1_NOTIFY" == "rabbit" ]; then
        echo $(_get_rabbit_notification_url $virtual_host)
    else
        echo "$AMQP1_NOTIFY_TRANSPORT_URL/$virtual_host"
    fi
}

# override the default in devstack as it forces all non-rabbit
# backends to fail...
function _amqp1_add_vhost {

    if [ "$AMQP1_NOTIFY" == "rabbit" ]; then
        _rabbit_rpc_backend_add_vhost $@
    fi

    # no configuration necessary for AMQP 1.0 backend
    return 0
}

# install packages necessary for support of the oslo.messaging AMQP
# 1.0 driver
function _install_pyngus {
    # Install pyngus client API
    if is_fedora; then
        # TODO(kgiusti) due to a bug in the way pip installs wheels,
        # do not let pip install the proton python bindings as it will
        # put them in the wrong path:
        # https://github.com/pypa/pip/issues/2940
        install_package python-qpid-proton
    elif is_ubuntu; then
        # ditto
        install_package python3-qpid-proton
    fi
    pip_install_gr pyngus
}


# remove packages used by oslo.messaging AMQP 1.0 driver
function _remove_pyngus {
    # TODO(kgiusti) no way to pip uninstall?
    # pip_install_gr pyngus
    :
}


# Set up the various configuration files used by the qpidd broker
function _configure_qpid {

    local url
    url=$(_parse_transport_url $1)

    # the location of the configuration files have changed since qpidd 0.14
    local qpid_conf_file
    if [ -e /etc/qpid/qpidd.conf ]; then
        qpid_conf_file=/etc/qpid/qpidd.conf
    elif [ -e /etc/qpidd.conf ]; then
        qpid_conf_file=/etc/qpidd.conf
    else
        exit_distro_not_supported "qpidd.conf file not found!"
    fi

    # ensure that the qpidd service can read its config
    sudo chmod o+r $qpid_conf_file

    # force the ACL file to a known location
    local qpid_acl_file
    qpid_acl_file=/etc/qpid/qpidd.acl
    if [ ! -e $qpid_acl_file ]; then
        sudo mkdir -p -m 755 `dirname $qpid_acl_file`
        sudo touch $qpid_acl_file
        sudo chmod o+r $qpid_acl_file
    fi
    echo "acl-file=$qpid_acl_file" | sudo tee $qpid_conf_file

    local username
    username=$(echo "$url" | cut -d' ' -f3)
    if [ -z "$username" ]; then
        # no QPID user configured, so disable authentication
        # and access control
        echo "auth=no" | sudo tee --append $qpid_conf_file
        cat <<EOF | sudo tee $qpid_acl_file
acl allow all all
EOF
    else
        # Configure qpidd to use PLAIN authentication, and add
        # $username to the ACL:
        echo "auth=yes" | sudo tee --append $qpid_conf_file
        local passwd
        passwd=$(echo "$url" | cut -d' ' -f4)
        if [ -z "$passwd" ]; then
            read_password password "ENTER A PASSWORD FOR QPID USER $username"
        fi
        # Create ACL to allow $username full access
        cat <<EOF | sudo tee $qpid_acl_file
group admin ${username}@QPID
acl allow admin all
acl deny all all
EOF
        # Add user to SASL database
        local sasl_conf_file
        sasl_conf_file=/etc/sasl2/qpidd.conf
        cat <<EOF | sudo tee $sasl_conf_file
pwcheck_method: auxprop
auxprop_plugin: sasldb
sasldb_path: /var/lib/qpidd/qpidd.sasldb
mech_list: PLAIN
sql_select: dummy select
EOF

        local sasl_db
        sasl_db=`sudo grep sasldb_path $sasl_conf_file | cut -f 2 -d ":" | tr -d [:blank:]`
        if [ ! -e $sasl_db ]; then
            sudo mkdir -p -m 755 `dirname $sasl_db`
        fi
        echo $passwd | sudo saslpasswd2 -c -p -f $sasl_db -u QPID $username
        sudo chmod o+r $sasl_db
    fi

    # Ensure that the version of the broker can support AMQP 1.0 and
    # configure the queue and topic address patterns used by
    # oslo.messaging.
    QPIDD=$(type -p qpidd)
    if ! $QPIDD --help | grep -q "queue-patterns"; then
        exit_distro_not_supported "qpidd with AMQP 1.0 support"
    fi
    local log_file
    log_file=$LOGDIR/qpidd.log
    cat <<EOF | sudo tee --append $qpid_conf_file
queue-patterns=exclusive
queue-patterns=unicast
topic-patterns=broadcast
log-enable=info+
log-to-file=$log_file
log-to-syslog=yes
max-connections=0
EOF

    # Set the SASL service name if the version of qpidd supports it
    if $QPIDD --help | grep -q "sasl-service-name"; then
        cat <<EOF | sudo tee --append $qpid_conf_file
sasl-service-name=amqp
EOF
    fi

    sudo touch $log_file
    sudo chmod a+rw $log_file  # qpidd user can write to it
}


# Set up the various configuration files used by the qpid-dispatch-router (qdr)
function _configure_qdr {

    local url
    url=$(_parse_transport_url $1)

    QDR=$(type -p qdrouterd)

    # the location of the configuration is /etc/qpid-dispatch
    local qdr_conf_file
    if [ -e /etc/qpid-dispatch/qdrouterd.conf ]; then
        qdr_conf_file=/etc/qpid-dispatch/qdrouterd.conf
    else
        exit_distro_not_supported "qdrouterd.conf file not found!"
    fi

    # ensure that the qpid-dispatch-router service can read its config
    sudo chmod o+r $qdr_conf_file

    # qdouterd.conf file customization for devstack deployment
    # Define attributes related to the AMQP container
    # Create stand alone router
    cat <<EOF | sudo tee $qdr_conf_file
router {
    mode: standalone
    id: Router.A
    workerThreads: 4
    saslConfigPath: /etc/sasl2
    saslConfigName: qdrouterd
}

EOF

    # Create a listener for incoming connect to the router
    local port
    port=$(echo "$url" | cut -d' ' -f2)

    # ip address field name changed to 'host' at 1.0+
    local field_name
    field_name=$([[ $($QDR -v) == 0.*.* ]] && echo addr || echo host)

    cat <<EOF | sudo tee --append $qdr_conf_file
listener {
    ${field_name}: 0.0.0.0
    port: ${port}
    role: normal
EOF
    local username
    username=$(echo "$url" | cut -d' ' -f3)
    if [ -z "$username" ]; then
        #no user configured, so disable authentication
        cat <<EOF | sudo tee --append $qdr_conf_file
    authenticatePeer: no
}

EOF
    else
        # configure to use PLAIN authentication
        local passwd
        passwd=$(echo "$url" | cut -d' ' -f4)
        if [ -z "$passwd" ]; then
            read_password passwd "ENTER A PASSWORD FOR QPID DISPATCH USER $username"
        fi
        cat <<EOF | sudo tee --append $qdr_conf_file
    authenticatePeer: yes
}

EOF
        # Add user to SASL database
        local sasl_conf_file
        sasl_conf_file=/etc/sasl2/qdrouterd.conf
        cat <<EOF | sudo tee $sasl_conf_file
pwcheck_method: auxprop
auxprop_plugin: sasldb
sasldb_path: /var/lib/qdrouterd/qdrouterd.sasldb
mech_list: PLAIN
sql_select: dummy select
EOF
        local sasl_db
        sasl_db=`sudo grep sasldb_path $sasl_conf_file | cut -f 2 -d ":" | tr -d [:blank:]`
        if [ ! -e $sasl_db ]; then
            sudo mkdir -p -m 755 `dirname $sasl_db`
        fi
        echo $passwd | sudo saslpasswd2 -c -p -f $sasl_db $username
        sudo chmod o+r $sasl_db
    fi

    # Create fixed address prefixes
    cat <<EOF | sudo tee --append $qdr_conf_file
address {
    prefix: unicast
    distribution: closest
}

address {
    prefix: exclusive
    distribution: closest
}

address {
    prefix: broadcast
    distribution: multicast
}

address {
    prefix: openstack.org/om/rpc/multicast
    distribution: multicast
}

address {
    prefix: openstack.org/om/rpc/unicast
    distribution: closest
}

address {
    prefix: openstack.org/om/rpc/anycast
    distribution: balanced
}

address {
    prefix: openstack.org/om/notify/multicast
    distribution: multicast
}

address {
    prefix: openstack.org/om/notify/unicast
    distribution: closest
}

address {
    prefix: openstack.org/om/notify/anycast
    distribution: balanced
}

EOF

    local log_file
    log_file=$LOGDIR/qdrouterd.log
    sudo touch $log_file
    sudo chmod a+rw $log_file  # qdrouterd user can write to it

    # Create log file configuration
    cat <<EOF | sudo tee --append $qdr_conf_file
log {
    module: DEFAULT
    enable: trace+
    output: $log_file
}

EOF

}


# install and configure the amqp1 backends
# (qpidd broker and optionally dispatch-router for hybrid)
function _install_amqp1_backend {

    local qdrouterd_package
    local qpidd_package
    if is_fedora; then
        # expects epel is already added to the yum repos
        install_package cyrus-sasl-lib
        install_package cyrus-sasl-plain
        qdrouterd_package="qpid-dispatch-router"
        qpidd_package="qpid-cpp-server"
    elif is_ubuntu; then
        install_package sasl2-bin
        # newer qpidd and proton only available via the qpid PPA
        sudo add-apt-repository -y ppa:qpid/released
        REPOS_UPDATED=False
        update_package_repo
        qdrouterd_package="qdrouterd"
        qpidd_package="qpidd"
    else
        exit_distro_not_supported "amqp1 qpid installation"
    fi

    _install_pyngus

    if [ "$AMQP1_RPC" == "qdrouterd" ]; then
        install_package $qdrouterd_package
        _configure_qdr $AMQP1_RPC_TRANSPORT_URL
    fi
    if [ "$AMQP1_NOTIFY" == "qpidd" ]; then
        install_package $qpidd_package
        _configure_qpid $AMQP1_NOTIFY_TRANSPORT_URL
    fi
}


function _start_amqp1_backend {
    echo_summary "Starting amqp1 backends"
    # restart, since qpid* may already be running
    if [ "$AMQP1_RPC" == "qdrouterd" ]; then
        restart_service qdrouterd
    fi
    if [ "$AMQP1_NOTIFY" == "qpidd" ]; then
        restart_service qpidd
    fi
}


function _cleanup_amqp1_backend {
    if is_fedora; then
        if [ "$AMQP1_RPC" == "qdrouterd" ]; then
            uninstall_package qpid-dispatch-router
        fi
        if [ "$AMQP1_NOTIFY" == "qpidd" ]; then
            uninstall_package qpid-cpp-server
        fi
    elif is_ubuntu; then
        if [ "$AMQP1_RPC" == "qdrouterd" ]; then
            uninstall_package qdrouterd
        fi
        if [ "$AMQP1_NOTIFY" == "qpidd" ]; then
            uninstall_package qpidd
        fi
    else
        exit_distro_not_supported "amqp1 qpid installation"
    fi

    _remove_pyngus
}


# iniset configuration for amqp rpc_backend
function _iniset_amqp1_backend {
    local package
    local file
    local section
    local virtual_host

    package=$1
    file=$2
    section=${3:-DEFAULT}
    virtual_host=$4

    iniset $file $section transport_url $(get_transport_url "$virtual_host")
    iniset $file oslo_messaging_notifications transport_url $(get_notification_url "$virtual_host")
}


if is_service_enabled amqp1; then

    # for backward compatibility - generate the transport urls from the old env vars if not set
    if [[ -z "$AMQP1_RPC_TRANSPORT_URL" ]]; then
        AMQP1_DEFAULT_PORT=${AMQP1_DEFAULT_PORT:=$([[ "$AMQP1_SERVICE" == "qpid" ]] && echo 5672 || echo 45672)}
        if [ -n "$AMQP1_USERNAME" ]; then
            AMQP1_RPC_TRANSPORT_URL="amqp://$AMQP1_USERNAME:$AMQP1_PASSWORD@$AMQP1_HOST:$AMQP1_DEFAULT_PORT"
        else
            AMQP1_RPC_TRANSPORT_URL="amqp://$AMQP1_HOST:$AMQP1_DEFAULT_PORT"
        fi
    fi

    if [[ -z "$AMQP1_NOTIFY_TRANSPORT_URL" ]]; then
        AMQP1_NOTIFY_PORT=${AMQP1_NOTIFY_PORT:=5672}
        if [ -n "$AMQP1_USERNAME" ]; then
            AMQP1_NOTIFY_TRANSPORT_URL="amqp://$AMQP1_USERNAME:$AMQP1_PASSWORD@$AMQP1_HOST:$AMQP1_NOTIFY_PORT"
        else
            AMQP1_NOTIFY_TRANSPORT_URL="amqp://$AMQP1_HOST:$AMQP1_NOTIFY_PORT"
        fi
    fi

    case $AMQP1_SERVICE in
        "qpid")
            # Use qpidd for both notifications and RPC messages
            AMQP1_RPC="qpidd"
            AMQP1_NOTIFY="qpidd"
            ;;
        "qpid-dual")
            # Use qpidd for notifications and qdrouterd for RPC messages
            AMQP1_RPC="qdrouterd"
            AMQP1_NOTIFY="qpidd"
            ;;
        "qpid-hybrid")
            # Use rabbitmq for notifications and qdrouterd for RPC messages
            AMQP1_RPC="qdrouterd"
            AMQP1_NOTIFY="rabbit"
            ;;
        "external")
            # Use a pre-provisioned message bus @ AMQP1_NOTIFY/RPC_TRANSPORT_URLs
            AMQP1_RPC="external"
            AMQP1_NOTIFY="external"
            ;;
        *)
            die $LINENO "Set AMQP1_SERVICE to one of: qpid, qpid-dual, qpid-hybrid or external - $AMQP1_SERVICE not supported"
            ;;
    esac

    #
    # Override all rpc_backend functions that are rabbit-specific:
    #

    # this plugin can be configured to use rabbit for notifications
    # (qpid-hybrid), so save a copy of the original
    if [ ! $(type -t _get_rabbit_notification_url) ]; then
        get_notification_url_definition=$(declare -f get_notification_url)
        eval "_get_rabbit_notification_url() ${get_notification_url_definition#*\()}"
        export -f _get_rabbit_notification_url
    fi

    # rpc_backend's version of rpc_backend_add_vhost assumes vhosting
    # is a rabbit-only feature!  Will need original if using rabbit
    # for notifications
    if [ ! $(type -t _rabbit_rpc_backend_add_vhost) ]; then
        rpc_backend_add_vhost_definition=$(declare -f rpc_backend_add_vhost)
        eval "_rabbit_rpc_backend_add_vhost() ${rpc_backend_add_vhost_definition#*\()}"
        export -f _rabbit_rpc_backend_add_vhost
    fi

    # export the overridden functions
    function iniset_rpc_backend {
        _iniset_amqp1_backend $@
    }
    export -f iniset_rpc_backend

    function get_transport_url {
        _get_amqp1_default_transport_url $@
    }
    export -f get_transport_url

    function get_notification_url {
        _get_amqp1_notify_transport_url $@
    }
    export -f get_notification_url

    function rpc_backend_add_vhost {
        _amqp1_add_vhost $@
    }
    export -f rpc_backend_add_vhost

    if [[ "$1" == "stack" && "$2" == "pre-install" ]]; then
        # nothing needed here
        :

    elif [[ "$1" == "stack" && "$2" == "install" ]]; then
        # Installs and configures the messaging service
        echo_summary "Installing AMQP service $AMQP1_SERVICE"
        _install_amqp1_backend

    elif [[ "$1" == "stack" && "$2" == "post-config" ]]; then
        # Start the messaging service process, this happens before any
        # services start
        _start_amqp1_backend

    elif [[ "$1" == "stack" && "$2" == "extra" ]]; then
        :
    fi

    if [[ "$1" == "unstack" ]]; then
        :
    fi

    if [[ "$1" == "clean" ]]; then
        # Remove state and transient data
        # Remember clean.sh first calls unstack.sh
        _cleanup_amqp1_backend
    fi
fi


# Tell emacs to use shell-script-mode
## Local variables:
## mode: shell-script
## End:
