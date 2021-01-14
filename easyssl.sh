#!/bin/bash

# prevent timestamps collisions
sleep 0.1

# === CONSTANTS ===
grn=$'\e[1;32m'
blu=$'\e[1;34m'
end=$'\e[0m'

TIME=$(date +%s)
SCRIPT_PATH="$(realpath "$0")"
EASYSSL_DIR="$(dirname "${SCRIPT_PATH}")"
UTILITY_SCRIPT="${EASYSSL_DIR}/bin/utility.sh"
CHAINS_DIR=${EASYSSL_DIR}/chains
CHAINS_FILE=${CHAINS_DIR}/.chains

VALIDITY=365
SIZE=4096
MD=sha256
AUTODN_CONF_NAME="autodn.properties"
ENVIRONMENT_CONF_NAME="environment.properties"
OPENSSL_CONF_NAME="openssl.cnf"
CAROOT_EXTENSION="ca_root_ext"
INTERMEDIATE_EXTENSION="ca_intermediate_ext"

# === GLOBAL VARS ===
chain_name="chain_${TIME}"
chain_dir="${CHAINS_DIR}/${chain_name}"
ca_root_name="ca_root"
ca_intermediate_name="ca_intermediate"
node_name="node"
node_issuer_dir=""

# === ARGUMENTS ===
arg_do_root="False"
arg_do_intermediate="False"
arg_do_node="False"
arg_extension="None"
arg_issuer="None"
arg_name="None"
arg_san="localhost"

# shellcheck source=/dev/null
source "${EASYSSL_DIR}/bin/utility.sh"

# === USAGE ===

usage() {
    # shellcheck disable=SC2059
    printf "${blu}Overview :${end}

  This script creates a CA with root, intermediate signing ca and nodes certificates.
  Every certificate is signed by the same generated intermediate CA.
  All of the nodes certificates share the same hostname information : 'localhost' by default
  You can override the hostname of the certificates with : '--hostname [hostname]'.
  The nodes certificates can be used for server-side, client-side or both purposes with : '--server', '--client' or '--super'.
  All of the generated private keys share the PKCS8 standard format.
  To change the issuer of the certificates, use '--issuer' and point to the directory containing the openssl configuration of the issuer.

  ${blu}Usage :${end}
  ./easyssl.sh [Mandatory: purpose] [Optional: options] | [utility]

  ${grn}[ purpose ]${end}
  --root\t\tOnly Generate root CA
  --intermediate\tGenerate a root CA and an intermediate signing CA
  --server [number]\tGenerate server-side certs with CA
  --client [number]\tGenerate client-side certs with CA
  --super [number]\tGenerate both server-side and client-side certs with CA

  ${grn}[ options ]${end}
  --name [name]\t\tChange filenames and the common name (CN).
  --san [host,ip..]\tAdd Subject Alternative Names for the generated certs. Default is 'localhost'. Eg: '--san 192.168.0.1,server1'
  --issuer [folder]\tGenerate certs using the provided CA. The folder MUST contain an openssl configuration file and a 'certs' folder containing the CA certificate. The path MUST be absolute.

  ${grn}[ utility ]${end}
  -h,--help\t\tDisplay this
  -p,--purge\t\tRemove all generated chains
  -s,--subject [path]\tDisplay the subject of the provided cert
  -e,--extract [path]\tExtract all certs of all chains inside the provided absolute path

  ${blu}Examples :${end}
  - Create certs for server-side and client-side purpose:
  ./easyssl.sh --super

  - Create an intermediate CA and generate server and client keys signed by this CA :
  ./easyssl.sh --intermediate --name myCA
  ./easyssl.sh --server --issuer /home/user/easyssl/chains/myCA/ca_intermediate
  ./easyssl.sh --client --issuer /home/user/easyssl/chains/myCA/ca_intermediate

  - Add SAN to the generated certificate :
  ./easyssl.sh --server --san 192.168.0.1,server1
  "
}

# === FUNCTIONS ===

# Remove all dirs referenced inside the file .chains
purgeDirs() {
    log_red "## REMOVE CHAINS ##"
    # purge chains
    if [ -f "${CHAINS_FILE}" ]; then
        chains=$(cat "${CHAINS_FILE}")
        for chain in $chains; do
            rm -rf "$chain"
            printf ". Removed %s\n" "${chain}"
        done
        rm "${CHAINS_FILE}"
    fi
}

# Change the Common Name of the generated certificates
# Change the name of the generated files
# arg1: name of the generated chain
function configureName() {
    chain_name="$1_${TIME}"
    chain_dir="${CHAINS_DIR}/${chain_name}"
     
    ca_root_name="$1_root"
    ca_intermediate_name="$1_intermediate"   
    node_name="$1"
}

function configureNodeIssuer() {
    if [ "${arg_issuer}" != "None" ];then
      node_issuer_dir="${arg_issuer}"
    else
      node_issuer_dir="${chain_dir}/${ca_intermediate_name}"
    fi
}

# params
# arg1: openssl config file path
function configureDNS() {
    if [ "${arg_san}" != "localhost" ]; then
        IFS=',' read -ra ADDR <<<"${arg_san}"
        san_placeholder="#{{more_san}}"
        count_san_ip=2
        count_san_host=2
        for i in "${ADDR[@]}"; do
            if [[ $i =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                # for ip address
                sed -i "s+${san_placeholder}+IP\.${count_san_ip} = ${i}\n${san_placeholder}+g" "$1"
                count_san_ip=$((count_san_ip + 1))
            else
                # for hostname
                sed -i "s+${san_placeholder}+DNS\.${count_san_host} = ${i}\n${san_placeholder}+g" "$1"
                count_san_host=$((count_san_host + 1))
            fi
        done
    fi
}

# Create the chain directory where all the files will be generated
function makeChainDir() {
    mkdir -p "${chain_dir}"
    echo "${chain_dir}" >>"${CHAINS_FILE}"
    echo "${node_name}" > "${chain_dir}/.name"
}

# create the directories where all the files of of the root CA will be generated
# @arg1: name of the dedicated configuration
# @arg2: any name of the current certificate
function makeChainFiles(){
    current_dir="${chain_dir}/$2"
    mkdir "${current_dir}"
    cd "${current_dir}" || exit
    mkdir certs private csr
    chmod 700 private
    touch index.txt index.txt.attr
    echo 1000 > serial
    cd "${EASYSSL_DIR}" || exit

    cp "${EASYSSL_DIR}/res/conf/${AUTODN_CONF_NAME}" "${current_dir}"
    cp "${EASYSSL_DIR}/res/conf/${ENVIRONMENT_CONF_NAME}" "${current_dir}"
    cp "${EASYSSL_DIR}/res/conf/$1" "${current_dir}/${OPENSSL_CONF_NAME}"
}

# Configure the environment, the file and the autodn files according to the current name and extension
# arg1 : any name to configure inside the file
# arg2 : extension dedicated to the proper usage of the current certificate. Must match the extensions configured inside
#       the current openssl configuration file. It will be used to generate the certificate.
# arg3 : issuer directory
# arg4 : issuer certificate name
function makeConfigure() {
    current_dir="${chain_dir}/$1"
    current_env="${chain_dir}/$1/${ENVIRONMENT_CONF_NAME}"
    current_conf="${current_dir}/${OPENSSL_CONF_NAME}"
    
    # environment
    sed -i -e "s+{{current_dir}}+${current_dir}+g" "${current_env}"
    sed -i -e "s+{{logfile}}+${current_dir}/stdout.log+g" "${current_env}"
    sed -i -e "s+{{conf}}+${current_conf}+g" "${current_env}"
    sed -i -e "s+{{private_key}}+${current_dir}/private/$1.p8+g" "${current_env}"
    sed -i -e "s+{{certificate}}+${current_dir}/certs/$1.crt+g" "${current_env}"
    sed -i -e "s+{{cert_extension}}+$2+g" "${current_env}"
    sed -i -e "s+{{csr}}+${current_dir}/csr/$1.csr.pem+g" "${current_env}"
    sed -i -e "s+{{issuer_conf}}+$3/${OPENSSL_CONF_NAME}+g" "${current_env}"
    sed -i -e "s+{{issuer_cert}}+$3\/certs\/$4+g" "${current_env}"
    sed -i -e "s+{{ca_file}}+${current_dir}/certs/ca_file.crt+g" "${current_env}"
    
    # openssl conf
    sed -i -e "s+{{ca_name}}+$1+g" "${current_conf}"
    sed -i -e "s+{{dir}}+${current_dir}+g" "${current_conf}"

    # autodn
    sed -i -e "s+{{cn}}+$1+g" "${current_dir}/${AUTODN_CONF_NAME}"
}

function makeRoot() {
    log_green "## MAKE CA ROOT ##"
    current_dir="${chain_dir}/${ca_root_name}"
    # shellcheck source=/dev/null
    source "${current_dir}/${ENVIRONMENT_CONF_NAME}"

    # make private key
    echo ". Make the CA root private key"
    temp_key="${current_dir}/private/temp.pem"
    openssl genrsa -out "${temp_key}" ${SIZE} >> "${logfile}" 2>&1
    openssl pkcs8 -topk8 -in "${temp_key}" -out "${private_key}" -nocrypt
    rm "${temp_key}"

    # make certificate
    echo ". Make the CA root certificate"
    # shellcheck source=/dev/null
    source "${current_dir}/${AUTODN_CONF_NAME}"
    subject="/DC=${auto_DC}/C=${auto_C}/ST=${auto_ST}/L=${auto_L}/O=${auto_O}/OU=${auto_OU}/CN=${auto_CN}/emailAddress=${auto_email}"
    openssl req -config "${conf}" -key "${private_key}" -new -x509 -days ${VALIDITY} -sha256 -extensions "${cert_extension}" -out "${certificate}" -subj "${subject}"

    cp "${certificate}" "${ca_file}"
}

# Create all the node or intermediate certificates
# arg1 : name of the folder inside the chain dir (this is how this function will recognize and intermediate and a node type)
function makeNode() {
    log_green "## MAKE CERTS ##"
    current_dir="${chain_dir}/$1"
    # shellcheck source=/dev/null
    source "${current_dir}/${ENVIRONMENT_CONF_NAME}"

    echo ". Create the intermediate CA private key"
    temp_key="${current_dir}/private/temp.pem"
    openssl genrsa -out "${temp_key}" ${SIZE} >> "${logfile}" 2>&1
    openssl pkcs8 -topk8 -in "${temp_key}" -out "${private_key}" -nocrypt
    rm "${temp_key}"

    echo ". Create the certificate signing request"
    # shellcheck source=/dev/null
    source "${current_dir}/${AUTODN_CONF_NAME}"
    subject="/DC=${auto_DC}/C=${auto_C}/ST=${auto_ST}/L=${auto_L}/O=${auto_O}/OU=${auto_OU}/CN=${auto_CN}/emailAddress=${auto_email}"
    openssl req -new -config "${conf}" -sha256 -key "${private_key}" -out "${csr}" -subj "${subject}"

    echo ". Create the intermediate CA certificate"
    # signing
    # if the key must be signed by a provided ca with an absolute path as argument
    yes yes | openssl ca -config "${issuer_conf}" -extensions "${cert_extension}" -days ${VALIDITY} -notext -md "${MD}" -in "${csr}" -out "${certificate}" >> "${logfile}" 2>&1

    echo ". Create the intermediate CA chain file"
    cat "${certificate}" "${issuer_cert}" > "${ca_file}"
}

# === PARSING ===

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
    -h | --help)
        usage
        exit 0
        ;;
    --root)
        arg_do_root="True"
        shift
        ;;
    --intermediate)
        arg_do_root="True"
        arg_do_intermediate="True"
        shift
        ;;
    --server)
        arg_do_root="True"
        arg_do_intermediate="True"
        arg_do_node="True"
        arg_extension="server_cert"
        shift
        ;;
    --client)
        arg_do_root="True"
        arg_do_intermediate="True"
        arg_do_node="True"
        arg_extension="client_cert"
        shift
        ;;
    --super)
        arg_do_root="True"
        arg_do_intermediate="True"
        arg_do_node="True"
        arg_extension="super_cert"
        shift
        ;;

    --issuer)
        arg_issuer=$2
        shift
        shift
        ;;
    --name)
        arg_name=$2
        shift
        shift
        ;;
    --san)
        arg_san=$2
        shift
        shift
        ;;

    -p | --purge)
        purgeDirs
        printf ". Done\n"
        exit 0
        ;;
    -s | --subject)
        ${UTILITY_SCRIPT} --subject "$2"
        exit 0
        ;;
    -e | --extract)
        ${UTILITY_SCRIPT} --extract "$2"
        exit 0
        ;;
    --platform)
        $EASYSSL_DIR/bin/platform.sh
        exit 0
        ;;
    *) # unknown option
        POSITIONAL+=("$1") # save it in an array for later
        shift              # past argument
        ;;
    esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

### PROGRAM ###

# if there is a provided name, change the chain and filenames
if [ "${arg_name}" != "None" ]; then
    configureName "${arg_name}"
fi

#setup
makeChainDir
# if there is a provided issuer, ignore root and intermediate CA generation
if [ "${arg_issuer}" == "None" ]; then
    if [ "${arg_do_root}" == "True" ]; then
        makeChainFiles "ca_root.cnf" "${ca_root_name}"
        issuer_dir="${chain_dir}/${ca_root_name}"
        makeConfigure "${ca_root_name}" "${CAROOT_EXTENSION}" "${issuer_dir}" "${ca_root_name}.crt"
        makeRoot
    fi
    if [ "${arg_do_intermediate}" == "True" ]; then
        makeChainFiles "ca_intermediate.cnf" "${ca_intermediate_name}"
        issuer_dir="${chain_dir}/${ca_root_name}"
        makeConfigure "${ca_intermediate_name}" "${INTERMEDIATE_EXTENSION}" "${issuer_dir}" "ca_file.crt"
        makeNode "${ca_intermediate_name}"
    fi
fi

if [ "${arg_do_node}" == "True" ]; then
    makeChainFiles "node.cnf" "${node_name}"
    configureNodeIssuer
    makeConfigure "${node_name}" "${arg_extension}" "${node_issuer_dir}" "ca_file.crt"
    configureDNS "${node_issuer_dir}/${OPENSSL_CONF_NAME}"
    makeNode "${node_name}"
fi

log_green ". DONE !"
echo ""
tree "${chain_dir}" -L 1

exit 0
