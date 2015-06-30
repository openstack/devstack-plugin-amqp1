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
#    one of 'qpid', ...
#    @TODO(kgiusti) add qpid-dispatch, rabbitmq, etc
# AMQP1_HOST - the host:port used to connect to the messaging service.
#    Defaults to 127.0.0.1:5672
# AMQP1_{USERNAME,PASSWORD} - for authentication with AMQP1_HOST
#

# Save trace setting
XTRACE=$(set +o | grep xtrace)
set +o xtrace

# builds transport url string
function _get_amqp1_transport_url {
    echo "amqp://$AMQP1_USERNAME:$AMQP1_PASSWORD@$AMQP1_HOST:5672/"
}


# install packages necessary for support of the oslo.messaging AMQP
# 1.0 driver
function _install_pyngus {
    # Install pyngus client API
    pip_install_gr pyngus
}


# remove packages used by oslo.messaging AMQP 1.0 driver
function _remove_pyngus {
    # TODO(kgiusti) no way to pip uninstall?
    # pip_install_gr pyngus
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

    # force the ACL file to a known location
    local qpid_acl_file=/etc/qpid/qpidd.acl
    if [ ! -e $qpid_acl_file ]; then
        sudo mkdir -p -m 755 `dirname $qpid_acl_file`
        sudo touch $qpid_acl_file
        sudo chmod o+r $qpid_acl_file
    fi
    sudo sed -i.bak '/^acl-file=/d' $qpid_conf_file
    echo "acl-file=$qpid_acl_file" | sudo tee --append $qpid_conf_file

    sudo sed -i '/^auth=/d' $qpid_conf_file
    if [ -z "$QPID_USERNAME" ]; then
        # no QPID user configured, so disable authentication
        # and access control
        echo "auth=no" | sudo tee --append $qpid_conf_file
        cat <<EOF | sudo tee $qpid_acl_file
acl allow all all
EOF
    else
        # Configure qpidd to use PLAIN authentication, and add
        # QPID_USERNAME to the ACL:
        echo "auth=yes" | sudo tee --append $qpid_conf_file
        if [ -z "$QPID_PASSWORD" ]; then
            read_password QPID_PASSWORD "ENTER A PASSWORD FOR QPID USER $QPID_USERNAME"
        fi
        # Create ACL to allow $QPID_USERNAME full access
        cat <<EOF | sudo tee $qpid_acl_file
group admin ${QPID_USERNAME}@QPID
acl allow admin all
acl deny all all
EOF
        # Add user to SASL database
        local sasl_conf_file=/etc/sasl2/qpidd.conf
        sudo sed -i.bak '/PLAIN/!s/mech_list: /mech_list: PLAIN /' $sasl_conf_file
        local sasl_db=`sudo grep sasldb_path $sasl_conf_file | cut -f 2 -d ":" | tr -d [:blank:]`
        if [ ! -e $sasl_db ]; then
            sudo mkdir -p -m 755 `dirname $sasl_db`
        fi
        echo $QPID_PASSWORD | sudo saslpasswd2 -c -p -f $sasl_db -u QPID $QPID_USERNAME
        sudo chmod o+r $sasl_db
    fi

    # Ensure that the version of the broker can support AMQP 1.0 and
    # configure the queue and topic address patterns used by
    # oslo.messaging.
    QPIDD=$(type -p qpidd)
    if ! $QPIDD --help | grep -q "queue-patterns"; then
        exit_distro_not_supported "qpidd with AMQP 1.0 support"
    fi
    if ! grep -q "queue-patterns=exclusive" $qpid_conf_file; then
        cat <<EOF | sudo tee --append $qpid_conf_file
queue-patterns=exclusive
queue-patterns=unicast
topic-patterns=broadcast
EOF
    fi
}


# install and configure the qpidd broker
function _install_qpid_backend {

    if is_fedora; then
        # expects epel is already added to the yum repos
        install_package cyrus-sasl-lib
        install_package cyrus-sasl-plain
        install_package qpid-cpp-server
    elif is_ubuntu; then
        install_package sasl2-bin
        # newer qpidd and proton only available via the qpid PPA
        sudo add-apt-repository ppa:qpid/testing
        sudo apt-get update
        install_package qpidd
    else
        exit_distro_not_supported "qpidd installation"
    fi

    _install_pyngus
    _configure_qpid
}


function _start_qpid_backend {
    echo_summary "Starting qpidd broker"
    start_service qpidd
}


function _cleanup_qpid_backend {
    if is_fedora; then
        uninstall_package qpid-cpp-server
	# TODO(kgiusti) can we pull these, or will that break other
	# packages that depend on them?
	
        # install_package cyrus_sasl_lib
        # install_package cyrus_sasl_plain
    elif is_ubuntu; then
        uninstall_package qpidd
        # install_package sasl2-bin
    else
        exit_distro_not_supported "qpid installation"
    fi

    _uninstall_pyngus
}


# iniset configuration for qpid
function _iniset_qpid_backend {
    local package=$1
    local file=$2
    local section=${3:-DEFAULT}

    iniset $file $section rpc_backend "amqp"
    # @TODO(kgiusti) why is "qpid_" part of the setting's name?  Why isn't this generic??
    iniset $file $section qpid_hostname ${AMQP1_HOST}
    if [ -n "$AMQP1_USERNAME" ]; then
	iniset $file $section qpid_username $AMQP1_USERNAME
	iniset $file $section qpid_password $AMQP1_PASSWORD
    fi
}


if is_service_enabled amqp1; then
    # @TODO(kgiusti) hardcode qpid for now, add other service
    # types as support is provided
    if [ "$AMQP1_SERVICE" != "qpid" ]; then
        die $LINENO "AMQP 1.0 requires qpid - $AMQP1_SERVICE not supported"
    fi

    # Note: this is the only tricky part about out of tree rpc plugins,
    # you must overwrite the iniset_rpc_backend function so that when
    # that's passed around the correct settings files are made.
    function iniset_rpc_backend {
        _iniset_${AMQP1_SERVICE}_backend $@
    }
    function get_transport_url {
        _get_amqp1_transport_url $@
    }
    export -f iniset_rpc_backend
    export -f get_transport_url
fi


# check for amqp1 service
if is_service_enabled amqp1; then
    if [[ "$1" == "stack" && "$2" == "pre-install" ]]; then
        # nothing needed here
        :

    elif [[ "$1" == "stack" && "$2" == "install" ]]; then
        # Installs and configures the messaging service
        echo_summary "Installing AMQP service $AMQP1_SERVICE"
        _install_${AMQP1_SERVICE}_backend

    elif [[ "$1" == "stack" && "$2" == "post-config" ]]; then
        # Start the messaging service process, this happens before any
        # services start
        _start_${AMQP1_SERVICE}_backend

    elif [[ "$1" == "stack" && "$2" == "extra" ]]; then
        :
    fi

    if [[ "$1" == "unstack" ]]; then
        :
    fi

    if [[ "$1" == "clean" ]]; then
        # Remove state and transient data
        # Remember clean.sh first calls unstack.sh
        _uninstall_${AMQP1_SERVICE}_backend
    fi
fi


# Restore xtrace
$XTRACE


# Tell emacs to use shell-script-mode
## Local variables:
## mode: shell-script
## End:
