#!/bin/bash -l

# StringTie App wrapper script


###############################################################################
#### Helper Functions ####
###############################################################################

## ****************************************************************************
## Usage description should match command line arguments defined below
usage () {
    echo "Usage: $(basename "$0")"
    echo "  --bam => Input BAM File"
    echo "  --gtf => Input GTF File"
    echo "  --output => Output Directory"
    echo "  --exec_method => Execution method (docker, auto)"
    echo "  --exec_init => Execution initialization command(s)"
    echo "  --help => Display this help message"
}
## ****************************************************************************

# report error code for command
safeRunCommand() {
    cmd="$@"
    eval "$cmd; "'PIPESTAT=("${PIPESTATUS[@]}")'
    for i in ${!PIPESTAT[@]}; do
        if [ ${PIPESTAT[$i]} -ne 0 ]; then
            echo "Error when executing command #${i}: '${cmd}'"
            exit ${PIPESTAT[$i]}
        fi
    done
}

# print message and exit
fail() {
    msg="$@"
    echo "${msg}"
    usage
    exit 1
}

# always report exit code
reportExit() {
    rv=$?
    echo "Exit code: ${rv}"
    exit $rv
}

trap "reportExit" EXIT

# check if string contains another string
contains() {
    string="$1"
    substring="$2"

    if test "${string#*$substring}" != "$string"; then
        return 0    # $substring is not in $string
    else
        return 1    # $substring is in $string
    fi
}



###############################################################################
## SCRIPT_DIR: directory of current script, depends on execution
## environment, which may be detectable using environment variables
###############################################################################
if [ -z "${AGAVE_JOB_ID}" ]; then
    # not an agave job
    SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
else
    echo "Agave job detected"
    SCRIPT_DIR=$(pwd)
fi
## ****************************************************************************



###############################################################################
#### Parse Command-Line Arguments ####
###############################################################################

getopt --test > /dev/null
if [ $? -ne 4 ]; then
    echo "`getopt --test` failed in this environment."
    exit 1
fi

## ****************************************************************************
## Command line options should match usage description
OPTIONS=
LONGOPTIONS=help,exec_method:,exec_init:,bam:,gtf:,output:,
## ****************************************************************************

# -temporarily store output to be able to check for errors
# -e.g. use "--options" parameter by name to activate quoting/enhanced mode
# -pass arguments only via   -- "$@"   to separate them correctly
PARSED=$(\
    getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@"\
)
if [ $? -ne 0 ]; then
    # e.g. $? == 1
    #  then getopt has complained about wrong arguments to stdout
    usage
    exit 2
fi

# read getopt's output this way to handle the quoting right:
eval set -- "$PARSED"

## ****************************************************************************
## Set any defaults for command line options
EXEC_METHOD="auto"
EXEC_INIT=":"
## ****************************************************************************

## ****************************************************************************
## Handle each command line option. Lower-case variables, e.g., ${file}, only
## exist if they are set as environment variables before script execution.
## Environment variables are used by Agave. If the environment variable is not
## set, the Upper-case variable, e.g., ${FILE}, is assigned from the command
## line parameter.
while true; do
    case "$1" in
        --help)
            usage
            exit 0
            ;;
        --bam)
            if [ -z "${bam}" ]; then
                BAM=$2
            else
                BAM="${bam}"
            fi
            shift 2
            ;;
        --gtf)
            if [ -z "${gtf}" ]; then
                GTF=$2
            else
                GTF="${gtf}"
            fi
            shift 2
            ;;
        --output)
            if [ -z "${output}" ]; then
                OUTPUT=$2
            else
                OUTPUT="${output}"
            fi
            shift 2
            ;;
        --exec_method)
            if [ -z "${exec_method}" ]; then
                EXEC_METHOD=$2
            else
                EXEC_METHOD="${exec_method}"
            fi
            shift 2
            ;;
        --exec_init)
            if [ -z "${exec_init}" ]; then
                EXEC_INIT=$2
            else
                EXEC_INIT="${exec_init}"
            fi
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Invalid option"
            usage
            exit 3
            ;;
    esac
done
## ****************************************************************************

## ****************************************************************************
## Log any variables passed as inputs
echo "Bam: ${BAM}"
echo "Gtf: ${GTF}"
echo "Output: ${OUTPUT}"
echo "Execution Method: ${EXEC_METHOD}"
echo "Execution Initialization: ${EXEC_INIT}"
## ****************************************************************************



###############################################################################
#### Validate and Set Variables ####
###############################################################################

## ****************************************************************************
## Add app-specific logic for handling and parsing inputs and parameters

# BAM input

if [ -z "${BAM}" ]; then
    echo "Input BAM File required"
    echo
    usage
    exit 1
fi
# make sure BAM is staged
count=0
while [ ! -f "${BAM}" ]
do
    echo "${BAM} not staged, waiting..."
    sleep 1
    count=$((count+1))
    if [ $count == 10 ]; then break; fi
done
if [ ! -f "${BAM}" ]; then
    echo "Input BAM File not found: ${BAM}"
    exit 1
fi
BAM_FULL=$(readlink -f "${BAM}")
BAM_DIR=$(dirname "${BAM_FULL}")
BAM_BASE=$(basename "${BAM_FULL}")


# GTF input

if [ -z "${GTF}" ]; then
    echo "Input GTF File required"
    echo
    usage
    exit 1
fi
# make sure GTF is staged
count=0
while [ ! -f "${GTF}" ]
do
    echo "${GTF} not staged, waiting..."
    sleep 1
    count=$((count+1))
    if [ $count == 10 ]; then break; fi
done
if [ ! -f "${GTF}" ]; then
    echo "Input GTF File not found: ${GTF}"
    exit 1
fi
GTF_FULL=$(readlink -f "${GTF}")
GTF_DIR=$(dirname "${GTF_FULL}")
GTF_BASE=$(basename "${GTF_FULL}")



# OUTPUT parameter
if [ -n "${OUTPUT}" ]; then
    :
    OUTPUT_FULL=$(readlink -f "${OUTPUT}")
    OUTPUT_DIR=$(dirname "${OUTPUT_FULL}")
    OUTPUT_BASE=$(basename "${OUTPUT_FULL}")
    LOG_FULL="${OUTPUT_DIR}/_log"
    TMP_FULL="${OUTPUT_DIR}/_tmp"
else
    :
    echo "Output Directory required"
    echo
    usage
    exit 1
fi

## ****************************************************************************

## EXEC_METHOD: execution method
## Suggested possible options:
##   auto: automatically determine execution method
##   singularity: singularity image packaged with the app
##   docker: docker containers from docker-hub
##   environment: binaries available in environment path

## ****************************************************************************
## List supported execution methods for this app (space delimited)
exec_methods="docker auto"
## ****************************************************************************

## ****************************************************************************
# make sure the specified execution method is included in list
if ! contains " ${exec_methods} " " ${EXEC_METHOD} "; then
    echo "Invalid execution method: ${EXEC_METHOD}"
    echo
    usage
    exit 1
fi
## ****************************************************************************



###############################################################################
#### App Execution Initialization ####
###############################################################################

## ****************************************************************************
## Execute any "init" commands passed to the GeneFlow CLI
CMD="${EXEC_INIT}"
echo "CMD=${CMD}"
safeRunCommand "${CMD}"
## ****************************************************************************



###############################################################################
#### Auto-Detect Execution Method ####
###############################################################################

# assign to new variable in order to auto-detect after Agave
# substitution of EXEC_METHOD
AUTO_EXEC=${EXEC_METHOD}
## ****************************************************************************
## Add app-specific paths to detect the execution method.
if [ "${EXEC_METHOD}" = "auto" ]; then
    # detect execution method
    if command -v docker >/dev/null 2>&1; then
        AUTO_EXEC=docker
    else
        echo "Valid execution method not detected"
        echo
        usage
        exit 1
    fi
    echo "Detected Execution Method: ${AUTO_EXEC}"
fi
## ****************************************************************************



###############################################################################
#### App Execution Preparation, Common to all Exec Methods ####
###############################################################################

## ****************************************************************************
## Add logic to prepare environment for execution
MNT=""; ARG=""; CMD0="mkdir -p ${OUTPUT_FULL} ${ARG}"; CMD="${CMD0}"; echo "CMD=${CMD}"; safeRunCommand "${CMD}"; 
MNT=""; ARG=""; CMD0="mkdir -p ${LOG_FULL} ${ARG}"; CMD="${CMD0}"; echo "CMD=${CMD}"; safeRunCommand "${CMD}"; 
## ****************************************************************************



###############################################################################
#### App Execution, Specific to each Exec Method ####
###############################################################################

## ****************************************************************************
## Add logic to execute app
## There should be one case statement for each item in $exec_methods
case "${AUTO_EXEC}" in
    docker)
        MNT=""; ARG=""; fnrun0() { echo "stringtie" | sed 's/>/\\>/g' | sed 's/</\\</g' | sed 's/|/\\|/g'; }; RUN_FULL='stringtie'; eval "RUN_LIST=($(fnrun0))"; RUN=${RUN_LIST[0]}; for (( ri=1; ri<${#RUN_LIST[@]}; ri++ )); do if [ "${RUN_LIST[$ri]:0:1}" = "^" ]; then RARG="${RUN_LIST[$ri]#?}"; RARG_FULL=$(readlink -f "${RARG}"); RARG_DIR=$(dirname "${RARG}"); RARG_BASE=$(basename "${RARG}"); MNT="${MNT} -v "; MNT="${MNT}\"${RARG_DIR}:/data${ri}_r\""; ARG="${ARG} \"/data${ri}_r/${RARG_BASE}\""; else ARG="${ARG} ${RUN_LIST[$ri]}"; fi; done; ARG="${ARG} -G"; MNT="${MNT} -v "; MNT="${MNT}\"${GTF_DIR}:/data1\""; ARG="${ARG} \"/data1/${GTF_BASE}\""; ARG="${ARG} --rf"; ARG="${ARG} -e"; ARG="${ARG} -B"; ARG="${ARG} -o"; MNT="${MNT} -v "; MNT="${MNT}\"${OUTPUT_DIR}:/data5\""; ARG="${ARG} \"/data5/${OUTPUT_BASE}/${OUTPUT_BASE}_final_transcript.gtf\""; ARG="${ARG} -A"; MNT="${MNT} -v "; MNT="${MNT}\"${OUTPUT_DIR}:/data6\""; ARG="${ARG} \"/data6/${OUTPUT_BASE}/${OUTPUT_BASE}.tsv\""; ARG="${ARG} -C"; MNT="${MNT} -v "; MNT="${MNT}\"${OUTPUT_DIR}:/data7\""; ARG="${ARG} \"/data7/${OUTPUT_BASE}/${OUTPUT_BASE}_final_reference.gtf\""; MNT="${MNT} -v "; MNT="${MNT}\"${BAM_DIR}:/data8\""; ARG="${ARG} \"/data8/${BAM_BASE}\""; CMD0="docker run --rm ${MNT} quay.io/biocontainers/stringtie:2.1.6--h978d192_0 ${RUN} ${ARG}"; CMD0="${CMD0} >\"${LOG_FULL}/${OUTPUT_BASE}-stringtie.stdout\""; CMD0="${CMD0} 2>\"${LOG_FULL}/${OUTPUT_BASE}-stringtie.stderr\""; CMD="${CMD0}"; echo "CMD=${CMD}"; safeRunCommand "${CMD}"; 
        ;;
esac
## ****************************************************************************



###############################################################################
#### Cleanup, Common to All Exec Methods ####
###############################################################################

## ****************************************************************************
## Add logic to cleanup execution artifacts, if necessary
## ****************************************************************************

