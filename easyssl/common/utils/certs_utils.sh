#!/bin/bash

# colors
red=$'\e[1;31m'
grn=$'\e[1;32m'
yel=$'\e[1;33m'
blu=$'\e[1;34m'
mag=$'\e[1;35m'
cyn=$'\e[1;36m'
end=$'\e[0m'

TIME=$(date +%s)
UTILS_SCRIPT_PATH="$(realpath "$0")"
# === FUNCTIONS ===

function log_red() {
    printf "${red}%s${end}\n" "$1"
}

function log_green() {
    printf "${grn}%s${end}\n" "$1"
}

function subject(){
  output=$(openssl x509 -subject -nameopt RFC2253 -noout -in "$1")
  # only display what comes after '='
  echo "${output#*=}"
}

function extract(){
  log_green "## EXTRACT CERTIFICATES ##"

  if [[ $HEADER = '/*'* ]]; then
    log_red "! FATAL: you must provide absolute path. Try '--help'."
    exit 1
  fi

  # for each chain, extract all certs inside a dedicated directory
  chains=$(cat "${CHAINS_DIR}/.chains")
  extract_dir="$1/extract_${TIME}"
  for chain_source_dir in ${chains[*]}
  do
    chain_name=$(cat "${chain_source_dir}/.name")
    chain_extract_dir="${extract_dir}/${chain_name}"
    # create chain dir
    mkdir -p "${chain_extract_dir}"
    cp "${chain_source_dir}/${chain_name}/certs/"*.crt "${chain_extract_dir}"
    cp "${chain_source_dir}/${chain_name}/private/"*.p8 "${chain_extract_dir}"
  done

  echo ""
  tree "${extract_dir}" -L 1
}

# add one or multiple certificates to trust inside a ca file
# if the ca file does not exists, it is created with the provided cert
# else the certificates are simply concatenated at the top of the ca file, keeping the order as they are provided
# arg1: absolute path to the ca file
# arg@:2 : certificates to trust
trust(){
  ca_file="$1"
  if [ ! -f "${ca_file}" ]; then
      touch "${ca_file}"
  fi
  # shellcheck disable=SC2124
  certs=${@:2}
  cp "${ca_file}" "${ca_file}.backup"
  # do not double quote 'certs' to preserve array
  cat ${certs} "${ca_file}.backup" > "${ca_file}"
  printf ". CA file updated in %s\n" "${ca_file}"
}


# === PARSING ===

POSITIONAL=()
while [[ $# -gt 0 ]]
do
  key="$1"
  case $key in
    --subject)
      subject "$2"
      exit 0
      ;;
    --extract)
      extract "$2"
      exit 0
      ;;
    --trust)
      trust "${@:2}"
      exit 0
      ;;
    *)    # unknown option
      POSITIONAL+=("$1") # save it in an array for later
      shift # past argument
      ;;
  esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

