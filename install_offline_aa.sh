#!/usr/bin/env bash
#
#  install_offline_aa.sh : Offline installer for the EPICS Archiver Appliance
#                          (MAVEN build environment)
#
#  Supported OS : Debian 11/12/13 and Ubuntu derivatives
#                 Rocky / AlmaLinux / RHEL / CentOS Stream 8, 9, 10
#
#  The installation is done in two steps.
#
#  1. on a machine which has internet access
#
#         ./install_offline_aa.sh bundle --bundle-dir=aa-bundle
#
#     downloads everything the installation needs into one directory and
#     packs it :
#
#         aa-bundle/manifest.txt   distribution, versions, commits
#         aa-bundle/env/           make rules, site templates, pom.xml
#         aa-bundle/src/           appliance source, a shallow git clone
#         aa-bundle/m2/            every Maven artifact of a real build
#         aa-bundle/tarballs/      Tomcat, Maven, optionally a Temurin JDK
#         aa-bundle/pkgs/          the OS packages and their dependencies
#
#  2. on the machine without internet access
#
#         ./install_offline_aa.sh --bundle=aa-bundle.tar.gz -y
#
#  The OS packages of the bundle only fit a machine running the same
#  distribution, major version and architecture as the machine which built
#  it. The manifest records all three and the installation stops on a
#  mismatch, unless --force-os is given.
#
#  The Sphinx documentation needs pip and a network, so the offline
#  installation always builds with -Dsphinx.skip=true.
#
#  version : 0.1.0
#
set -euo pipefail

declare -g SC_SCRIPT SC_NAME SC_DIR ENV_TOP
SC_SCRIPT="$(realpath "${BASH_SOURCE[0]:-$0}")"
SC_NAME="${SC_SCRIPT##*/}"
SC_DIR="${SC_SCRIPT%/*}"
## Where the build environment lives, set by resolve_env_top()
ENV_TOP=""

## ----------------------------------------------------------------------------
## Defaults, all of them can be changed through the command line options
## ----------------------------------------------------------------------------
## 'env'  unpacks the build environment, everything else needs it.
## 'src' comes before 'db' : sql.fill fills the tables from the SQL file which
## lives in the appliance source tree, so the clone has to exist first.
ALL_STAGES=(env pkgs java src db tomcat build install service verify)
## Stages which are never part of a default run
EXTRA_STAGES=(bundle paths exist status uninstall)
## Stages which only read the system, they never need sudo
NOSUDO_STAGES=(paths exist status)

## Bundle : created by the 'bundle' stage, consumed by every other one
BUNDLE=""                        # --bundle=DIR|TARBALL , the bundle to install from
BUNDLE_DIR="aa-bundle"           # --bundle-dir=DIR , where 'bundle' writes
BUNDLE_WORK=""                   # extracted bundle, set by open_bundle()
BUNDLE_TMP=""                    # temporary extraction directory to clean up
BUNDLE_VERSION="1"               # bundle layout version, recorded in the manifest
WITH_PKGS="true"                 # --no-pkgs   : do not put the OS packages in the bundle
WITH_JDK="true"                  # --with-jdk=no : do not put a Temurin JDK in the bundle
FORCE_OS="false"                 # --force-os  : install a bundle built on another distribution
BUNDLE_PACK="true"               # --no-pack   : leave the bundle unpacked, do not make the tarball

## Build environment repository : the make rules, the site templates, pom.xml
ENV_REPO="https://github.com/Sangil-Lee/epicsarchiverap-env"
ENV_REF="maven"                  # branch, tag or commit of ENV_REPO
ENV_DIR="/opt/aa-env"            # where it is checked out, owned by the caller
ENV_UPDATE="false"               # true : always refresh an existing checkout

## Appliance source repository, written into configure/RELEASE.local
SRC_URL=""                       # empty : keep the configure/RELEASE default

JAVA_MODE="auto"                 # auto | pkg | tarball
JDK_MAJOR="21"
JAVA_ENV_PREFIX="/opt/java-env"  # matches JAVA_HOME / MAVEN_HOME of configure/CONFIG_COMMON
MAVEN_VER="3.9.9"

AA_USER="tomcat"                 # AA_USERID and AA_GROUPID
AA_HOST_IPADDR="localhost"       # ARCHAPPL_HOST_IPADDR
STORAGE_TOP=""                   # ARCHAPPL_STORAGE_TOP, empty : keep the CONFIG_SITE default

DB_NAME="archappl"
DB_USER="archappl"
DB_USER_PASS="archappl"
DB_ADMIN="admin"
DB_ADMIN_PASS="admin"

SRC_TAG=""                       # empty : keep the configure/RELEASE default
CA_ADDR_LIST=""                  # empty : keep the configure/CONFIG_EPICSENV default
CA_AUTO_ADDR_LIST=""

## Maven downloads a few large artifacts (jython-standalone is 47 MB) and some
## networks reset those transfers. These options make Maven retry instead of
## failing the whole build.
MAVEN_NET_OPTS="-Dmaven.wagon.http.retryHandler.count=5 -Dmaven.wagon.httpconnectionManager.ttlSeconds=120"
MAVEN_USER_OPTS=""               # --maven-opts=... , appended to the mvn command line

SKIP_DOCS="false"                # true : mvn package -Dsphinx.skip=true  (make build.mvn2)
OPEN_FIREWALL="false"
ASSUME_YES="false"
DRY_RUN="false"
## the environment directory does not exist yet when the log is opened
LOG_FILE="${HOME}/install_full_aa.log"

## Ports used by the appliance, see configure/CONFIG_VARS
AA_PORTS=(17665 17666 17667 17668)

## Filled by detect_os()
OS_ID=""; OS_LIKE=""; OS_VERSION_ID=""; OS_MAJOR=""; OS_FAMILY=""; OS_PRETTY=""
## Filled by stage_java()
JAVA_HOME_DETECTED=""; MAVEN_HOME_DETECTED=""; ANT_HOME_DETECTED=""
## Filled by parse_args()
REQUESTED_STAGES=()
## Which values were given on the command line : the other ones are seeded from
## the current make configuration so that a partial run never silently resets them
declare -A OPT_SET=()

## ----------------------------------------------------------------------------
## Pretty printing and logging
## ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_BLU=$'\033[1;34m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_OFF=""
fi

function log   { printf '%s\n' "$*" >> "${LOG_FILE}" 2>/dev/null || true; }
function info  { printf '%s>>>%s %s\n'   "${C_BLU}" "${C_OFF}" "$*"; log ">>> $*"; }
function ok    { printf '%s[ OK]%s %s\n' "${C_GRN}" "${C_OFF}" "$*"; log "[ OK] $*"; }
function warn  { printf '%s[ !!]%s %s\n' "${C_YEL}" "${C_OFF}" "$*" >&2; log "[ !!] $*"; }
function error { printf '%s[ERR]%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; log "[ERR] $*"; }
function die   { error "$*"; [[ -s "${LOG_FILE}" ]] && error "see the log file ${LOG_FILE}"; exit 1; }

function banner
{
    printf '\n%s------------------------------------------------------------%s\n' "${C_BLU}" "${C_OFF}"
    printf '%s  %s%s\n' "${C_BLU}" "$*" "${C_OFF}"
    printf '%s------------------------------------------------------------%s\n\n' "${C_BLU}" "${C_OFF}"
    log ""; log "=== $* ==="
}

## try   : run a command, tee its output into the log file, return its status
## run   : the same, but abort the installation when the command fails
## try_sh / run_sh : the same for a shell snippet (pipes, redirections, globs)
function try
{
    log "\$ $*"
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '%s[dry]%s %s\n' "${C_YEL}" "${C_OFF}" "$*"
        return 0
    fi
    "$@" 2>&1 | tee -a "${LOG_FILE}"
    return "${PIPESTATUS[0]}"
}

function run { try "$@" || die "command failed : $*"; }

function try_sh
{
    log "\$ $*"
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '%s[dry]%s %s\n' "${C_YEL}" "${C_OFF}" "$*"
        return 0
    fi
    bash -c "$*" 2>&1 | tee -a "${LOG_FILE}"
    return "${PIPESTATUS[0]}"
}

function run_sh { try_sh "$*" || die "command failed : $*"; }

## make wrappers.
## 'cd' instead of 'make -C' on purpose : -C turns on --print-directory, which
## the sub-make started by scripts/mariadb_setup.bash inherits, and its
## "Entering directory" lines then end up inside the captured path.
## The build environment may not be there yet : during a --dry-run it is never
## fetched, so make is only announced and every variable reads back empty.
function try_mk
{
    if [[ ! -d "${ENV_TOP}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            printf '%s[dry]%s make %s   (in %s)\n' "${C_YEL}" "${C_OFF}" "$*" "${ENV_TOP}"
            return 0
        fi
        die "the build environment ${ENV_TOP} does not exist"
    fi
    ( cd "${ENV_TOP}" && try make "$@" )
}
function mk       { try_mk "$@" || die "make $* failed"; }
function make_var { [[ -d "${ENV_TOP}" ]] || return 0; ( cd "${ENV_TOP}" && make -s "print-$1" 2>/dev/null | tail -1 ); }

function ask_yes
{
    local prompt="$1" answer
    [[ "${ASSUME_YES}" == "true" ]] && return 0
    read -r -p "${prompt} [y/N] " answer
    [[ "${answer}" =~ ^[Yy] ]]
}

## ----------------------------------------------------------------------------
## Usage
## ----------------------------------------------------------------------------
function usage
{
    cat <<EOF

Usage : ${SC_NAME} [OPTIONS] [STAGE ...]

  Offline installation of the EPICS Archiver Appliance (MAVEN environment)
  on the Debian and the Rocky / RHEL family of Linux distributions.

  Step 1, on a machine with internet access :

      ./${SC_NAME} bundle --bundle-dir=aa-bundle

  collects everything into aa-bundle/ and packs aa-bundle.tar.gz :
  the build environment, the appliance source as a git repository, every
  Maven artifact of a real build, the Tomcat / Maven / JDK tarballs and the
  OS packages with their dependencies.

  Step 2, on the machine without internet access :

      ./${SC_NAME} --bundle=aa-bundle.tar.gz -y --storage=/home/archappl

  The bundled OS packages only fit a machine running the same distribution,
  major version and architecture. The manifest records all three and the
  installation stops on a mismatch unless --force-os is given. The Sphinx
  documentation always needs a network, so the offline build skips it.

  Without --bundle this script behaves like the online installer.

STAGES (default : all of them, in this order)

  env       Unpack the build environment from the bundle, or fetch it
  pkgs      Install the OS packages : build tools, MariaDB, chrony, ...
  java      Install or detect JDK ${JDK_MAJOR}+ and Apache Maven, generate configure/*.local
  src       Clone the appliance source code            (make init)
  db        Enable MariaDB, secure it, create the database, the user and the tables
  tomcat    Download and install Apache Tomcat 9 into \$(TOMCAT_INSTALL_LOCATION)
  build     Build the WAR files with Maven             (make build)
  install   Install the appliance and the systemd unit (make install)
  service   Start and enable the systemd service
  verify    Wait for the mgmt web application, then print a summary

  These ones are never part of a default run :

  bundle    Collect everything an offline machine needs (needs the network)
  paths     Print every path and setting this installation uses  (no sudo)
  exist     Check what is installed and what is missing          (no sudo)
  status    Print the systemd and the appliance service status   (no sudo)
  uninstall Stop the service and remove the installed appliance

OPTIONS

  -y, --yes                  Do not ask anything, assume "yes"
  -n, --dry-run              Only print what would be done
      --log-file=FILE        Log file (default : ${LOG_FILE})

      --bundle=PATH          Install from this bundle, a directory or a tar.gz
      --bundle-dir=DIR       Where the 'bundle' stage writes  (default : ${BUNDLE_DIR})
      --no-pkgs              Do not put the OS packages in the bundle, the
                             offline machine installs them from its own mirror
      --with-jdk=no          Do not put the Temurin JDK in the bundle
      --no-pack              Leave the bundle unpacked, do not create the tar.gz
      --force-os             Install a bundle built on another distribution,
                             its OS packages are then ignored

      --env-repo=URL         Build environment repository
                             (default : ${ENV_REPO})
      --env-ref=REF          Its branch, tag or commit    (default : ${ENV_REF})
      --env-dir=PATH         Where it is checked out      (default : ${ENV_DIR})
      --env-update           Refresh an existing checkout before installing

      --src-url=URL          Appliance source repository account or URL prefix,
                             SRC_URL of configure/RELEASE
      --src-tag=TAG          Its branch, tag or commit, SRC_TAG

      --java-mode=MODE       auto | pkg | tarball   (default : ${JAVA_MODE})
                             auto    : reuse an installed JDK ${JDK_MAJOR}+, else the
                                       distribution package, else the Temurin tarball
                             pkg     : distribution package only
                             tarball : always download the Eclipse Temurin tarball
      --jdk-major=N          JDK major version (default : ${JDK_MAJOR})
      --java-prefix=PATH     Where the downloaded JDK/Maven go (default : ${JAVA_ENV_PREFIX})
      --maven-version=VER    Apache Maven version (default : ${MAVEN_VER})

      --aa-user=NAME         Service user and group (default : ${AA_USER})
      --host=ADDR            ARCHAPPL_HOST_IPADDR used in appliances.xml (default : ${AA_HOST_IPADDR})
      --storage=PATH         ARCHAPPL_STORAGE_TOP, the sts/mts/lts parent directory
                             (default : the configure/CONFIG_SITE value, \$HOME/arch)

      --db-name=NAME         Database name       (default : ${DB_NAME})
      --db-user=NAME         Database user       (default : ${DB_USER})
      --db-pass=PASS         Database password   (default : ${DB_USER_PASS})
      --db-admin=NAME        SQL admin account   (default : ${DB_ADMIN})
      --db-admin-pass=PASS   SQL admin password  (default : ${DB_ADMIN_PASS})

      --ca-addr-list=LIST    EPICS_CA_ADDR_LIST, e.g. "127.0.0.1 10.0.0.255"
      --ca-auto-addr-list=YES|NO
      --maven-opts=OPTS      Extra options for the Maven command line
      --skip-docs            Build without the Sphinx documentation (-Dsphinx.skip=true)
      --open-firewall        Open the appliance ports (${AA_PORTS[*]}) in firewalld or ufw

  -h, --help                 This message

EXAMPLES BY PURPOSE

  The 'make' commands below are run from the build environment directory,
  \$(${SC_NAME} paths | grep environment).
  Do not add 'make -C', the scripts called by some rules cannot cope with it.

  Step 1 : build the bundle, on a machine with internet access
    ./${SC_NAME} bundle                              # ./aa-bundle + aa-bundle.tar.gz
    ./${SC_NAME} bundle --bundle-dir=/data/aa-2026-08 --no-pkgs
    ./${SC_NAME} bundle --env-ref=v1.0 --src-tag=v1.0 --with-jdk=no
    tar tzf aa-bundle.tar.gz | head            # what is inside
    cat aa-bundle/manifest.txt                 # distribution, versions, commits

  Step 2 : install, on the machine without internet access
    ./${SC_NAME} --bundle=aa-bundle.tar.gz -y --storage=/home/archappl
    ./${SC_NAME} --bundle=/mnt/usb/aa-bundle -y       # an unpacked bundle works too
    ./${SC_NAME} --bundle=aa-bundle.tar.gz --dry-run  # check before touching anything
    ./${SC_NAME} --bundle=aa-bundle.tar.gz --force-os -y   # OS packages from your mirror

  Install only a part of it from the bundle
    ./${SC_NAME} --bundle=aa-bundle.tar.gz build install service
    ./${SC_NAME} --bundle=aa-bundle.tar.gz db          # only the database

  Which paths are used : installation, storage, JDK, Tomcat, database, systemd
    ./${SC_NAME} paths
    make vars FILTER=ARCHAPPL
    make print-AA_INSTALL_LOCATION                   # one single variable

  Is it installed, and is it running ?
    ./${SC_NAME} exist                               # every component, one line each
    ./${SC_NAME} status                              # systemd unit and service PIDs
    ./${SC_NAME} verify                              # wait for the web application
    make exist LEVEL=2                               # tree of the installed files

  Rebuild and redeploy after a source or a configuration change
    ./${SC_NAME} build install service
    ./${SC_NAME} --src-tag=master src build install service

  Change one setting and apply it, the other settings are kept
    ./${SC_NAME} --storage=/home/archappl build install service
    ./${SC_NAME} --ca-addr-list='10.0.0.255' install service

  Database only
    ./${SC_NAME} db                                  # database, user and tables
    make sql.show                                    # list the appliance tables
    make PVTypeInfo.show                             # list the archived PVs

  Logs and troubleshooting
    tail -f ${LOG_FILE}
    ./${SC_NAME} status
    make sd_status

  Remove it
    ./${SC_NAME} uninstall                           # appliance and systemd unit
    make tomcat.uninstall                            # Tomcat as well
    make db.drop                                     # database and its user
    rm -f configure/*.local                          # back to the environment defaults

EOF
}

## ----------------------------------------------------------------------------
## Option parsing
## ----------------------------------------------------------------------------
function parse_args
{
    while (( $# > 0 )); do
        case "$1" in
            -y|--yes)              ASSUME_YES="true" ;;
            -n|--dry-run)          DRY_RUN="true" ;;
            --log-file=*)          LOG_FILE="${1#*=}" ;;
            --java-mode=*)         JAVA_MODE="${1#*=}" ;;
            --jdk-major=*)         JDK_MAJOR="${1#*=}" ;;
            --java-prefix=*)       JAVA_ENV_PREFIX="${1#*=}" ;;
            --maven-version=*)     MAVEN_VER="${1#*=}" ;;
            --aa-user=*)           AA_USER="${1#*=}";        OPT_SET[AA_USER]=1 ;;
            --host=*)              AA_HOST_IPADDR="${1#*=}"; OPT_SET[AA_HOST_IPADDR]=1 ;;
            --storage=*)           STORAGE_TOP="${1#*=}";    OPT_SET[STORAGE_TOP]=1 ;;
            --db-name=*)           DB_NAME="${1#*=}";        OPT_SET[DB_NAME]=1 ;;
            --db-user=*)           DB_USER="${1#*=}";        OPT_SET[DB_USER]=1 ;;
            --db-pass=*)           DB_USER_PASS="${1#*=}";   OPT_SET[DB_USER_PASS]=1 ;;
            --db-admin=*)          DB_ADMIN="${1#*=}";       OPT_SET[DB_ADMIN]=1 ;;
            --db-admin-pass=*)     DB_ADMIN_PASS="${1#*=}";  OPT_SET[DB_ADMIN_PASS]=1 ;;
            --bundle=*)            BUNDLE="${1#*=}" ;;
            --bundle-dir=*)        BUNDLE_DIR="${1#*=}" ;;
            --no-pkgs)             WITH_PKGS="false" ;;
            --with-jdk=*)          [[ "${1#*=}" =~ ^(no|false|0)$ ]] && WITH_JDK="false" || WITH_JDK="true" ;;
            --no-pack)             BUNDLE_PACK="false" ;;
            --force-os)            FORCE_OS="true" ;;
            --env-repo=*)          ENV_REPO="${1#*=}" ;;
            --env-ref=*)           ENV_REF="${1#*=}" ;;
            --env-dir=*)           ENV_DIR="${1#*=}"; OPT_SET[ENV_DIR]=1 ;;
            --env-update)          ENV_UPDATE="true" ;;
            --src-url=*)           SRC_URL="${1#*=}" ;;
            --src-tag=*)           SRC_TAG="${1#*=}" ;;
            --ca-addr-list=*)      CA_ADDR_LIST="${1#*=}" ;;
            --ca-auto-addr-list=*) CA_AUTO_ADDR_LIST="${1#*=}" ;;
            --maven-opts=*)        MAVEN_USER_OPTS="${1#*=}" ;;
            --skip-docs)           SKIP_DOCS="true" ;;
            --open-firewall)       OPEN_FIREWALL="true" ;;
            -h|--help)             usage; exit 0 ;;
            -*)                    usage; die "unknown option : $1" ;;
            *)                     REQUESTED_STAGES+=("$1") ;;
        esac
        shift
    done

    case "${JAVA_MODE}" in
        auto|pkg|tarball) ;;
        *) die "--java-mode must be one of auto, pkg, tarball" ;;
    esac
    [[ "${JDK_MAJOR}" =~ ^[0-9]+$ ]] || die "--jdk-major must be a number"

    if (( ${#REQUESTED_STAGES[@]} == 0 )); then
        REQUESTED_STAGES=("${ALL_STAGES[@]}")
    fi

    local stage s known
    for stage in "${REQUESTED_STAGES[@]}"; do
        known="false"
        for s in "${ALL_STAGES[@]}" "${EXTRA_STAGES[@]}"; do
            [[ "${stage}" == "${s}" ]] && known="true"
        done
        [[ "${known}" == "true" ]] || die "unknown stage : ${stage}, see ${SC_NAME} --help"
    done
}

## true when the run only creates a bundle : it must not touch the configuration
## of the machine it runs on, the bundle carries its own environment
function stages_are_bundle_only
{
    local stage
    for stage in "${REQUESTED_STAGES[@]}"; do
        [[ "${stage}" == "bundle" ]] || return 1
    done
    return 0
}

## true when every requested stage only reads the system
function stages_are_read_only
{
    local stage s found
    for stage in "${REQUESTED_STAGES[@]}"; do
        found="false"
        for s in "${NOSUDO_STAGES[@]}"; do
            [[ "${stage}" == "${s}" ]] && found="true"
        done
        [[ "${found}" == "true" ]] || return 1
    done
    return 0
}

## ----------------------------------------------------------------------------
## Bundle : creation on the online machine, opening on the offline one
## ----------------------------------------------------------------------------
function bundle_manifest_value
{
    local key="$1"
    [[ -r "${BUNDLE_WORK}/manifest.txt" ]] || return 0
    awk -F'=' -v k="${key}" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "${BUNDLE_WORK}/manifest.txt"
}

## Make the bundle usable : a directory is taken as is, a tarball is extracted
function open_bundle
{
    [[ -n "${BUNDLE}" ]] || return 0
    [[ -e "${BUNDLE}" ]] || die "the bundle ${BUNDLE} does not exist"

    if [[ -d "${BUNDLE}" ]]; then
        BUNDLE_WORK="$(realpath "${BUNDLE}")"
    elif [[ "${DRY_RUN}" == "true" ]]; then
        ## unpacking hundreds of megabytes to show a plan is pointless : only the
        ## manifest is read, and the layout it describes is mimicked
        BUNDLE_TMP="$(mktemp -d)"
        BUNDLE_WORK="${BUNDLE_TMP}/bundle"
        mkdir -p "${BUNDLE_WORK}"
        info "reading the manifest of $(basename "${BUNDLE}")"
        tar -C "${BUNDLE_WORK}" --strip-components=1 --wildcards -xzf "$(realpath "${BUNDLE}")" '*/manifest.txt' 2>/dev/null \
            || warn "no manifest could be read from the tarball"
        mkdir -p "${BUNDLE_WORK}/env" "${BUNDLE_WORK}/m2" "${BUNDLE_WORK}/tarballs"
        [[ "$(bundle_manifest_value with_pkgs)" == "true" ]] && mkdir -p "${BUNDLE_WORK}/pkgs"
    else
        BUNDLE_TMP="$(mktemp -d)"
        info "extracting $(basename "${BUNDLE}") ..."
        run_sh "tar -C '${BUNDLE_TMP}' -xzf '$(realpath "${BUNDLE}")'"
        ## the tarball carries one single top directory
        BUNDLE_WORK="$(find "${BUNDLE_TMP}" -mindepth 1 -maxdepth 1 -type d | head -1)"
        [[ -n "${BUNDLE_WORK}" ]] || die "the bundle tarball looks empty"
    fi

    [[ -r "${BUNDLE_WORK}/manifest.txt" ]] || die "${BUNDLE_WORK} has no manifest.txt, this is not a bundle"
    ok "bundle : ${BUNDLE_WORK}"

    local b_id b_major b_arch
    b_id="$(bundle_manifest_value os_id)"
    b_major="$(bundle_manifest_value os_major)"
    b_arch="$(bundle_manifest_value arch)"
    info "built on ${b_id} ${b_major} ${b_arch} at $(bundle_manifest_value created)"

    if [[ -d "${BUNDLE_WORK}/pkgs" ]] && [[ "${b_id}" != "${OS_ID}" || "${b_major}" != "${OS_MAJOR}" || "${b_arch}" != "$(uname -m)" ]]; then
        error "the bundle carries ${b_id} ${b_major} ${b_arch} packages, this machine is ${OS_ID} ${OS_MAJOR} $(uname -m)"
        if [[ "${FORCE_OS}" == "true" ]]; then
            warn "--force-os given, the OS packages of the bundle are ignored"
            WITH_PKGS="false"
        else
            error "rebuild the bundle on a ${OS_ID} ${OS_MAJOR} machine, or install the OS packages"
            error "from your own mirror and add --force-os"
            die "the bundle does not fit this machine"
        fi
    fi
    return 0
}

function close_bundle
{
    [[ -n "${BUNDLE_TMP}" && -d "${BUNDLE_TMP}" ]] && rm -rf "${BUNDLE_TMP}"
    return 0
}

## --- creation ---------------------------------------------------------------
## The distribution JDK is only bundled when no Temurin tarball is : on EL,
## java-N-openjdk-devel pulls the whole graphical stack (libX11, fontconfig,
## and through it pipewire and gnome pieces), some 46 packages which the
## appliance never uses and which clash with what a desktop machine already has.
## 'ant' is left out for the same reason, the Maven build does not use it.
function bundle_pkg_list
{
    if [[ "${OS_FAMILY}" == "debian" ]]; then
        printf '%s\n' ca-certificates wget curl git sed gawk unzip tar make gcc tree procps \
                      python3 python3-pip python3-venv \
                      mariadb-server mariadb-client chrony
        [[ "${WITH_JDK}" == "true" ]] || printf '%s\n' "openjdk-${JDK_MAJOR}-jdk-headless"
    else
        printf '%s\n' ca-certificates wget curl git sed gawk unzip tar make gcc libgcc which tree procps-ng \
                      python3 python3-pip \
                      mariadb-server mariadb chrony
        [[ "${WITH_JDK}" == "true" ]] || printf '%s\n' "java-${JDK_MAJOR}-openjdk-devel"
    fi
}

function bundle_packages
{
    local dest="$1" pkgs=()
    mapfile -t pkgs < <(bundle_pkg_list)
    run mkdir -p "${dest}"

    if [[ "${OS_FAMILY}" == "debian" ]]; then
        warn "on Debian only the packages which are not installed yet can be downloaded reliably,"
        warn "build the bundle on a machine which does not have them, or use your own mirror"
        run mkdir -p "${dest}/partial"
        try_sh "sudo apt-get install --reinstall --download-only -y -o Dir::Cache::archives='${dest}' ${pkgs[*]}" \
            || warn "apt-get could not download every package"
        try_sh "sudo chown -R $(id -un):$(id -gn) '${dest}'" || true
        rmdir "${dest}/partial" 2>/dev/null || true
    else
        ## --alldeps : also fetch the dependencies which are already installed here,
        ##             the target machine may not have them
        ## skip_if_unavailable : one broken third party repository must not stop
        ##             the download of everything else
        run_sh "dnf download -y --setopt='*.skip_if_unavailable=1' --resolve --alldeps --destdir='${dest}' ${pkgs[*]} < /dev/null"
    fi

    local n; n="$(find "${dest}" -name '*.rpm' -o -name '*.deb' 2>/dev/null | wc -l)"
    ok "${n} package files, $(du -sh "${dest}" 2>/dev/null | cut -f1)"
}

function bundle_tarballs
{
    local dest="$1"
    run mkdir -p "${dest}"

    ## Tomcat, the URL is built by the make rules of the environment
    local tomcat_url tomcat_src
    tomcat_url="$(make_var TOMCAT_URL)"; tomcat_url="${tomcat_url//\"/}"
    tomcat_src="$(make_var TOMCAT_SRC)"
    if [[ -s "${dest}/${tomcat_src}" ]]; then
        ok "${tomcat_src} is already in the bundle"
    else
        info "downloading ${tomcat_src}"
        run_sh "curl -fsSL '${tomcat_url}' -o '${dest}/${tomcat_src}'"
    fi

    ## Maven
    local maven_src="apache-maven-${MAVEN_VER}-bin.tar.gz"
    if [[ -s "${dest}/${maven_src}" ]]; then
        ok "${maven_src} is already in the bundle"
    else
        info "downloading ${maven_src}"
        run_sh "curl -fsSL 'https://archive.apache.org/dist/maven/maven-3/${MAVEN_VER}/binaries/${maven_src}' -o '${dest}/${maven_src}'"
    fi

    ## Temurin JDK, only used when the target machine has no JDK package
    if [[ "${WITH_JDK}" == "true" ]]; then
        local arch
        case "$(uname -m)" in
            x86_64)  arch="x64" ;;
            aarch64) arch="aarch64" ;;
            *) warn "no Temurin build for $(uname -m), the JDK is not bundled"; arch="" ;;
        esac
        if [[ -s "${dest}/temurin-jdk-${JDK_MAJOR}-linux-${arch}.tar.gz" ]]; then
            ok "the Temurin JDK is already in the bundle"
        elif [[ -n "${arch}" ]]; then
            info "downloading the Eclipse Temurin JDK ${JDK_MAJOR} (${arch})"
            run_sh "curl -fsSL 'https://api.adoptium.net/v3/binary/latest/${JDK_MAJOR}/ga/linux/${arch}/jdk/hotspot/normal/eclipse' -o '${dest}/temurin-jdk-${JDK_MAJOR}-linux-${arch}.tar.gz'"
        fi
    fi
    ok "tarballs : $(du -sh "${dest}" 2>/dev/null | cut -f1)"
}

## Populate the Maven repository by running a real build : dependency:go-offline
## misses the plugins which are only resolved while packaging.
##
## The build is driven by the make rules of the bundled environment, not by a
## bare mvn call : conf.archapplproperties generates the site files and
## copy.sitespecific puts them in src/sitespecific/<siteid>/classpathfiles,
## which the war plugin needs. ENV_TOP already points at the bundled
## environment, and the source sits inside it at $(SRC_PATH).
## The build is a full one, Sphinx included : pom.xml packs ${docs.dir}/docs/build
## into the mgmt war, and that directory only exists once Sphinx has run. Sphinx
## needs pip and a network, which the offline machine does not have, so its
## output travels inside the bundle and the offline build skips Sphinx itself.
function bundle_maven_repo
{
    local dest="$1" src="$2"
    run mkdir -p "${dest}"
    info "building once to fill the Maven repository, this takes a few minutes"
    mk conf.archapplproperties
    mk build.mvn MAVEN_OPTS="-Dmaven.repo.local=${dest} ${MAVEN_NET_OPTS}"
    [[ -d "${src}/docs/docs/build" ]] \
        || warn "${src}/docs/docs/build was not produced, the offline mgmt war will have no documentation"
    ## the war files are rebuilt on the target, the python virtual environment
    ## of Sphinx is useless there, but its rendered output is kept
    run_sh "cd '${src}' && rm -rf target docs/.venv"
    ok "maven repository : $(du -sh "${dest}" 2>/dev/null | cut -f1)"
}

function stage_bundle
{
    banner "Stage : bundle - collect everything an offline machine needs"

    [[ "${DRY_RUN}" == "true" ]] && { info "would create the bundle in ${BUNDLE_DIR}"; return 0; }
    command -v git >/dev/null 2>&1 || die "git is required to create a bundle"

    local dest; dest="$(realpath -m "${BUNDLE_DIR}")"
    if [[ -e "${dest}" && ! -d "${dest}" ]]; then
        die "${dest} exists and is not a directory"
    fi
    ## an interrupted bundle is continued instead of being thrown away : the
    ## downloads are large and a broken repository or network should not cost
    ## everything which was already collected
    [[ -d "${dest}" ]] && info "${dest} exists, the parts which are already complete are kept"
    run mkdir -p "${dest}"

    ## 1. the build environment
    if is_env_top "${dest}/env"; then
        ok "the build environment is already in the bundle"
    else
        info "cloning the build environment ${ENV_REPO} (${ENV_REF})"
        run rm -rf "${dest}/env"
        try_sh "git clone --depth 1 --branch '${ENV_REF}' '${ENV_REPO}' '${dest}/env'" \
            || run_sh "git clone '${ENV_REPO}' '${dest}/env' && git -C '${dest}/env' checkout '${ENV_REF}'"
    fi

    ## the source URL and tag come from the environment which was just cloned
    local saved_env_top="${ENV_TOP}"
    ENV_TOP="${dest}/env"
    [[ -n "${SRC_URL}" || -n "${SRC_TAG}" ]] && write_config_file "${ENV_TOP}/configure/RELEASE.local" \
"## Generated by ${SC_NAME}
$( [[ -n "${SRC_URL}" ]] && echo "SRC_URL=${SRC_URL}" )
$( [[ -n "${SRC_TAG}" ]] && printf 'SRC_TAG:=%s\nSRC_VERSION:=%s\n' "${SRC_TAG}" "${SRC_TAG}" )
"
    local src_url src_tag src_path
    src_url="$(make_var SRC_GITURL)"
    src_tag="$(make_var SRC_TAG)"
    src_path="$(make_var SRC_PATH)"

    ## 2. the appliance source, as a git repository : the make rules and the pom
    ##    read the git history (src_version, RELEASE_NOTES). It is cloned where
    ##    the make rules expect it, inside the environment.
    if [[ -d "${ENV_TOP}/${src_path}/.git" ]]; then
        ok "the appliance source is already in the bundle"
    else
        info "cloning the appliance source ${src_url} (${src_tag})"
        run rm -rf "${ENV_TOP}/${src_path}"
        try_sh "git clone --depth 1 --branch '${src_tag}' '${src_url}' '${ENV_TOP}/${src_path}'" \
            || run_sh "git clone '${src_url}' '${ENV_TOP}/${src_path}' && git -C '${ENV_TOP}/${src_path}' checkout '${src_tag}'"
    fi

    ## 3. the Maven artifacts, from a real build
    JAVA_HOME_DETECTED="$(find_system_jdk)" || die "a JDK ${JDK_MAJOR}+ is needed to create a bundle, run './${SC_NAME} java' first"
    MAVEN_HOME_DETECTED="${JAVA_ENV_PREFIX}/MAVEN"
    [[ -x "${MAVEN_HOME_DETECTED}/bin/mvn" ]] || die "Maven is needed to create a bundle, run './${SC_NAME} java' first"
    ## the bundled environment must point at the JDK and the Maven of this machine
    write_local_config
    ## a reference build which already produced the Sphinx output is not redone
    if [[ -d "${dest}/m2" && -d "${ENV_TOP}/${src_path}/docs/docs/build" ]]; then
        ok "the Maven repository is already in the bundle ($(du -sh "${dest}/m2" | cut -f1))"
    else
        bundle_maven_repo "${dest}/m2" "${ENV_TOP}/${src_path}"
    fi

    ## 4. Tomcat, Maven and the JDK tarballs
    bundle_tarballs "${dest}/tarballs"

    ## 5. the OS packages
    if [[ "${WITH_PKGS}" == "true" ]]; then
        bundle_packages "${dest}/pkgs"
    else
        info "--no-pkgs : the OS packages are not bundled, the target machine needs its own mirror"
    fi

    ## 6. the manifest and this installer
    run cp -f "${SC_SCRIPT}" "${dest}/${SC_NAME}"
    write_config_file "${dest}/manifest.txt" "\
bundle_version=${BUNDLE_VERSION}
created=$(date '+%Y-%m-%d %H:%M:%S %z')
created_on=$(hostname)
os_id=${OS_ID}
os_major=${OS_MAJOR}
os_pretty=${OS_PRETTY}
arch=$(uname -m)
env_repo=${ENV_REPO}
env_ref=${ENV_REF}
env_commit=$(git -C "${dest}/env" log --oneline -1 2>/dev/null || echo unknown)
src_url=${src_url}
src_tag=${src_tag}
src_path=${src_path}
src_commit=$(git -C "${ENV_TOP}/${src_path}" log --oneline -1 2>/dev/null || echo unknown)
jdk_major=${JDK_MAJOR}
maven_version=${MAVEN_VER}
tomcat_version=$(make_var TOMCAT_VER)
with_pkgs=${WITH_PKGS}
with_jdk=${WITH_JDK}
"
    ENV_TOP="${saved_env_top}"

    ## 7. pack it
    if [[ "${BUNDLE_PACK}" == "true" ]]; then
        info "packing ${dest}.tar.gz"
        run rm -f "${dest}.tar.gz"
        run_sh "tar -C '$(dirname "${dest}")' -czf '${dest}.tar.gz' '$(basename "${dest}")'"
        ok "bundle : ${dest}.tar.gz  ($(du -sh "${dest}.tar.gz" | cut -f1))"
    fi

    printf '\n'
    print_kv "bundle directory" "${dest}  ($(du -sh "${dest}" | cut -f1))"
    print_kv "install it with"  "./${SC_NAME} --bundle=${dest}.tar.gz -y --storage=/home/archappl"
    printf '\n'
    return 0
}

## ----------------------------------------------------------------------------
## Build environment : take it from the bundle, or fetch it
## ----------------------------------------------------------------------------
## A directory is a usable build environment when it carries the make rules,
## the site templates and the pom.xml this installer drives.
function is_env_top
{
    local dir="$1"
    [[ -r "${dir}/Makefile" && -d "${dir}/configure" && -d "${dir}/site-template" && -r "${dir}/pom.xml" ]]
}

## https://github.com/owner/repo(.git) -> owner/repo , empty for any other host
function github_slug
{
    local url="${1%.git}"
    [[ "${url}" =~ ^https?://github\.com/([^/]+)/([^/]+)/?$ ]] || return 1
    printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

function fetch_env_git
{
    command -v git >/dev/null 2>&1 || return 1
    info "cloning ${ENV_REPO} (${ENV_REF}) into ${ENV_DIR}"
    try_sh "git clone --branch '${ENV_REF}' '${ENV_REPO}' '${ENV_DIR}'" && return 0
    ## a commit hash cannot be cloned with --branch
    try_sh "git clone '${ENV_REPO}' '${ENV_DIR}' && git -C '${ENV_DIR}' checkout '${ENV_REF}'"
}

function fetch_env_tarball
{
    local slug tmp
    slug="$(github_slug "${ENV_REPO}")" || {
        warn "${ENV_REPO} is not a github.com URL, the tarball fallback only knows github.com"
        return 1
    }
    info "downloading ${slug} (${ENV_REF}) as a tarball into ${ENV_DIR}"
    tmp="$(mktemp -d)"
    try_sh "curl -fsSL 'https://codeload.github.com/${slug}/tar.gz/${ENV_REF}' -o '${tmp}/env.tar.gz'" || {
        rm -rf "${tmp}"; return 1
    }
    try_sh "tar -C '${ENV_DIR}' -xzf '${tmp}/env.tar.gz' --strip-components=1" || { rm -rf "${tmp}"; return 1; }
    rm -rf "${tmp}"
    return 0
}

## Refresh an existing git checkout, a tarball checkout is simply left alone
function update_env_git
{
    [[ -d "${ENV_TOP}/.git" ]] || { warn "${ENV_TOP} is not a git checkout, nothing to update"; return 0; }
    command -v git >/dev/null 2>&1 || return 0
    info "updating ${ENV_TOP} to ${ENV_REF}"
    try_sh "git -C '${ENV_TOP}' fetch --all --tags" || warn "git fetch failed, keeping the current checkout"
    try_sh "git -C '${ENV_TOP}' checkout '${ENV_REF}'" || warn "cannot check out ${ENV_REF}"
    try_sh "git -C '${ENV_TOP}' pull --ff-only" || true
    return 0
}

## This installer has to work on a bare system : make drives every stage and
## git or curl is needed to bring the build environment in.
function ensure_bootstrap_tools
{
    [[ "${DRY_RUN}" == "true" ]] && return 0
    stages_are_read_only && return 0

    local missing=()
    command -v make >/dev/null 2>&1 || missing+=("make")
    command -v tar  >/dev/null 2>&1 || missing+=("tar")
    if ! command -v git >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        missing+=("git" "curl" "ca-certificates")
    fi
    (( ${#missing[@]} == 0 )) && return 0

    info "installing the bootstrap tools : ${missing[*]}"
    if [[ "${OS_FAMILY}" == "debian" ]]; then
        try sudo env DEBIAN_FRONTEND=noninteractive apt-get update -y || true
    fi
    pkg_install "${missing[@]}"
    return 0
}

## Offline machines may not even have make yet, and it is in the bundle
function ensure_bundle_bootstrap
{
    [[ "${DRY_RUN}" == "true" ]] && return 0
    stages_are_read_only && return 0
    command -v make >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 && return 0

    [[ -d "${BUNDLE_WORK}/pkgs" && "${WITH_PKGS}" == "true" ]] \
        || die "'make' is missing and the bundle carries no packages, install make and tar first"
    info "'make' is missing, installing the packages of the bundle first"
    pkgs_from_bundle
    command -v make >/dev/null 2>&1 || die "'make' is still missing after the bundle packages were installed"
    return 0
}

## Decide which directory is the build environment and make sure it exists.
## 1. the directory of this script, when the installer sits inside a checkout
## 2. --env-dir, when it already carries a checkout
## 3. otherwise fetch the environment repository into --env-dir
function resolve_env_top
{
    ## A bundle always installs into --env-dir and keeps using it. This is
    ## checked first and unconditionally : the second call of this function, from
    ## the 'env' stage, must not fall back to a checkout which happens to sit
    ## next to the script.
    if [[ -n "${BUNDLE_WORK}" && -d "${BUNDLE_WORK}/env" ]] && is_env_top "${ENV_DIR}"; then
        ENV_TOP="${ENV_DIR}"
        ok "build environment of the bundle : ${ENV_TOP}"
        return 0
    fi
    ## an explicit --env-dir which already holds an environment wins over the
    ## directory of the script as well
    if [[ -z "${BUNDLE_WORK}" && -n "${OPT_SET[ENV_DIR]:-}" ]] && is_env_top "${ENV_DIR}"; then
        ENV_TOP="${ENV_DIR}"
        ok "build environment : ${ENV_TOP}"
        [[ "${ENV_UPDATE}" == "true" ]] && update_env_git
        return 0
    fi

    ## the bundle carries the environment, copy it into --env-dir
    if [[ -n "${BUNDLE_WORK}" && -d "${BUNDLE_WORK}/env" ]]; then
        info "installing the build environment of the bundle into ${ENV_DIR}"
        if [[ "${DRY_RUN}" != "true" ]]; then
            if ! mkdir -p "${ENV_DIR}" 2>/dev/null; then
                run sudo install -d -o "$(id -un)" -g "$(id -gn)" "${ENV_DIR}"
            fi
            [[ -w "${ENV_DIR}" ]] || run sudo chown "$(id -un):$(id -gn)" "${ENV_DIR}"
            run_sh "cp -a '${BUNDLE_WORK}/env/.' '${ENV_DIR}/'"
        fi
        ENV_TOP="${ENV_DIR}"
        ok "build environment ready : ${ENV_TOP}"
        return 0
    fi

    if is_env_top "${SC_DIR}"; then
        ENV_TOP="${SC_DIR}"
        ok "build environment found next to this script : ${ENV_TOP}"
        [[ "${ENV_UPDATE}" == "true" ]] && update_env_git
        return 0
    fi

    if is_env_top "${ENV_DIR}"; then
        ENV_TOP="${ENV_DIR}"
        ok "build environment found : ${ENV_TOP}"
        [[ "${ENV_UPDATE}" == "true" ]] && update_env_git
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        ENV_TOP="${ENV_DIR}"
        info "would fetch ${ENV_REPO} (${ENV_REF}) into ${ENV_DIR}"
        return 0
    fi

    if stages_are_read_only; then
        die "no build environment in ${ENV_DIR}, run the installation first or pass --env-dir=PATH"
    fi

    ## the maven build and the source clone happen here, so the caller has to own it
    if [[ ! -d "${ENV_DIR}" ]]; then
        if mkdir -p "${ENV_DIR}" 2>/dev/null; then
            :
        else
            run sudo install -d -o "$(id -un)" -g "$(id -gn)" "${ENV_DIR}"
        fi
    fi
    [[ -w "${ENV_DIR}" ]] || run sudo chown "$(id -un):$(id -gn)" "${ENV_DIR}"
    ## an empty directory is required, a half filled one is refused
    if [[ -n "$(ls -A "${ENV_DIR}" 2>/dev/null)" ]]; then
        die "${ENV_DIR} exists but is not a build environment, empty it or pass --env-dir=PATH"
    fi

    fetch_env_git || fetch_env_tarball || die "cannot fetch ${ENV_REPO} (${ENV_REF})"
    is_env_top "${ENV_DIR}" || die "${ENV_DIR} does not look like a build environment after the download"
    ENV_TOP="${ENV_DIR}"
    ok "build environment ready : ${ENV_TOP}"
    return 0
}

function stage_env
{
    banner "Stage : env - build environment (make rules, templates, pom.xml)"

    ENV_UPDATE="true"
    resolve_env_top
    print_kv "repository" "${ENV_REPO}"
    print_kv "reference"  "${ENV_REF}"
    print_kv "checkout"   "${ENV_TOP}"
    if [[ -d "${ENV_TOP}/.git" ]] && command -v git >/dev/null 2>&1; then
        print_kv "commit" "$(git -C "${ENV_TOP}" log --oneline -1 2>/dev/null || echo unknown)"
    else
        print_kv "commit" "tarball checkout, no git metadata"
    fi
    return 0
}

## ----------------------------------------------------------------------------
## OS detection and privileges
## ----------------------------------------------------------------------------
function detect_os
{
    [[ -r /etc/os-release ]] || die "/etc/os-release is missing, cannot detect the distribution"
    # shellcheck disable=SC1091
    OS_ID="$(. /etc/os-release; echo "${ID:-}")"
    # shellcheck disable=SC1091
    OS_LIKE="$(. /etc/os-release; echo "${ID_LIKE:-}")"
    # shellcheck disable=SC1091
    OS_VERSION_ID="$(. /etc/os-release; echo "${VERSION_ID:-}")"
    # shellcheck disable=SC1091
    OS_PRETTY="$(. /etc/os-release; echo "${PRETTY_NAME:-}")"
    OS_MAJOR="${OS_VERSION_ID%%.*}"

    case " ${OS_ID} ${OS_LIKE} " in
        *" debian "*|*" ubuntu "*)                            OS_FAMILY="debian" ;;
        *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*)     OS_FAMILY="rhel" ;;
        *)  die "unsupported distribution : ${OS_PRETTY}, only the Debian and Rocky/RHEL families are supported" ;;
    esac

    info "distribution : ${OS_PRETTY}  (family ${OS_FAMILY}, major ${OS_MAJOR})"
}

function check_sudo
{
    [[ "$(id -u)" == "0" ]] && \
        die "run ${SC_NAME} as a normal user owning sudo rights, not as root : the make rules call sudo themselves"
    command -v sudo >/dev/null 2>&1 || die "sudo is required but is not installed"
    [[ "${DRY_RUN}" == "true" ]] && return 0

    if ! sudo -n true 2>/dev/null; then
        info "the installation needs sudo privileges, please type your password"
        sudo -v || die "sudo authentication failed"
    fi
    ## keep the sudo timestamp alive during the long build
    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 45; done & ) >/dev/null 2>&1
    return 0
}

function selinux_note
{
    command -v getenforce >/dev/null 2>&1 || return 0
    [[ "$(getenforce 2>/dev/null || echo Disabled)" == "Enforcing" ]] || return 0
    warn "SELinux is Enforcing : the appliance runs as an unconfined systemd service, but if a service"
    warn "cannot write into its storage, check it with 'sudo ausearch -m avc -ts recent'"
}

## ----------------------------------------------------------------------------
## Packages
## ----------------------------------------------------------------------------
## '*.skip_if_unavailable=1' keeps an unrelated broken third party repository
## from blocking the whole installation
DNF_OPTS=(-y "--setopt=*.skip_if_unavailable=1")

function pkg_install
{
    if [[ "${OS_FAMILY}" == "debian" ]]; then
        run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    else
        run sudo dnf "${DNF_OPTS[@]}" install "$@"
    fi
}

## Install the packages one by one, only warn when one of them cannot be installed
function pkg_install_optional
{
    local p rc
    for p in "$@"; do
        if [[ "${DRY_RUN}" == "true" ]]; then
            printf '%s[dry]%s install optional package %s\n' "${C_YEL}" "${C_OFF}" "${p}"
            continue
        fi
        rc=0
        if [[ "${OS_FAMILY}" == "debian" ]]; then
            try_sh "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y '${p}'" >/dev/null 2>&1 || rc=$?
        else
            try_sh "sudo dnf -y '--setopt=*.skip_if_unavailable=1' install '${p}'" >/dev/null 2>&1 || rc=$?
        fi
        if (( rc == 0 )); then
            ok "optional package '${p}' is installed"
        else
            warn "optional package '${p}' could not be installed on ${OS_PRETTY}, skipped"
        fi
    done
}

function pkg_available
{
    local p="$1"
    if [[ "${OS_FAMILY}" == "debian" ]]; then
        [[ -n "$(apt-cache policy "${p}" 2>/dev/null | awk '/Candidate:/ && $2 != "(none)" {print $2}')" ]] && return 0
        return 1
    fi

    local dnfq=(dnf -q "--setopt=*.skip_if_unavailable=1")
    "${dnfq[@]}" list --available "${p}" </dev/null >/dev/null 2>&1 && return 0
    "${dnfq[@]}" list --installed "${p}" </dev/null >/dev/null 2>&1 && return 0
    ## when even a base package cannot be queried, the repository metadata is broken
    if ! "${dnfq[@]}" list --available bash </dev/null >/dev/null 2>&1 \
       && ! "${dnfq[@]}" list --installed bash </dev/null >/dev/null 2>&1; then
        warn "the dnf metadata cannot be read (a repository may be broken), check 'dnf repolist'"
    fi
    return 1
}

## Install the package files carried by the bundle, without touching any repository
function pkgs_from_bundle
{
    local dir="${BUNDLE_WORK}/pkgs"
    if [[ "${OS_FAMILY}" == "debian" ]]; then
        compgen -G "${dir}/*.deb" >/dev/null || { warn "no .deb in the bundle, nothing to install"; return 0; }
        ## dpkg is run twice on purpose : the first pass may leave unconfigured
        ## packages when the dependency order is not the file order
        try_sh "sudo dpkg -i ${dir}/*.deb" || try_sh "sudo dpkg -i ${dir}/*.deb" \
            || die "the packages of the bundle could not be installed"
        try sudo dpkg --configure -a || true
    else
        compgen -G "${dir}/*.rpm" >/dev/null || { warn "no .rpm in the bundle, nothing to install"; return 0; }
        ## --disablerepo='*' : never reach out to a network repository
        if ! try_sh "sudo dnf install -y --disablerepo='*' ${dir}/*.rpm"; then
            error "the packages of the bundle conflict with what this machine already has."
            error "the bundle is built for a machine at the patch level of the machine which"
            error "created it. Either bring this machine to that level from its own mirror,"
            error "or skip the bundled packages and install them yourself :"
            error "    ./${SC_NAME} --bundle=... --force-os ..."
            die "the OS packages could not be installed"
        fi
    fi
    ok "the packages of the bundle are installed"
}

function stage_pkgs
{
    banner "Stage : pkgs - operating system packages"

    if [[ -n "${BUNDLE_WORK}" ]]; then
        if [[ "${WITH_PKGS}" == "true" && -d "${BUNDLE_WORK}/pkgs" ]]; then
            info "installing the OS packages from the bundle"
            pkgs_from_bundle
        else
            warn "the bundle has no OS packages, install them from your own mirror :"
            warn "    $(bundle_pkg_list | tr '\n' ' ')"
        fi
        ## a correct system time is mandatory to archive the signals correctly
        try sudo systemctl enable --now chronyd >/dev/null 2>&1 \
            || try sudo systemctl enable --now chrony >/dev/null 2>&1 \
            || warn "could not enable the NTP service (chrony), please check the system clock yourself"
        return 0
    fi

    if [[ "${OS_FAMILY}" == "debian" ]]; then
        try sudo env DEBIAN_FRONTEND=noninteractive apt-get update -y \
            || warn "apt-get update reported an error, continuing with the cached package lists"
        pkg_install \
            ca-certificates wget curl git sed gawk unzip tar make gcc tree procps \
            python3 python3-pip python3-venv \
            mariadb-server mariadb-client \
            chrony
        ## nice to have, not fatal when a release drops one of them
        pkg_install_optional python-is-python3 libmariadb-dev libmariadb-dev-compat ant jsvc
    else
        run sudo dnf "${DNF_OPTS[@]}" install dnf-plugins-core
        ## CodeReady Builder : 'crb' on EL9+, 'powertools' on EL8
        local crb=""
        if sudo dnf repolist --all 2>/dev/null | grep -qE '^crb[[:space:]]'; then
            crb="crb"
        elif sudo dnf repolist --all 2>/dev/null | grep -qE '^powertools[[:space:]]'; then
            crb="powertools"
        fi
        if [[ -n "${crb}" ]]; then
            ## 'config-manager --set-enabled' is dnf4, 'config-manager setopt' is dnf5
            try sudo dnf config-manager --set-enabled "${crb}" \
                || try sudo dnf config-manager setopt "${crb}.enabled=1" \
                || warn "cannot enable the ${crb} repository"
        fi
        pkg_install_optional epel-release
        pkg_install \
            ca-certificates wget curl git sed gawk unzip tar make gcc libgcc which tree procps-ng \
            python3 python3-pip \
            mariadb-server mariadb \
            chrony
        pkg_install_optional ant apache-commons-daemon-jsvc
    fi

    ## a correct system time is mandatory to archive the signals correctly
    try sudo systemctl enable --now chronyd >/dev/null 2>&1 \
        || try sudo systemctl enable --now chrony >/dev/null 2>&1 \
        || warn "could not enable the NTP service (chrony), please check the system clock yourself"

    ok "the operating system packages are ready"
}

## ----------------------------------------------------------------------------
## JDK, Maven and Ant
## ----------------------------------------------------------------------------
## echo the JAVA_HOME of an installed JDK whose javac is >= ${JDK_MAJOR}
function find_system_jdk
{
    local candidate javac_ver
    for candidate in "${JAVA_ENV_PREFIX}/JDK" \
                     /usr/lib/jvm/java-"${JDK_MAJOR}"-openjdk* \
                     /usr/lib/jvm/temurin-"${JDK_MAJOR}"* \
                     /usr/lib/jvm/jdk-"${JDK_MAJOR}"* \
                     /usr/lib/jvm/*; do
        [[ -x "${candidate}/bin/javac" ]] || continue
        javac_ver="$("${candidate}/bin/javac" -version 2>&1 | awk '{print $2}' | cut -d. -f1)"
        [[ "${javac_ver}" =~ ^[0-9]+$ ]] || continue
        if (( javac_ver >= JDK_MAJOR )); then
            realpath "${candidate}"
            return 0
        fi
    done
    return 1
}

function install_jdk_package
{
    local pkg
    if [[ "${OS_FAMILY}" == "debian" ]]; then
        pkg="openjdk-${JDK_MAJOR}-jdk-headless"
    else
        pkg="java-${JDK_MAJOR}-openjdk-devel"
    fi

    if pkg_available "${pkg}"; then
        info "installing the distribution JDK package ${pkg}"
        pkg_install "${pkg}"
        return 0
    fi
    warn "${pkg} is not available on ${OS_PRETTY}"
    return 1
}

function install_jdk_tarball
{
    local arch url dest tmp
    case "$(uname -m)" in
        x86_64)  arch="x64" ;;
        aarch64) arch="aarch64" ;;
        *) die "unsupported CPU architecture for the Temurin tarball : $(uname -m)" ;;
    esac
    url="https://api.adoptium.net/v3/binary/latest/${JDK_MAJOR}/ga/linux/${arch}/jdk/hotspot/normal/eclipse"
    dest="${JAVA_ENV_PREFIX}/JDK"

    info "downloading the Eclipse Temurin JDK ${JDK_MAJOR} (${arch}) from adoptium.net"
    tmp="$(mktemp -d)"
    try_sh "curl -fsSL '${url}' -o '${tmp}/jdk.tar.gz'" || die "cannot download the JDK tarball, check the network or the proxy settings"
    run sudo install -d "${JAVA_ENV_PREFIX}"
    run sudo rm -rf "${dest}"
    run sudo install -d "${dest}"
    run_sh "sudo tar -C '${dest}' -xzf '${tmp}/jdk.tar.gz' --strip-components=1"
    rm -rf "${tmp}"
    [[ "${DRY_RUN}" == "true" || -x "${dest}/bin/javac" ]] || die "the JDK tarball installation failed"
    ok "JDK ${JDK_MAJOR} is installed in ${dest}"
}

function install_maven_tarball
{
    local src url dest tmp
    src="apache-maven-${MAVEN_VER}-bin.tar.gz"
    url="https://archive.apache.org/dist/maven/maven-3/${MAVEN_VER}/binaries/${src}"
    dest="${JAVA_ENV_PREFIX}/MAVEN"

    info "downloading Apache Maven ${MAVEN_VER}"
    tmp="$(mktemp -d)"
    try_sh "curl -fsSL '${url}' -o '${tmp}/${src}'" || die "cannot download ${url}"
    if try_sh "curl -fsSL '${url}.sha512' -o '${tmp}/${src}.sha512'"; then
        run_sh "cd '${tmp}' && echo \"\$(cat '${src}.sha512')  ${src}\" | sha512sum -c -"
    else
        warn "the sha512 file could not be downloaded, the Maven tarball checksum is not verified"
    fi
    run sudo install -d "${JAVA_ENV_PREFIX}"
    run sudo rm -rf "${dest}"
    run sudo install -d "${dest}"
    run_sh "sudo tar -C '${dest}' -xzf '${tmp}/${src}' --strip-components=1"
    rm -rf "${tmp}"
    [[ "${DRY_RUN}" == "true" || -x "${dest}/bin/mvn" ]] || die "the Maven installation failed"
    ok "Apache Maven ${MAVEN_VER} is installed in ${dest}"
}

## Unpack a tarball of the bundle into a destination directory
function untar_bundle_tarball
{
    local pattern="$1" dest="$2" file
    file="$(compgen -G "${BUNDLE_WORK}/tarballs/${pattern}" | head -1)" || return 1
    [[ -n "${file}" ]] || return 1
    run sudo install -d "$(dirname "${dest}")"
    run sudo rm -rf "${dest}"
    run sudo install -d "${dest}"
    run_sh "sudo tar -C '${dest}' -xzf '${file}' --strip-components=1"
    return 0
}

function stage_java
{
    banner "Stage : java - JDK ${JDK_MAJOR}+, Apache Maven and Apache Ant"

    if [[ -n "${BUNDLE_WORK}" ]]; then
        ## the JDK usually comes from the OS packages of the bundle
        if JAVA_HOME_DETECTED="$(find_system_jdk)"; then
            ok "JDK ${JDK_MAJOR}+ available : ${JAVA_HOME_DETECTED}"
        elif untar_bundle_tarball "temurin-jdk-*.tar.gz" "${JAVA_ENV_PREFIX}/JDK"; then
            ok "the Temurin JDK of the bundle is installed in ${JAVA_ENV_PREFIX}/JDK"
            JAVA_HOME_DETECTED="$(find_system_jdk)" || die "the bundled JDK does not work"
        else
            die "no JDK ${JDK_MAJOR}+ and no JDK in the bundle, rebuild it without --with-jdk=no"
        fi
        info "JAVA_HOME  : ${JAVA_HOME_DETECTED}"

        if [[ -x "${JAVA_ENV_PREFIX}/MAVEN/bin/mvn" ]]; then
            ok "Apache Maven available : ${JAVA_ENV_PREFIX}/MAVEN"
        else
            untar_bundle_tarball "apache-maven-*-bin.tar.gz" "${JAVA_ENV_PREFIX}/MAVEN" \
                || die "no Maven tarball in the bundle"
            ok "the Maven of the bundle is installed in ${JAVA_ENV_PREFIX}/MAVEN"
        fi
        MAVEN_HOME_DETECTED="${JAVA_ENV_PREFIX}/MAVEN"

        [[ -d /usr/share/ant ]] && ANT_HOME_DETECTED="/usr/share/ant" || ANT_HOME_DETECTED=""
        write_local_config
        try_mk info.mvn || warn "make info.mvn failed, check the generated configure/*.local files"
        return 0
    fi

    ## --- JDK ---------------------------------------------------------------
    case "${JAVA_MODE}" in
        pkg)
            install_jdk_package || die "no distribution JDK ${JDK_MAJOR} package, use --java-mode=tarball"
            ;;
        tarball)
            install_jdk_tarball
            ;;
        auto)
            if JAVA_HOME_DETECTED="$(find_system_jdk)"; then
                ok "a JDK ${JDK_MAJOR}+ is already available : ${JAVA_HOME_DETECTED}"
            elif install_jdk_package; then
                info "the distribution JDK package is installed"
            else
                install_jdk_tarball
            fi
            ;;
    esac

    if JAVA_HOME_DETECTED="$(find_system_jdk)"; then
        info "JAVA_HOME  : ${JAVA_HOME_DETECTED}"
    elif [[ "${DRY_RUN}" == "true" ]]; then
        JAVA_HOME_DETECTED="${JAVA_ENV_PREFIX}/JDK"
    else
        die "no JDK ${JDK_MAJOR}+ was found after the installation"
    fi

    ## --- Maven -------------------------------------------------------------
    if [[ -x "${JAVA_ENV_PREFIX}/MAVEN/bin/mvn" ]]; then
        ok "Apache Maven is already available : ${JAVA_ENV_PREFIX}/MAVEN"
    else
        install_maven_tarball
    fi
    MAVEN_HOME_DETECTED="${JAVA_ENV_PREFIX}/MAVEN"

    ## --- Ant, not used by the Maven build, kept for the auxiliary rules ----
    if [[ -d /usr/share/ant ]]; then
        ANT_HOME_DETECTED="/usr/share/ant"
    elif [[ -d /usr/share/java/ant ]]; then
        ANT_HOME_DETECTED="/usr/share/java/ant"
    else
        ANT_HOME_DETECTED=""
        warn "Apache Ant was not found, which is fine for the Maven build"
    fi

    write_local_config
    try_mk info.mvn || warn "make info.mvn failed, please check the generated configure/*.local files"
}

## ----------------------------------------------------------------------------
## configure/*.local generation
## ----------------------------------------------------------------------------
function write_config_file
{
    local dest="$1"; shift
    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '%s[dry]%s would write %s\n' "${C_YEL}" "${C_OFF}" "${dest}"
        return 0
    fi
    printf '%s' "$*" > "${dest}"
    log "--- ${dest} ---"; log "$*"
    ok "generated ${dest}"
}

## Take the value which make currently reports, unless the user gave it on the
## command line. Running './install_aa.sh build' after a customised installation
## must not reset the database or the storage settings.
function seed_from_make
{
    local var="$1" mvar="$2" val
    [[ -n "${OPT_SET[${var}]:-}" ]] && return 0
    val="$(make_var "${mvar}")"
    [[ -n "${val}" ]] && printf -v "${var}" '%s' "${val}"
    return 0
}

function seed_defaults_from_make
{
    seed_from_make DB_NAME        DB_NAME
    seed_from_make DB_USER        DB_USER
    seed_from_make DB_USER_PASS   DB_USER_PASS
    seed_from_make DB_ADMIN       DB_ADMIN
    seed_from_make DB_ADMIN_PASS  DB_ADMIN_PASS
    seed_from_make AA_USER        AA_USERID
    seed_from_make AA_HOST_IPADDR ARCHAPPL_HOST_IPADDR
    seed_from_make STORAGE_TOP    ARCHAPPL_STORAGE_TOP
    return 0
}

function write_local_config
{
    info "generating the configure/*.local files"

    local header="## Generated by ${SC_NAME} on $(date '+%Y-%m-%d %H:%M:%S')
## Remove this file to go back to the repository defaults.
"
    ## TOMCAT_HOME must be the same as TOMCAT_INSTALL_LOCATION, see configure/CONFIG_TOMCAT
    local tomcat_location; tomcat_location="$(make_var TOMCAT_INSTALL_LOCATION)"
    [[ -n "${tomcat_location}" ]] || tomcat_location="/opt/tomcat9"

    write_config_file "${ENV_TOP}/configure/CONFIG_COMMON.local" "${header}
TOMCAT_HOME:=${tomcat_location}

DB_NAME:=${DB_NAME}
DB_USER:=${DB_USER}
DB_USER_PASS:=${DB_USER_PASS}
DB_ADMIN:=${DB_ADMIN}
DB_ADMIN_PASS:=${DB_ADMIN_PASS}

ARCHAPPL_HOST_IPADDR:=${AA_HOST_IPADDR}
"

    [[ -n "${JAVA_HOME_DETECTED}" ]] && write_config_file "${ENV_TOP}/configure/CONFIG_COMMON_JDK.local" "${header}
JAVA_HOME:=${JAVA_HOME_DETECTED}
JAVA_PATH:=${JAVA_HOME_DETECTED}/bin
"

    [[ -n "${MAVEN_HOME_DETECTED}" ]] && write_config_file "${ENV_TOP}/configure/CONFIG_COMMON_MAVEN.local" "${header}
MAVEN_HOME:=${MAVEN_HOME_DETECTED}
MAVEN_PATH:=${MAVEN_HOME_DETECTED}/bin
"

    [[ -n "${ANT_HOME_DETECTED}" ]] && write_config_file "${ENV_TOP}/configure/CONFIG_COMMON_ANT.local" "${header}
ANT_HOME:=${ANT_HOME_DETECTED}
ANT_PATH:=${ANT_HOME_DETECTED}/bin
"

    ## AA_USERID and the storage layout.
    ## The sts/mts/lts variables are expanded with ':=' in configure/CONFIG_SITE,
    ## so all of them have to be redefined when ARCHAPPL_STORAGE_TOP changes.
    local site="${header}
AA_USERID:=${AA_USER}
AA_GROUPID:=${AA_USER}
"
    if [[ -n "${STORAGE_TOP}" ]]; then
        site+="
ARCHAPPL_STORAGE_TOP:=${STORAGE_TOP}
ARCHAPPL_SHORT_TERM_FOLDER:=${STORAGE_TOP}/sts/ArchiverStore
ARCHAPPL_MEDIUM_TERM_FOLDER:=${STORAGE_TOP}/mts/ArchiverStore
ARCHAPPL_LONG_TERM_FOLDER:=${STORAGE_TOP}/lts/ArchiverStore
"
    fi
    write_config_file "${ENV_TOP}/configure/CONFIG_SITE.local" "${site}"

    ## appliance source repository and revision
    if [[ -n "${SRC_TAG}" || -n "${SRC_URL}" ]]; then
        local release="${header}"
        [[ -n "${SRC_URL}" ]] && release+="SRC_URL=${SRC_URL}
"
        [[ -n "${SRC_TAG}" ]] && release+="SRC_TAG:=${SRC_TAG}
SRC_VERSION:=${SRC_TAG}
"
        write_config_file "${ENV_TOP}/configure/RELEASE.local" "${release}"
    fi

    if [[ -n "${CA_ADDR_LIST}" || -n "${CA_AUTO_ADDR_LIST}" ]]; then
        local epicsenv="${header}"
        [[ -n "${CA_ADDR_LIST}" ]]      && epicsenv+="EPICS_CA_ADDR_LIST=${CA_ADDR_LIST}
"
        [[ -n "${CA_AUTO_ADDR_LIST}" ]] && epicsenv+="EPICS_CA_AUTO_ADDR_LIST=${CA_AUTO_ADDR_LIST}
"
        write_config_file "${ENV_TOP}/configure/CONFIG_EPICSENV.local" "${epicsenv}"
    fi
    return 0
}

## ----------------------------------------------------------------------------
## Service account and storage sanity check
## ----------------------------------------------------------------------------
function ensure_aa_user
{
    run sudo bash "${ENV_TOP}/site-template/usergroup.postinst" configure "${AA_USER}" "${AA_USER}"
}

## Early and cheap advisory check : the service account is usually not a member
## of the invoking user group, so a 0700 home directory hides the storage.
function warn_storage_early
{
    local storage dir
    storage="${STORAGE_TOP:-$(make_var ARCHAPPL_STORAGE_TOP)}"
    [[ -n "${storage}" ]] || return 0
    dir="${storage}"
    while [[ "${dir}" != "/" && -n "${dir}" ]]; do
        if [[ -d "${dir}" && "$(stat -c '%A' "${dir}" 2>/dev/null | cut -c10)" != "x" ]]; then
            warn "${dir} is not traversable by other users, so the service account '${AA_USER}'"
            warn "may not be able to write the archived data into ${storage}."
            warn "consider  --storage=/var/lib/archappl  or  chmod o+x ${dir}"
            return 0
        fi
        dir="$(dirname "${dir}")"
    done
    return 0
}

function check_storage_access
{
    local storage; storage="${STORAGE_TOP:-$(make_var ARCHAPPL_STORAGE_TOP)}"
    [[ -n "${storage}" ]] || return 0
    [[ "${DRY_RUN}" == "true" ]] && return 0
    id "${AA_USER}" >/dev/null 2>&1 || return 0

    ## every existing parent directory has to be traversable by the service account
    local dir="${storage}" bad=""
    while [[ "${dir}" != "/" && -n "${dir}" ]]; do
        if [[ -d "${dir}" ]] && ! sudo -u "${AA_USER}" test -x "${dir}" 2>/dev/null; then
            bad="${dir}"
        fi
        dir="$(dirname "${dir}")"
    done

    if [[ -n "${bad}" ]]; then
        error "the service account '${AA_USER}' cannot enter ${bad}, so the appliance"
        error "would not be able to write its data into ${storage}."
        error "use another storage location or open that directory, for example :"
        error "    ./${SC_NAME} --storage=/var/lib/archappl ${REQUESTED_STAGES[*]}"
        error "    chmod o+x ${bad}"
        die "the storage location is not usable by ${AA_USER}"
    fi
    ok "the storage ${storage} is reachable by ${AA_USER}"
}

## ----------------------------------------------------------------------------
## Stages
## ----------------------------------------------------------------------------
## The repository scripts open their administrative connection with
## 'sudo mysql --user=root'. On some EL systems the data directory is
## initialised by the 'mysql' system user, so the only all privilege socket
## account which exists afterwards is mysql@localhost and root@localhost is
## missing. Recreate it with unix_socket authentication in that case.
function ensure_db_root_access
{
    [[ "${DRY_RUN}" == "true" ]] && return 0

    if sudo mysql --user=root -e 'SELECT 1' >/dev/null 2>&1; then
        ok "MariaDB root@localhost answers through the unix socket"
        return 0
    fi

    warn "'sudo mysql --user=root' is refused, looking for another all privilege socket account"
    local sysuser
    for sysuser in mysql mariadb; do
        id "${sysuser}" >/dev/null 2>&1 || continue
        sudo -u "${sysuser}" mysql --user="${sysuser}" -e 'SELECT 1' >/dev/null 2>&1 || continue
        info "creating root@localhost (unix_socket) through the ${sysuser}@localhost account"
        run_sh "sudo -u ${sysuser} mysql --user=${sysuser} -e \"CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED VIA unix_socket; GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;\""
        if sudo mysql --user=root -e 'SELECT 1' >/dev/null 2>&1; then
            ok "root@localhost now answers with 'sudo mysql'"
            return 0
        fi
    done

    error "no administrative MariaDB connection is available."
    error "the repository scripts need 'sudo mysql --user=root' to work, repair it with"
    error "    sudo mariadb-secure-installation"
    die "cannot administrate the MariaDB server"
}

function stage_db
{
    banner "Stage : db - MariaDB configuration"

    run sudo systemctl enable --now mariadb
    try systemctl --no-pager --full status mariadb || true
    ensure_db_root_access

    ## the repository scripts call the 'mysql' client explicitly
    if ! command -v mysql >/dev/null 2>&1 && command -v mariadb >/dev/null 2>&1; then
        warn "no 'mysql' client found, adding the compatibility symlink /usr/local/bin/mysql"
        run_sh "sudo ln -sf '$(command -v mariadb)' /usr/local/bin/mysql"
        if ! command -v mysqldump >/dev/null 2>&1 && command -v mariadb-dump >/dev/null 2>&1; then
            run_sh "sudo ln -sf '$(command -v mariadb-dump)' /usr/local/bin/mysqldump"
        fi
    fi

    if [[ "${DB_USER_PASS}" == "archappl" || "${DB_ADMIN_PASS}" == "admin" ]]; then
        warn "the default MariaDB passwords are in use, change them with --db-pass and --db-admin-pass on a production system"
    fi

    mk db.conf
    mk db.secure
    mk db.addAdmin
    mk db.create
    mk db.show
    mk sql.fill
    mk sql.show

    ok "the '${DB_NAME}' database, its user and its tables are ready"
}

function stage_tomcat
{
    banner "Stage : tomcat - Apache Tomcat 9"

    ensure_aa_user
    local location; location="$(make_var TOMCAT_INSTALL_LOCATION)"

    if [[ -e "${location}/bin/catalina.sh" ]]; then
        ok "Tomcat is already installed in ${location}"
    elif [[ -n "${BUNDLE_WORK}" ]]; then
        ## 'make tomcat.get' downloads, so the tarball is put in place by hand
        ## and only 'make tomcat.install' is used
        local tomcat_src; tomcat_src="$(make_var TOMCAT_SRC)"
        [[ -e "${BUNDLE_WORK}/tarballs/${tomcat_src}" ]] \
            || die "${tomcat_src} is not in the bundle, it was created for another Tomcat version"
        info "taking ${tomcat_src} from the bundle"
        run cp -f "${BUNDLE_WORK}/tarballs/${tomcat_src}" "${ENV_TOP}/${tomcat_src}"
        mk tomcat.install
    else
        mk tomcat.get
        mk tomcat.install
    fi
    try_mk tomcat.exist || true
}

function stage_src
{
    banner "Stage : src - appliance source code"

    local src_path; src_path="$(make_var SRC_PATH)"

    ## The bundle carries the source as a git repository, inside the environment
    ## it was cloned into : the make rules read its history (src_version) and so
    ## does the pom (RELEASE_NOTES).
    if [[ -n "${BUNDLE_WORK}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            info "would use the appliance source of the bundle, $(bundle_manifest_value src_commit)"
            mk pom
            return 0
        fi
        if [[ ! -d "${ENV_TOP}/${src_path}" && -d "${BUNDLE_WORK}/src" ]]; then
            info "copying the appliance source of the bundle into ${ENV_TOP}/${src_path}"
            run_sh "cp -a '${BUNDLE_WORK}/src' '${ENV_TOP}/${src_path}'"
        fi
        [[ -d "${ENV_TOP}/${src_path}" ]] || die "the bundle carries no appliance source"
        [[ -d "${ENV_TOP}/${src_path}/.git" ]] || warn "the bundled source is not a git repository, 'make install' may fail"
        ok "appliance source : ${ENV_TOP}/${src_path}  ($(git -C "${ENV_TOP}/${src_path}" log --oneline -1 2>/dev/null || echo 'no git history'))"
        mk pom
        return 0
    fi

    if [[ -d "${ENV_TOP}/${src_path}/.git" ]]; then
        ok "the source code is already cloned into ${ENV_TOP}/${src_path}"
        [[ -n "${SRC_TAG}" ]] && mk srcupdate
        mk pom
    else
        mk init
    fi
    return 0
}

## pom.xml packs ${docs.dir}/docs/build into the mgmt war, and the war plugin
## fails when that directory is missing. Sphinx creates it, so skipping Sphinx
## on a fresh source tree needs the empty directory to exist.
function ensure_docs_build_dir
{
    local src_path docs_build
    src_path="$(make_var SRC_PATH)"
    docs_build="${ENV_TOP}/${src_path}/docs/docs/build"
    [[ -d "${docs_build}" ]] && return 0
    warn "no Sphinx output in ${docs_build}, creating it empty :"
    warn "the mgmt web application will have no documentation pages"
    run mkdir -p "${docs_build}"
    return 0
}

## Tell the user what to do with the Maven failure which just happened
function diagnose_build_failure
{
    local tail_log; tail_log="$(tail -300 "${LOG_FILE}" 2>/dev/null)"
    error "the Maven build failed"
    if grep -qE "Unrecognized option|Could not create the Java Virtual Machine" <<< "${tail_log}"; then
        error "the JVM refused an option : \$(MAVEN_OPTS) of the make rules is also exported"
        error "as the MAVEN_OPTS environment variable, which the mvn launcher reads as JVM"
        error "options. Only JVM safe options (-D...) belong in --maven-opts."
    elif grep -qE "Could not transfer artifact|Connection reset|Connection timed out|UnknownHostException|PKIX" <<< "${tail_log}"; then
        error "Maven could not download every dependency, this is a network or a proxy problem."
        error "the downloads resume where they stopped, so simply run it again :"
        error "    ./${SC_NAME} build install service"
    elif grep -qE "build_docs\.sh|sphinx-build|docs/docs/build" <<< "${tail_log}"; then
        error "the Sphinx documentation build failed, run again without the documentation :"
        error "    ./${SC_NAME} --skip-docs build install service"
    else
        error "look at the Maven output in ${LOG_FILE}"
        error "when the failure comes from the Sphinx documentation, run again with --skip-docs"
    fi
    exit 1
}

function stage_build
{
    banner "Stage : build - Maven build of the WAR files"

    check_storage_access

    ## the repository puts $(MAVEN_OPTS) on the mvn command line, keep what is
    ## already configured there and add the network and the user options
    local mopts; mopts="$(make_var MAVEN_OPTS) ${MAVEN_NET_OPTS} ${MAVEN_USER_OPTS}"

    if [[ -n "${BUNDLE_WORK}" ]]; then
        [[ -d "${BUNDLE_WORK}/m2" ]] || die "the bundle has no Maven repository, it is incomplete"
        ## Maven writes into its local repository, so the bundle copy is merged
        ## into the one of this user instead of being used read only
        local m2="${HOME}/.m2/repository"
        info "merging the Maven repository of the bundle into ${m2}"
        run mkdir -p "${m2}"
        run_sh "cp -an '${BUNDLE_WORK}/m2/.' '${m2}/' 2>/dev/null || true"
        ## Offline mode cannot travel through $(MAVEN_OPTS) : make exports its
        ## command line variables, and the mvn launcher reads the MAVEN_OPTS
        ## environment variable as JVM options, where -o is not valid. Maven 3.9
        ## reads its own command line arguments from MAVEN_ARGS instead.
        mopts="$(make_var MAVEN_OPTS) -Dmaven.repo.local=${m2} ${MAVEN_USER_OPTS}"
        export MAVEN_ARGS="-o"
        info "Maven runs offline (MAVEN_ARGS=-o), local repository ${m2}"
        if [[ "${SKIP_DOCS}" != "true" ]]; then
            info "the Sphinx documentation needs pip and a network, building with -Dsphinx.skip=true"
            SKIP_DOCS="true"
        fi
    fi

    if [[ "${SKIP_DOCS}" == "true" ]]; then
        info "building without the Sphinx documentation (-Dsphinx.skip=true)"
        ensure_docs_build_dir
        mk conf
        try_mk build.mvn2 MAVEN_OPTS="${mopts}" || diagnose_build_failure
    else
        try_mk build MAVEN_OPTS="${mopts}" || diagnose_build_failure
    fi

    [[ "${DRY_RUN}" == "true" ]] && return 0
    local wars; wars="$(make_var ARCHAPPL_WARS_TARGET_PATH)"
    compgen -G "${wars}/*.war" >/dev/null || die "no WAR file was produced in ${wars}"
    ok "WAR files : $(compgen -G "${wars}/*.war" | tr '\n' ' ')"
}

function stage_install
{
    banner "Stage : install - appliance and systemd unit"

    ensure_aa_user
    check_storage_access
    mk install
    try_mk exist || true
}

function stage_service
{
    banner "Stage : service - systemd service"

    local unit; unit="$(make_var SYSTEMD_FILENAME)"
    run sudo systemctl daemon-reload
    try_mk sd_enable || true
    run sudo systemctl restart "${unit}"
    try systemctl --no-pager --full status "${unit}" || true

    [[ "${OPEN_FIREWALL}" == "true" ]] && open_firewall
    return 0
}

function open_firewall
{
    local port
    if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
        for port in "${AA_PORTS[@]}"; do
            run sudo firewall-cmd --permanent --add-port="${port}/tcp"
        done
        run sudo firewall-cmd --reload
        ok "firewalld : the ports ${AA_PORTS[*]} are open"
    elif command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        for port in "${AA_PORTS[@]}"; do
            run sudo ufw allow "${port}/tcp"
        done
        ok "ufw : the ports ${AA_PORTS[*]} are open"
    else
        warn "no active firewalld or ufw was found, no port was opened"
    fi
}

function stage_verify
{
    banner "Stage : verify - is the appliance answering ?"

    local mgmt_port; mgmt_port="$(make_var ARCHAPPL_MGMT_PORT)"
    [[ -n "${mgmt_port}" ]] || mgmt_port="${AA_PORTS[0]}"
    local url="http://localhost:${mgmt_port}/mgmt/ui/index.html"
    local unit; unit="$(make_var SYSTEMD_FILENAME)"

    if [[ "${DRY_RUN}" == "true" ]]; then
        info "would wait for ${url}"
        print_summary
        return 0
    fi

    local i=0 rc=1
    printf 'waiting for %s ' "${url}"
    while (( i < 60 )); do
        if [[ "$(curl -s -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)" == "200" ]]; then
            rc=0; break
        fi
        printf '.'; sleep 2; (( ++i ))
    done
    printf '\n'

    if (( rc == 0 )); then
        ok "the management web application answers on ${url}"
    else
        warn "the appliance did not answer within 120 seconds, have a look at"
        warn "    sudo systemctl status ${unit}"
        warn "    tail -f $(make_var AA_INSTALL_LOCATION)/mgmt/logs/archappl_service.log"
    fi

    print_summary
    return 0
}

## ----------------------------------------------------------------------------
## Read only stages : where is what, what exists, what is running
## ----------------------------------------------------------------------------
function print_kv { printf '  %-24s %s\n' "$1" "$2"; }

## print_state <label> <ok|no> <detail>
function print_state
{
    local mark
    if [[ "$2" == "ok" ]]; then mark="${C_GRN}[ OK]${C_OFF}"; else mark="${C_YEL}[ --]${C_OFF}"; fi
    printf '  %b %-22s %s\n' "${mark}" "$1" "$3"
}

function stage_paths
{
    banner "Stage : paths - where everything is"

    local storage; storage="${STORAGE_TOP:-$(make_var ARCHAPPL_STORAGE_TOP)}"

    printf '%sInstaller and build environment%s\n' "${C_BLU}" "${C_OFF}"
    print_kv "installer"               "${SC_SCRIPT}"
    print_kv "environment repository"  "${ENV_REPO} (${ENV_REF})"
    print_kv "environment"             "${ENV_TOP}"
    print_kv "source repository"       "$(make_var SRC_GITURL)"
    printf '\n%sInstallation%s\n' "${C_BLU}" "${C_OFF}"
    print_kv "appliance"               "$(make_var AA_INSTALL_LOCATION)"
    print_kv "services"                "$(make_var ARCHAPPL_SERVICES)"
    print_kv "source code"             "${ENV_TOP}/$(make_var SRC_PATH)  ($(make_var SRC_TAG))"
    print_kv "WAR files"               "$(make_var ARCHAPPL_WARS_TARGET_PATH)"
    print_kv "main script"             "$(make_var AA_INSTALL_LOCATION)/$(make_var ARCHAPPL_MAIN_SCRIPT)"
    printf '\n%sStorage%s\n' "${C_BLU}" "${C_OFF}"
    print_kv "storage top"             "${storage}"
    print_kv "short term (sts)"        "$(make_var ARCHAPPL_SHORT_TERM_FOLDER)"
    print_kv "medium term (mts)"       "$(make_var ARCHAPPL_MEDIUM_TERM_FOLDER)"
    print_kv "long term (lts)"         "$(make_var ARCHAPPL_LONG_TERM_FOLDER)"
    printf '\n%sJava and Tomcat%s\n' "${C_BLU}" "${C_OFF}"
    print_kv "JAVA_HOME"               "$(make_var JAVA_HOME)"
    print_kv "MAVEN_HOME"              "$(make_var MAVEN_HOME)"
    print_kv "TOMCAT_HOME"             "$(make_var TOMCAT_HOME)"
    printf '\n%sService and network%s\n' "${C_BLU}" "${C_OFF}"
    print_kv "service account"         "$(make_var AA_USERID):$(make_var AA_GROUPID)"
    print_kv "systemd unit"            "$(make_var SYSTEMD_PATH)/$(make_var SYSTEMD_FILENAME)"
    print_kv "mgmt / web UI"           "http://$(make_var ARCHAPPL_HOST_IPADDR):$(make_var ARCHAPPL_MGMT_PORT)/mgmt/ui/index.html"
    print_kv "engine / etl / retrieval" "$(make_var ARCHAPPL_ENGINE_PORT) / $(make_var ARCHAPPL_ETL_PORT) / $(make_var ARCHAPPL_RETRIEVAL_PORT)"
    print_kv "EPICS_CA_ADDR_LIST"      "$(make_var EPICS_CA_ADDR_LIST)"
    printf '\n%sDatabase%s\n' "${C_BLU}" "${C_OFF}"
    print_kv "database"                "$(make_var DB_NAME) at $(make_var DB_HOST_NAME):$(make_var DB_HOST_PORT)"
    print_kv "database user"           "$(make_var DB_USER)"
    printf '\n%sGenerated configuration%s\n' "${C_BLU}" "${C_OFF}"
    local f
    for f in "${ENV_TOP}"/configure/*.local; do
        [[ -e "${f}" ]] && print_kv "$(basename "${f}")" "${f}"
    done
    print_kv "install log"             "${LOG_FILE}"
    printf '\n'
    return 0
}

function stage_exist
{
    banner "Stage : exist - what is installed"

    local jdk mvn tomcat src wars aa unit storage active
    jdk="$(make_var JAVA_HOME)"
    mvn="$(make_var MAVEN_HOME)"
    tomcat="$(make_var TOMCAT_HOME)"
    src="${ENV_TOP}/$(make_var SRC_PATH)"
    wars="$(make_var ARCHAPPL_WARS_TARGET_PATH)"
    aa="$(make_var AA_INSTALL_LOCATION)"
    unit="$(make_var SYSTEMD_FILENAME)"
    storage="${STORAGE_TOP:-$(make_var ARCHAPPL_STORAGE_TOP)}"

    [[ -x "${jdk}/bin/java" ]] \
        && print_state "JDK" ok "${jdk}  ($("${jdk}/bin/java" -version 2>&1 | head -1))" \
        || print_state "JDK" no "${jdk} is missing, run : ./${SC_NAME} java"
    [[ -x "${mvn}/bin/mvn" ]] \
        && print_state "Maven" ok "${mvn}" \
        || print_state "Maven" no "${mvn} is missing, run : ./${SC_NAME} java"
    ## '-e' and not '-x' : the Tomcat files belong to the service account and are
    ## not readable by the user who runs this script
    [[ -e "${tomcat}/bin/catalina.sh" ]] \
        && print_state "Tomcat" ok "${tomcat}" \
        || print_state "Tomcat" no "${tomcat} is missing, run : ./${SC_NAME} tomcat"
    [[ -d "${src}/.git" ]] \
        && print_state "source code" ok "${src}" \
        || print_state "source code" no "${src} is missing, run : ./${SC_NAME} src"
    compgen -G "${wars}/*.war" >/dev/null \
        && print_state "WAR files" ok "$(compgen -G "${wars}/*.war" | wc -l) file(s) in ${wars}" \
        || print_state "WAR files" no "nothing in ${wars}, run : ./${SC_NAME} build"
    [[ -d "${aa}" ]] \
        && print_state "appliance" ok "${aa}" \
        || print_state "appliance" no "${aa} is missing, run : ./${SC_NAME} install"
    [[ -d "${storage}" ]] \
        && print_state "storage" ok "${storage}  ($(du -sh "${storage}" 2>/dev/null | cut -f1) used)" \
        || print_state "storage" no "${storage} does not exist yet"
    [[ -f "$(make_var SYSTEMD_PATH)/${unit}" ]] \
        && print_state "systemd unit" ok "$(make_var SYSTEMD_PATH)/${unit}" \
        || print_state "systemd unit" no "not installed, run : ./${SC_NAME} install"

    active="$(systemctl is-active mariadb 2>/dev/null || true)"
    [[ "${active}" == "active" ]] \
        && print_state "mariadb" ok "active" \
        || print_state "mariadb" no "${active:-unknown}, run : ./${SC_NAME} db"

    active="$(systemctl is-active "${unit}" 2>/dev/null || true)"
    [[ "${active}" == "active" ]] \
        && print_state "appliance service" ok "active ($(systemctl is-enabled "${unit}" 2>/dev/null || echo 'not enabled'))" \
        || print_state "appliance service" no "${active:-unknown}, run : ./${SC_NAME} service"

    local url; url="http://localhost:$(make_var ARCHAPPL_MGMT_PORT)/mgmt/ui/index.html"
    if [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)" == "200" ]]; then
        print_state "web application" ok "${url}"
    else
        print_state "web application" no "${url} does not answer"
    fi
    printf '\n'
    return 0
}

function stage_status
{
    banner "Stage : status - service status"

    local unit; unit="$(make_var SYSTEMD_FILENAME)"
    try systemctl --no-pager --full status "${unit}" || true

    ## The pid files below $(AA_INSTALL_LOCATION) belong to the service account,
    ## so read the state from the process table and from the listening sockets
    ## instead : this works as a normal user.
    local install_location services svc pid port
    install_location="$(make_var AA_INSTALL_LOCATION)"
    services="$(make_var ARCHAPPL_SERVICES)"

    printf '\n%sAppliance services%s\n' "${C_BLU}" "${C_OFF}"
    for svc in ${services}; do
        case "${svc}" in
            mgmt)      port="$(make_var ARCHAPPL_MGMT_PORT)" ;;
            engine)    port="$(make_var ARCHAPPL_ENGINE_PORT)" ;;
            etl)       port="$(make_var ARCHAPPL_ETL_PORT)" ;;
            retrieval) port="$(make_var ARCHAPPL_RETRIEVAL_PORT)" ;;
            *)         port="" ;;
        esac
        pid="$(pgrep -f "${install_location}/${svc}" 2>/dev/null | head -1)"
        if [[ -n "${pid}" ]] && ss -lnt 2>/dev/null | grep -q ":${port}\b"; then
            print_state "${svc}" ok "pid ${pid}, listening on ${port}"
        elif [[ -n "${pid}" ]]; then
            print_state "${svc}" no "pid ${pid} but nothing listens on ${port}"
        else
            print_state "${svc}" no "not running, log : ${install_location}/${svc}/logs/archappl_service.log"
        fi
    done

    printf '\n%sArchived PVs%s\n' "${C_BLU}" "${C_OFF}"
    local pvs; pvs="$(curl -s -m 5 "http://localhost:$(make_var ARCHAPPL_MGMT_PORT)/mgmt/bpl/getAllPVs" 2>/dev/null || true)"
    if [[ -n "${pvs}" ]]; then
        print_kv "getAllPVs" "${pvs:0:200}"
    else
        print_kv "getAllPVs" "the mgmt web application does not answer"
    fi
    printf '\n'
    return 0
}

function stage_uninstall
{
    banner "Stage : uninstall"

    ask_yes "remove $(make_var AA_INSTALL_LOCATION) and the systemd service ?" || { info "cancelled"; return 0; }
    mk uninstall
    ok "the appliance is removed, the database and Tomcat are kept"
}

## ----------------------------------------------------------------------------
## Summary
## ----------------------------------------------------------------------------
function print_summary
{
    local install_location storage unit
    install_location="$(make_var AA_INSTALL_LOCATION)"
    storage="${STORAGE_TOP:-$(make_var ARCHAPPL_STORAGE_TOP)}"
    unit="$(make_var SYSTEMD_FILENAME)"

    cat <<EOF

${C_GRN}============================================================
 EPICS Archiver Appliance : installation summary
============================================================${C_OFF}

  Web UI           : http://$(hostname):${AA_PORTS[0]}/mgmt/ui/index.html
                     http://localhost:${AA_PORTS[0]}/mgmt/ui/index.html
  Installed in     : ${install_location}
  Storage          : ${storage}   (sts / mts / lts)
  Service account  : ${AA_USER}
  systemd unit     : ${unit}
  Database         : ${DB_NAME}  (user ${DB_USER})
  JAVA_HOME        : $(make_var JAVA_HOME)
  MAVEN_HOME       : $(make_var MAVEN_HOME)
  TOMCAT_HOME      : $(make_var TOMCAT_HOME)
  Log file         : ${LOG_FILE}

  Useful commands

    sudo systemctl status ${unit}
    cd ${ENV_TOP} && make sd_status
    cd ${ENV_TOP} && make vars FILTER=ARCHAPPL
    ./${SC_NAME} status
    tail -f ${install_location}/mgmt/logs/archappl_service.log

  Rebuild and redeploy after a configuration change

    ./${SC_NAME} build install service

EOF
}

## ----------------------------------------------------------------------------
## main
## ----------------------------------------------------------------------------
function main
{
    parse_args "$@"

    : > "${LOG_FILE}" 2>/dev/null || LOG_FILE="/tmp/install_full_aa.$$.log"
    log "### ${SC_NAME} started on $(date) : $*"

    banner "EPICS Archiver Appliance : standalone installation"
    info "installer   : ${SC_SCRIPT}"
    info "environment : ${ENV_REPO} (${ENV_REF})"
    info "stages      : ${REQUESTED_STAGES[*]}"
    info "log file    : ${LOG_FILE}"

    detect_os
    if stages_are_read_only; then
        info "read only stages, no sudo needed"
    else
        check_sudo
        selinux_note
    fi

    trap close_bundle EXIT
    open_bundle

    ## the build environment carries the make rules and the templates, so it has
    ## to be there before anything else is read or built
    if stages_are_bundle_only; then
        ## 'bundle' clones its own environment, this machine is left alone
        info "creating a bundle only, the configuration of this machine is not touched"
    else
        if [[ -n "${BUNDLE_WORK}" ]]; then
            ensure_bundle_bootstrap
        else
            ensure_bootstrap_tools
        fi
        resolve_env_top
    fi
    command -v make >/dev/null 2>&1 || die "'make' is required, install it first : apt-get install make / dnf install make"

    ## Values not given on the command line keep whatever the repository is
    ## currently configured with.
    stages_are_bundle_only || seed_defaults_from_make

    ## The java stage regenerates the configure/*.local files by itself. When it
    ## is not part of this run, refresh them from what is installed here so that
    ## the command line options are always taken into account.
    local s java_stage="false"
    for s in "${REQUESTED_STAGES[@]}"; do
        [[ "${s}" == "java" ]] && java_stage="true"
    done
    if [[ "${java_stage}" == "false" ]] && ! stages_are_read_only && ! stages_are_bundle_only; then
        JAVA_HOME_DETECTED="$(make_var JAVA_HOME)"
        [[ -x "${JAVA_HOME_DETECTED}/bin/javac" ]] || JAVA_HOME_DETECTED="$(find_system_jdk || true)"
        MAVEN_HOME_DETECTED="$(make_var MAVEN_HOME)"
        [[ -x "${MAVEN_HOME_DETECTED}/bin/mvn" ]] || MAVEN_HOME_DETECTED=""
        ANT_HOME_DETECTED="$(make_var ANT_HOME)"
        [[ -d "${ANT_HOME_DETECTED}" ]] || ANT_HOME_DETECTED=""
        write_local_config
    fi

    if ! stages_are_read_only && ! stages_are_bundle_only; then warn_storage_early; fi

    local stage
    for stage in "${REQUESTED_STAGES[@]}"; do
        "stage_${stage}"
        ok "stage '${stage}' is done"
    done

    ## when 'verify' was not requested, still show the summary after a real
    ## installation stage, but not after the read only or the uninstall ones
    local summary="false"
    for stage in "${REQUESTED_STAGES[@]}"; do
        [[ "${stage}" == "env" ]] && continue      # fetching the environment installs nothing
        for s in "${ALL_STAGES[@]}"; do
            [[ "${stage}" == "${s}" ]] && summary="true"
        done
        [[ "${stage}" == "verify" ]] && summary="false" && break
    done
    [[ "${summary}" == "true" ]] && print_summary

    ok "all the requested stages are done"
    return 0
}

main "$@"
