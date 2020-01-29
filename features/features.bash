#! /usr/bin/env bash

# usage: ./features.bash [feature-file-or-dir ...]
declare    -g WORKSPACE
declare    -g LIB_DIR
declare    -g FEATURES_ROOT_DIR
declare -a -g features_dirs=()
declare -a -g features_files=()

LIB_DIR="$(realpath "$( dirname "${BASH_SOURCE[0]}" )"/..)"
FEATURES_ROOT_DIR="$(realpath "$( dirname "${BASH_SOURCE[0]}" )")"

readonly LIB_DIR FEATURES_ROOT_DIR

function test_features
{
    WORKSPACE="$(mktemp -d --tmpdir -- test_features.XXXXXXXXXX)"

    declare run_all=true

    if [[ "${#features_dirs[@]}" -gt 0 ]]
    then
        run_all=false
        run_feature_dirs "${features_dirs[@]}"
    fi

    if [[ "${#features_files[@]}" -gt 0 ]]
    then
        run_all=false
        run_feature_files "${features_files[@]}"
    fi

    if ${run_all}
    then
        run_all
    fi

    # unfortunately shunit2 delete trap EXIT
    rm -r "${WORKSPACE}"
}

function run_all
{
    while IFS=$'\n' read -r dir
    do
        [[ -d "${FEATURES_ROOT_DIR}/${dir}" ]] && run_feature_dir "${dir}"
        [[ -f "${FEATURES_ROOT_DIR}/${dir}" ]] && run_feature_files "${dir}"
    done < <(cd "${FEATURES_ROOT_DIR}" && ls -1)
}

function run_feature_dirs
{
    for dir in "$@"
    do
        run_feature_dir "${dir}"
    done
}

function run_feature_dir
{
    declare dir="$1"

    while IFS=$'\n' read -r file
    do
        [[ -f "${FEATURES_ROOT_DIR}/${dir}/${file}" ]] && run_feature_file "${dir}/${file}"
    done < <(cd "${FEATURES_ROOT_DIR}/${dir}" && ls -1)
}

function run_feature_files
{
    for file in "$@"
    do
        run_feature_file "${file}"
    done
}

function run_feature_file
{
    # path relative to FEATURES_ROOT_DIR
    declare feature_file="$1"

    declare feature_workspace="${WORKSPACE}/${feature_file//\//__}"
    mkdir "${feature_workspace}"

    extract_feature "${FEATURES_ROOT_DIR}/${feature_file}" "${feature_workspace}"

    if ! [[ -f "${feature_workspace}/feature.txt" ]]
    then
        assertTrue "File '${feature_file}' does not contain any feature" true
        return
    fi

    cat "${feature_workspace}/feature.txt"

    while IFS=$'\n' read -r scenario_file
    do
        if [[ "${scenario_file}" =~ scenario-[0-9]+.txt$ ]]
        then
            run_scenario "${scenario_file}"
        fi
    done < <(ls -1 "${feature_workspace}"/scenario-*.txt)
}

function extract_feature
{
    declare feature_file="$1"
    declare output_dir="$2"

    awk -v dir="${output_dir}" -v lib_dir="${LIB_DIR}" '
function ltrim(s) { sub(/^[ \t\r\n]+/, "", s); return s }
function starts_with(text) { return $0 ~ "^[ \t\r\n]*"text; }

BEGIN       { scenario_number=0; file="" }

starts_with("Feature:")  {
                step="feature"
                file=dir"/feature.txt"
                print ltrim($0) >file
                next
            }

starts_with("Scenario:") {
                step="scenario"
                scenario_number++
                file=dir"/scenario-"scenario_number".txt"
                scenario_step_file=dir"/scenario-"scenario_number"-steps.txt"
                print >file
                next
            }
# Given is not handled
starts_with("Given") { step="scenario-when"; next }
starts_with("When")  { step="scenario-when" }
starts_with("Then")  { step="scenario-then" }

step ~ /^scenario-/ { print > scenario_step_file }

# feature multiline description (keep tabs)
step == "feature"   { print>file;next }

# Scenario multiline description (keep tabs)
step == "scenario"  { print>file;next }

step == "scenario-when" && /I run the following script\:/  {
            file=dir"/scenario-"scenario_number".bash"
            next
        }

# Line starts with Then
step=="scenario-then" && /stdout should be:/ {
            file=dir"/scenario-"scenario_number".expected.stdout"
            next
        }

step=="scenario-then" && /stdout should be empty/ {
            file=dir"/scenario-"scenario_number".expected.stdout.empty"
            print "">file
            next
        }

step=="scenario-then" && /stderr should be:/ {
            file=dir"/scenario-"scenario_number".expected.stderr"
            next
        }

step=="scenario-then" && /stderr should be empty/ {
            file=dir"/scenario-"scenario_number".expected.stderr.empty"
            print "">file
            next
        }

step=="scenario-then" && /script exit status should be [0-9]+/ && match($0,/[0-9]+/) {
            file=dir"/scenario-"scenario_number".expected.exit_status"
            print substr($0, RSTART, RLENGTH)>file;
            next
        }

file == "" { next }

# skip PyStrings
/"""/  { next }

# other Given When Then or And should not be printed (need to be matched before this line)
/^[ \t\r\n]*(Given|When|Then|And)/ { next }

# replace this pattern with the actual lib directory
/__LIB_DIR__/ { sub(/__LIB_DIR__/,lib_dir) }

# output everything to previously defined file
       { print ltrim($0) >file }
' "${feature_file}"

}

function run_scenario
{
    declare scenario_file="$1"

    cat "${scenario_file}"

    declare basename="${scenario_file%.txt}"
    declare scenario_step_file="${basename}-steps.txt"
    # shellcheck disable=SC2034
    declare scenario_step_file_shown=false
    declare exit_status=0

    if ! [[ -f "${basename}.bash" ]]
    then
        assertTrue "No bash script found for scenario" "false"
        return
    fi

    bash "${basename}.bash" >"${basename}.result.stdout" 2>"${basename}.result.stderr" || exit_status=$?

    if [[ -f "${basename}.expected.exit_status" ]]
    then
        wrap_assert "${scenario_step_file}" "scenario_step_file_shown" \
            assertEquals "exit status should be equal" "$(cat "${basename}.expected.exit_status")" "${exit_status}"
    fi

    if [[ -f "${basename}.expected.stdout.empty" ]]
    then
        if [[ -f "${basename}.result.stdout" ]] && [[ "$(wc -l < "${basename}.result.stdout")" -gt 0 ]]
        then
            declare message
            message="Stdout should be empty but contain
\`\`\`
$(cat "${basename}.result.stdout")
\`\`\`"
            wrap_assert "${scenario_step_file}" "scenario_step_file_shown" \
                assertTrue "${message}" "false"
        fi
    elif ! diff -q --new-file "${basename}.expected.stdout" "${basename}.result.stdout" &>/dev/null
    then
        declare message
        message="stdout differs. Result of 'diff expected result':
\`\`\`
$(diff --new-file "${basename}.expected.stdout" "${basename}.result.stdout")
\`\`\`"
        wrap_assert "${scenario_step_file}" "scenario_step_file_shown" \
            assertTrue "${message}" false
        unset message
    fi

    if [[ -f "${basename}.expected.stderr.empty" ]]
    then
        if [[ -f "${basename}.result.stderr" ]] && [[ "$(wc -l < "${basename}.result.stderr")" -gt 0 ]]
        then
            declare message
            message="stderr should be empty but contain
\`\`\`
$(cat "${basename}.result.stderr")
\`\`\`"
            wrap_assert "${scenario_step_file}" "scenario_step_file_shown" \
                assertTrue "${message}" "false"
        fi
    elif ! diff -q --new-file "${basename}.expected.stderr" "${basename}.result.stderr" &>/dev/null
    then
        declare message
        message="stderr differs. Result of 'diff expected result':
\`\`\`
$(diff --new-file "${basename}.expected.stderr" "${basename}.result.stderr")
\`\`\`"
        wrap_assert "${scenario_step_file}" "scenario_step_file_shown" \
            assertTrue "${message}" false
        unset message
    fi
}

function wrap_assert
{
    declare file="$1"
    declare -n _shown="$2"
    declare assert_command="$3"
    shift 3

    # avoid running twice if file as already been displayed
    if ${_shown}
    then
        ${assert_command} "$@"

        return
    fi

    if ! ${assert_command} "$@" >/dev/null
    then
        if ! "${_shown}"
        then
            _shown=true
            cat "${file}"
        fi
        ${assert_command} "$@"
        __shunit_assertsFailed=$((__shunit_assertsFailed - 1))
        __shunit_assertsTotal=$((__shunit_assertsTotal - 1))
    fi
}

if [[ "${#BASH_SOURCE[@]}" -eq 1 ]]
then

    while [[ $# -gt 0 ]]
    do
        declare arg="$1"
        shift

        if [[ -d "${FEATURES_ROOT_DIR}/${arg}" ]]
        then
            features_dirs+=("${arg}")
            continue
        fi

        if [[ -f "${FEATURES_ROOT_DIR}/${arg}" ]]
        then
            features_files+=("${arg}")
            continue
        fi

        >&2 echo "'${arg}': directory or file not found in '${FEATURES_ROOT_DIR}'"
        exit 1
    done
    # shellcheck source=../bin/shunit2.sh
    source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../bin/shunit2.sh")"
fi
