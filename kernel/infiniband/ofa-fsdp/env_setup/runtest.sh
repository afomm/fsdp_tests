#!/bin/bash -x
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /kernel/infiniband/ofa-fsdp/env_setup
#   Description: prepare RDMA cluster test environment
#   Author: Afom Michael <tmichael@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2020 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
trap "rm -f /mnt/testarea/env_setup-run_number.log; exit 1" SIGHUP SIGINT SIGQUIT SIGTERM

export result="PASS"
export test_base="$(pwd)"
export s_hostname=$(hostname -s)
export host_json="${test_base}/json/${s_hostname}.json"
__bashrc_source=0
__json_state=0

# link ./rdma-qa-functions.sh
ln -s ${test_base}/rdma-qa-functions.sh ${HOME}/rdma-qa-functions.sh

# install wget
which wget || yum -y install wget

# Source the common test script helpers
source /usr/bin/rhts_environment.sh
source env_setup_functions.sh

# let's make sure rdma-setup.sh was executed before
_rdma_setup="/root/fsdp_setup/rdma-setup.sh"
if [[ ! -e $_rdma_setup ]]; then
    run_rdma_setup
fi

# Location of bashrc file to export env_setup variables from
export BASHRC_FILE="${HOME}/.bashrc"

RQA_pkg_install dmidecode lshw environment-modules python3

function common_setup {
    # run common_setup to parse the inventory files based on hostname

    # Init a parsed_FILE for host variables output by JSON parser
    export parsed_FILE=${HOME}/json_parse_out.txt
    rm -f "$parsed_FILE"

    # determine if ENV_NETWORK and ENV_DRIVER were specified
    RDMA_DRIVER=""
    RDMA_NETWORK=""
    if [[ ! -z $ENV_DRIVER  ]]; then RDMA_DRIVER="$ENV_DRIVER"  ; fi
    if [[ ! -z $ENV_NETWORK ]]; then RDMA_NETWORK="$ENV_NETWORK"; fi

    # make sure inventory file exists
    if [[ ! -f $host_json ]]; then
        echo "Try to generate $host_json ..."
        bash ./create_hca_json.sh
        local __generate_json=$?
        if [[ $__generate_json -ne 0 ]]; then
            echo "Failed to generate $host_json"
	    echo "host can't be properly configured with $host_json"
	    echo "Exiting..."
            exit $__generate_json
        fi
    fi

    # We use roce.45 rather than roce
    if [[ $ENV_NETWORK == "roce" ]]; then
        ENV_NETWORK="${ENV_NETWORK}.45"
    fi

    RDMA_DRIVER=$(RQA_get_driver_name $RDMA_DRIVER)

    # run the JSON parser for this host
    $PYEXEC ./host_data_parser.py "$host_json" "${RDMA_DRIVER}" \
            "${RDMA_NETWORK}" | tee $parsed_FILE
    local __json_state=$?

    RQA_check_result -r  $__json_state -t "JSON parser"
    if [[ $__json_state -ne 0 ]]; then
        echo "JSON Parser failed probably because a combination of"
        echo "ENV_DRIVER + ENV_NETWORK pair was not found for this host"
        echo "Exiting ..."
        RQA_check_result -r 1 -t "Combination of ENV_DRIVER + ENV_NETWORK pair"
        exit $__json_state
    elif [[ $__json_state -eq 0 ]]; then
        # source the output file generated by the parser
        source "$parsed_FILE"

        # assign IPv4 and IPv6 variables
        [[ ! -z $DEVICE_ID ]] && [[ -z "$RDMA_IPV4" ]] && RDMA_IPV4=$(RQA_get_my_ipv4 $DEVICE_ID)
        [[ ! -z $DEVICE_ID ]] && RDMA_IPV6=$(RQA_get_my_ipv6 $DEVICE_ID)

        # if this is SIW or RXE test on LOM_2 device,
        # make sure that the link-local IPv6 gets set for IPv6 address
        if [[ ( "$RDMA_DRIVER" == "siw" || "$RDMA_DRIVER" == "rxe" ) && "$RDMA_NETWORK" == "eth" ]]; then
            [[ $(echo $RDMA_IPV6 | wc | awk '{print $2}') -gt 1 ]] &&
            RDMA_IPV6=$(echo $RDMA_IPV6 | sed -r -n 's/[a-z0-9:]+\s(fe80::.*)/\1/p')
        fi

        # ping the IPv4 to ensure the network is actually available
        ping -c 3 $RDMA_IPV4
        RQA_check_result -r $? -t "ping $RDMA_IPV4"

        # add the IPv4 and IPv6 variables to .bashrc
        grep "RDMA_IPV4=\"172.31." $parsed_FILE
        if [[ $? -ne 0 ]]; then
            echo "export RDMA_IPV4=\"${RDMA_IPV4}\"" >> $parsed_FILE
        fi
        echo "export RDMA_IPV6=\"${RDMA_IPV6}\"" >> $parsed_FILE
    fi

    echo -en "\n# /kernel/infiniband/ofa-fsdp/env_setup variables\n" >> $BASHRC_FILE
    if [[ -s $parsed_FILE ]] && grep "export" $parsed_FILE >/dev/null; then
        cat >> $BASHRC_FILE < $parsed_FILE
    fi

    # source the .bashrc again
    source $BASHRC_FILE 1>/dev/null 2>&1
    ((__bashrc_source + $?))
}

# called by the client on a multi-host test setup
function client {

    # sync the client + server
    rhts_sync_set -s "ES_CLIENT_READY_${TNAME}-${ENV_NETWORK}-${RUN_NUMBER}"
    rhts_sync_block -s "ES_SERVER_READY_${TNAME}-${ENV_NETWORK}-${RUN_NUMBER}" ${SERVERS}

    # wait for server's signal to start
    rhts_sync_block -s "ES_SERVER_DONE_${TNAME}-${ENV_NETWORK}-${RUN_NUMBER}" ${SERVERS}

    # get server-specific variables
    srv_ssh=$(echo $SERVERS | awk -F '.' '{print $1}')
    SERVER_DRIVER=$(ssh ${srv_ssh} echo '${RDMA_DRIVER}')
    SERVER_NETWORK=$(ssh ${srv_ssh} echo '${RDMA_NETWORK}')
    SERVER_HCA_ID=$(ssh ${srv_ssh} echo '${HCA_ID}')
    SERVER_HCA_ABRV=$(ssh ${srv_ssh} echo '${HCA_ABRV}')
    SERVER_DEVICE_ID=$(ssh ${srv_ssh} echo '${DEVICE_ID}')
    SERVER_DEVICE_MAC=$(ssh ${srv_ssh} echo '${DEVICE_MAC}')
    SERVER_DEVICE_PORT=$(ssh ${srv_ssh} echo '${DEVICE_PORT}')
    SERVER_PORT_GUID=$(ssh ${srv_ssh} echo '${PORT_GUID}')
    SERVER_IPV4=$(ssh ${srv_ssh} echo '${RDMA_IPV4}')
    SERVER_IPV6=$(ssh ${srv_ssh} echo '${RDMA_IPV6}')

    # check if any of the above variables did not set
    if [[ -z $SERVER_DRIVER || -z $SERVER_NETWORK \
       || -z $SERVER_HCA_ID || -z $SERVER_HCA_ABRV \
       || -z $SERVER_DEVICE_ID || -z $SERVER_DEVICE_MAC \
       || -z $SERVER_DEVICE_PORT ||  -z $SERVER_PORT_GUID \
       || -z $SERVER_IPV4 || -z $SERVER_IPV6 ]]; then
        RQA_check_result -r 1 -t "client gets server variables"
    fi

    # write client and server variables to .bashrc
    {
        echo "export CLIENT_DRIVER=\"${RDMA_DRIVER}\""
        echo "export CLIENT_NETWORK=\"${RDMA_NETWORK}\""
        echo "export CLIENT_HCA_ID=\"${HCA_ID}\""
        echo "export CLIENT_HCA_ABRV=\"${HCA_ABRV}\""
        echo "export CLIENT_DEVICE_ID=\"${DEVICE_ID}\""
        echo "export CLIENT_DEVICE_MAC=\"${DEVICE_MAC}\""
        echo "export CLIENT_DEVICE_PORT=\"${DEVICE_PORT}\""
        echo "export CLIENT_PORT_GUID=\"${PORT_GUID}\""
        echo "export CLIENT_IPV4=\"${RDMA_IPV4}\""
        echo "export CLIENT_IPV6=\"${RDMA_IPV6}\""
        echo "export SERVER_DRIVER=\"${SERVER_DRIVER}\""
        echo "export SERVER_NETWORK=\"${SERVER_NETWORK}\""
        echo "export SERVER_HCA_ID=\"${SERVER_HCA_ID}\""
        echo "export SERVER_HCA_ABRV=\"${SERVER_HCA_ABRV}\""
        echo "export SERVER_DEVICE_ID=\"${SERVER_DEVICE_ID}\""
        echo "export SERVER_DEVICE_MAC=\"${SERVER_DEVICE_MAC}\""
        echo "export SERVER_DEVICE_PORT=\"${SERVER_DEVICE_PORT}\""
        echo "export SERVER_PORT_GUID=\"${SERVER_PORT_GUID}\""
        echo "export SERVER_IPV4=\"${SERVER_IPV4}\""
        echo "export SERVER_IPV6=\"${SERVER_IPV6}\""
        echo "export REMOTE_HOST=\"${srv_ssh}\""
    } >> "$BASHRC_FILE"

    # source the .bashrc again
    source "$BASHRC_FILE" 1>/dev/null 2>&1
    ((__bashrc_source + $?))

    # finish client side steps
    echo '--- client finishes.'
    rhts_sync_set -s "ES_CLIENT_DONE_${TNAME}-${ENV_NETWORK}-${RUN_NUMBER}"
}

# called by the server on a multi-host test setup
function server {

    # sync the client + server
    rhts_sync_block -s "ES_CLIENT_READY_${TNAME}-${ENV_NETWORK}-${RUN_NUMBER}" ${CLIENTS}
    rhts_sync_set -s "ES_SERVER_READY_${TNAME}-${ENV_NETWORK}-${RUN_NUMBER}"

    # get client-specific variables
    cli_ssh=$(echo $CLIENTS | awk -F '.' '{print $1}')
    CLIENT_DRIVER=$(ssh ${cli_ssh} echo '${RDMA_DRIVER}')
    CLIENT_NETWORK=$(ssh ${cli_ssh} echo '${RDMA_NETWORK}')
    CLIENT_HCA_ID=$(ssh ${cli_ssh} echo '${HCA_ID}')
    CLIENT_HCA_ABRV=$(ssh ${cli_ssh} echo '${HCA_ABRV}')
    CLIENT_DEVICE_ID=$(ssh ${cli_ssh} echo '${DEVICE_ID}')
    CLIENT_DEVICE_MAC=$(ssh ${cli_ssh} echo '${DEVICE_MAC}')
    CLIENT_DEVICE_PORT=$(ssh ${cli_ssh} echo '${DEVICE_PORT}')
    CLIENT_PORT_GUID=$(ssh ${cli_ssh} echo '${PORT_GUID}')
    CLIENT_IPV4=$(ssh ${cli_ssh} echo '${RDMA_IPV4}')
    CLIENT_IPV6=$(ssh ${cli_ssh} echo '${RDMA_IPV6}')

    # check if any of the above variables did not set
    if [[ -z $CLIENT_DRIVER || -z $CLIENT_NETWORK \
       || -z $CLIENT_HCA_ID || -z $CLIENT_HCA_ABRV \
       || -z $CLIENT_DEVICE_ID || -z $CLIENT_DEVICE_MAC \
       || -z $CLIENT_DEVICE_PORT || -z $CLIENT_PORT_GUID \
       || -z $CLIENT_IPV4 || -z $CLIENT_IPV6 ]]; then
        RQA_check_result -r 1 -t "server gets client variables"
    fi

    # write server and client variables to .bashrc
    {
        echo "export CLIENT_DRIVER=\"${CLIENT_DRIVER}\""
        echo "export CLIENT_NETWORK=\"${CLIENT_NETWORK}\""
        echo "export CLIENT_HCA_ID=\"${CLIENT_HCA_ID}\""
        echo "export CLIENT_HCA_ABRV=\"${CLIENT_HCA_ABRV}\""
        echo "export CLIENT_DEVICE_ID=\"${CLIENT_DEVICE_ID}\""
        echo "export CLIENT_DEVICE_MAC=\"${CLIENT_DEVICE_MAC}\""
        echo "export CLIENT_DEVICE_PORT=\"${CLIENT_DEVICE_PORT}\""
        echo "export CLIENT_PORT_GUID=\"${CLIENT_PORT_GUID}\""
        echo "export CLIENT_IPV4=\"${CLIENT_IPV4}\""
        echo "export CLIENT_IPV6=\"${CLIENT_IPV6}\""
        echo "export SERVER_DRIVER=\"${RDMA_DRIVER}\""
        echo "export SERVER_NETWORK=\"${RDMA_NETWORK}\""
        echo "export SERVER_HCA_ID=\"${HCA_ID}\""
        echo "export SERVER_HCA_ABRV=\"${HCA_ABRV}\""
        echo "export SERVER_DEVICE_ID=\"${DEVICE_ID}\""
        echo "export SERVER_DEVICE_MAC=\"${DEVICE_MAC}\""
        echo "export SERVER_DEVICE_PORT=\"${DEVICE_PORT}\""
        echo "export SERVER_PORT_GUID=\"${PORT_GUID}\""
        echo "export SERVER_IPV4=\"${RDMA_IPV4}\""
        echo "export SERVER_IPV6=\"${RDMA_IPV6}\""
        echo "export REMOTE_HOST=\"${cli_ssh}\""
    } >> "$BASHRC_FILE"

    # source the .bashrc again
    source "$BASHRC_FILE" 1>/dev/null 2>&1
    ((__bashrc_source + $?))

    # signal the client to start
    rhts_sync_set -s "ES_SERVER_DONE_${TNAME}-${ENV_NETWORK}-${RUN_NUMBER}"

    # wait for client to finish
    echo '--- server finishes.'
    rhts_sync_block -s "ES_CLIENT_DONE_${TNAME}-${ENV_NETWORK}-${RUN_NUMBER}" ${CLIENTS}
}

RQA_set_servers_clients

if [[ "$(hostname -s)" == "${CLIENTS%%}" ]]; then
    tftp_service_sync "${CLIENTS}" "${SERVERS}"
elif [[ "$(hostname -s)" == "${SERVERS%%}" ]]; then
    tftp_service_sync "${SERVERS}" "${CLIENTS}"
fi

RQA_rhts_or_dev_mode multi env
RQA_set_pyexec

# if json looks wrong, delete it so we can re-try to populate it
if [[ -e $host_json ]]; then
    jq '.' $host_json
    __json_state=$?
    if [[ $__json_state -ne 0 ]]; then
        rm -f $host_json
    fi
fi

# decide if we're running on RHTS or in developer mode
# NOTE: if running this test case manually, it will assume singlehost mode
#       unless you specify both CLIENTS=<host1> SERVERS=<host2> make run
if [[ -z "$CLIENTS" && -z "$SERVERS" ]]; then
    echo "Running in a single mode"
    RQA_rhts_or_dev_mode single env
    common_setup
else
    echo "Running in a multihost mode"
    common_setup
    # if this is a multihost case, run client/server setup
    if hostname -A | grep ${CLIENTS%%.*} >/dev/null ; then
        echo "------- client start test -------"
        client
    elif hostname -A | grep ${SERVERS%%.*} >/dev/null ; then
        echo "------- server start test -------"
        server
    fi
fi

RQA_check_result -r $__bashrc_source -t "Source ${HOME}/.bashrc"

# report result
RQA_overall_result

rm -f ${RUN_NUMBER_LOG} /mnt/testarea/env_setup-run_number.log
unset RUN_NUMBER TNAME

echo "------ end of env_setup runtest.sh ------"
exit 0
