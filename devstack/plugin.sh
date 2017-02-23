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
# AMQP1_SERVICE - identifies the messaging backend to use.  Should be
#    one of 'qpid' for broker backend, 'qpid-dual' for hybrid router-broker, or
#    'qpid-hybrid' for keeping Rabbit for notifcations.
#    @TODO(kgiusti) add qpid-dispatch, etc
# AMQP1_HOST - the host used to connect to the messaging service.
#    Defaults to 127.0.0.1
# AMQP1_{DEFAULT_PORT, NOTIFY_PORT} - the port used to connect to the messaging
#    service. Defaults to 5672 and 5671.
# AMQP1_{USERNAME,PASSWORD} - for authentication with AMQP1_HOST
#

# builds default transport url string
function _get_amqp1_default_transport_url {
    if [ -z "$AMQP1_USERNAME" ]; then
        echo "amqp://$AMQP1_HOST:${AMQP1_DEFAULT_PORT}/"
    else
        echo "amqp://$AMQP1_USERNAME:$AMQP1_PASSWORD@$AMQP1_HOST:${AMQP1_DEFAULT_PORT}/"
    fi
}

# builds notify transport url string
function _get_amqp1_notify_transport_url {
    if [ -z "$AMQP1_USERNAME" ]; then
        echo "amqp://$AMQP1_HOST:${AMQP1_NOTIFY_PORT}/"
    else
        echo "amqp://$AMQP1_USERNAME:$AMQP1_PASSWORD@$AMQP1_HOST:${AMQP1_NOTIFY_PORT}/"
    fi
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
        install_package python-qpid-proton
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
    local qpid_acl_file=/etc/qpid/qpidd.acl
    if [ ! -e $qpid_acl_file ]; then
        sudo mkdir -p -m 755 `dirname $qpid_acl_file`
        sudo touch $qpid_acl_file
        sudo chmod o+r $qpid_acl_file
    fi
    echo "acl-file=$qpid_acl_file" | sudo tee $qpid_conf_file

    # map broker port for dual backend config
    if [ "$AMQP1_SERVICE" == "qpid-dual" ]; then
        echo "port=${AMQP1_NOTIFY_PORT}" | sudo tee --append $qpid_conf_file
    fi

    if [ -z "$AMQP1_USERNAME" ]; then
        # no QPID user configured, so disable authentication
        # and access control
        echo "auth=no" | sudo tee --append $qpid_conf_file
        cat <<EOF | sudo tee $qpid_acl_file
acl allow all all
EOF
    else
        # Configure qpidd to use PLAIN authentication, and add
        # AMQP1_USERNAME to the ACL:
        echo "auth=yes" | sudo tee --append $qpid_conf_file
        if [ -z "$AMQP1_PASSWORD" ]; then
            read_password AMQP1_PASSWORD "ENTER A PASSWORD FOR QPID USER $AMQP1_USERNAME"
        fi
        # Create ACL to allow $AMQP1_USERNAME full access
        cat <<EOF | sudo tee $qpid_acl_file
group admin ${AMQP1_USERNAME}@QPID
acl allow admin all
acl deny all all
EOF
        # Add user to SASL database
        local sasl_conf_file=/etc/sasl2/qpidd.conf
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
        echo $AMQP1_PASSWORD | sudo saslpasswd2 -c -p -f $sasl_db -u QPID $AMQP1_USERNAME
        sudo chmod o+r $sasl_db
    fi

    # Ensure that the version of the broker can support AMQP 1.0 and
    # configure the queue and topic address patterns used by
    # oslo.messaging.
    QPIDD=$(type -p qpidd)
    if ! $QPIDD --help | grep -q "queue-patterns"; then
        exit_distro_not_supported "qpidd with AMQP 1.0 support"
    fi
    local log_file=$LOGDIR/qpidd.log
    cat <<EOF | sudo tee --append $qpid_conf_file
queue-patterns=exclusive
queue-patterns=unicast
topic-patterns=broadcast
log-enable=info+
log-to-file=$log_file
log-to-syslog=yes
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
    debugDump: /opt/stack/amqp1
}

EOF

    # Create a listener for incoming connect to the router
    cat <<EOF | sudo tee --append $qdr_conf_file
listener {
    addr: 0.0.0.0
    port: ${AMQP1_DEFAULT_PORT}
    role: normal
EOF
    if [ -z "$AMQP1_USERNAME" ]; then
        #no user configured, so disable authentication
        cat <<EOF | sudo tee --append $qdr_conf_file
    authenticatePeer: no
}

EOF
    else
        # configure to use PLAIN authentication
        if [ -z "$AMQP1_PASSWORD" ]; then
            read_password AMQP1_PASSWORD "ENTER A PASSWORD FOR QPID DISPATCH USER $AMQP1_USERNAME"
        fi
        cat <<EOF | sudo tee --append $qdr_conf_file
    authenticatePeer: yes
}

EOF
        # Add user to SASL database
        local sasl_conf_file=/etc/sasl2/qdrouterd.conf
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
        echo $AMQP1_PASSWORD | sudo saslpasswd2 -c -p -f $sasl_db $AMQP1_USERNAME
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

    local log_file=$LOGDIR/qdrouterd.log

    sudo touch $log_file
    sudo chmod a+rw $log_file  # qdrouterd user can write to it

    # Create log file configuration
    cat <<EOF | sudo tee --append $qdr_conf_file
log {
    module: DEFAULT
    enable: info+
    output: $log_file
}

EOF

}


# install and configure the amqp1 backends
# (qpidd broker and optionally dispatch-router for hybrid)
function _install_amqp1_backend {

    if is_fedora; then
        # expects epel is already added to the yum repos
        install_package cyrus-sasl-lib
        install_package cyrus-sasl-plain
        if [ "$AMQP1_SERVICE" != "qpid-hybrid" ]; then
            install_package qpid-cpp-server
        fi
        if [ "$AMQP1_SERVICE" != "qpid" ]; then
            install_package qpid-dispatch-router
        fi
    elif is_ubuntu; then
        install_package sasl2-bin
        # newer qpidd and proton only available via the qpid PPA
        sudo add-apt-repository -y ppa:qpid/testing
        #sudo apt-get update
        REPOS_UPDATED=False
        update_package_repo
        if [ "$AMQP1_SERVICE" != "qpid-hybrid" ]; then
            install_package qpidd
        fi
        if [ "$AMQP1_SERVICE" != "qpid" ]; then
            install_package qdrouterd
        fi
    else
        exit_distro_not_supported "amqp1 qpid installation"
    fi

    _install_pyngus
    if [ "$AMQP1_SERVICE" != "qpid-hybrid" ]; then
        _configure_qpid
    fi
    if [ "$AMQP1_SERVICE" != "qpid" ]; then
        _configure_qdr
    fi
}


function _start_amqp1_backend {
    echo_summary "Starting amqp1 backends"
    # restart, since qpid* may already be running
    if [ "$AMQP1_SERVICE" != "qpid-hybrid" ]; then
        restart_service qpidd
    fi
    if [ "$AMQP1_SERVICE" != "qpid" ]; then
        restart_service qdrouterd
    fi
}


function _cleanup_amqp1_backend {
    if is_fedora; then
        if [ "$AMQP1_SERVICE" != "qpid-hybrid" ]; then
            uninstall_package qpid-cpp-server
        fi
        if [ "$AMQP1_SERVICE" != "qpid" ]; then
            uninstall_package qpid-dispatch-router
        fi
        # TODO(kgiusti) can we pull these, or will that break other
        # packages that depend on them?

        # install_package cyrus_sasl_lib
        # install_package cyrus_sasl_plain
    elif is_ubuntu; then
        if [ "$AMQP1_SERVICE" != "qpid-hybrid" ]; then
            uninstall_package qpidd
        fi
        if [ "$AMQP1_SERVICE" != "qpid" ]; then
            uninstall_package qdrouterd
        fi
        # install_package sasl2-bin
    else
        exit_distro_not_supported "amqp1 qpid installation"
    fi

    _remove_pyngus
}


# iniset configuration for amqp rpc_backend
function _iniset_amqp1_backend {
    local package=$1
    local file=$2
    local section=${3:-DEFAULT}

    if [ "$AMQP1_SERVICE" == "qpid-dual" ]; then
        iniset $file $section transport_url $(get_transport_url)
        iniset $file oslo_messaging_notifications transport_url $(_get_amqp1_notify_transport_url)
    elif [ "$AMQP1_SERVICE" == "qpid-hybrid" ]; then
        iniset $file $section transport_url $(get_transport_url)
        iniset $file oslo_messaging_notifications transport_url $(_get_rabbit_transport_url)
    else
        iniset $file $section transport_url $(get_transport_url)
    fi
}


if is_service_enabled amqp1; then
    # @TODO (ansmith) check is for qdr or qpid for now
    if [[ "$AMQP1_SERVICE" != "qpid" && "$AMQP1_SERVICE" != "qpid-dual" && "$AMQP1_SERVICE" != "qpid-hybrid" ]]; then
        die $LINENO "AMQP 1.0 requires qpid, qpid-dual or qpid-hybrid - $AMQP1_SERVICE not supported"
    fi

    # Save rabbit get_transport_url for notifications if necessary
    get_transport_url_definition=$(declare -f get_transport_url)
    eval "_get_rabbit_transport_url() ${get_transport_url_definition#*\()}"
    export -f _get_rabbit_transport_url

    # Note: this is the only tricky part about out of tree rpc plugins,
    # you must overwrite the iniset_rpc_backend function so that when
    # that's passed around the correct settings files are made.
    function iniset_rpc_backend {
        _iniset_amqp1_backend $@
    }
    function get_transport_url {
        _get_amqp1_default_transport_url $@
    }
    export -f iniset_rpc_backend
    export -f get_transport_url
fi


# check for amqp1 service
if is_service_enabled amqp1; then

    if [ "$AMQP1_SERVICE" != "qpid-hybrid" ]; then
        available_port=5672
    else
        available_port=15672
    fi

    AMQP1_DEFAULT_PORT=${AMQP1_DEFAULT_PORT:=$available_port}
    AMQP1_NOTIFY_PORT=${AMQP1_NOTIFY_PORT:=5671}

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
