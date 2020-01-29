#!/usr/bin/env bash
#
# Enhance the trap bash built-in command by providing pause/restore and ability
# to add code on top of existing ones.

if [[ "${BASH_VERSINFO[0]}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]}" -lt 3 ]] \
    || [[ "${BASH_VERSINFO[0]}" -lt 4 ]]
then
    >&2 echo "trap lib only works with bash version 4.3+"
    false

    exit
fi

# do not import this lib twice
[[ "$(type -t "trap")" =~ ^function$ ]] && return

#############################################################################
# If set to true, the default behavior of the trap function will be to append
# command to the list of commands for a given signal
# This is set to false by default to mimic trap built-in behavior.
#
# Best usage:
# TRAP_APPEND=true source trap.sh
#############################################################################
declare -g TRAP_APPEND=${TRAP_APPEND:-false}

#############################################################
# Control whether paused trap signal should be editable or not
# If set to true, paused signal being edited will be restored
#
# Usage:
# ```
# TRAP_EDIT_PAUSED=true trap 'echo my code' SIGINT
# ```
# or, globally:
# ```
# TRAP_EDIT_PAUSED=true
# trap 'echo my code' SIGINT
# ...
#############################################################
declare -g TRAP_EDIT_PAUSED=${TRAP_EDIT_PAUSED:-false}

#
#
# PUBLIC functions
#
#

################################################################################
# trap [-lp] [[arg] sigspec ...]
#
# Override trap built-in command.
# Basic behavior remains the same.
#
# Globals:
#    TRAP_APPEND      If true, append arg to sigspec.
#                     If false, replace previous commands by the one provided.
#                     Default: false (mimic trap behavior)
#    TRAP_EDIT_PAUSED If true, allows editing paused signal.
#                     See trap::signal::pause.
# Arguments:
#    see `man -P $'less -p "\s+trap \["' bash` (this goes directly to the right
#    position)
# Returns:
#    0  if OK
#    1  in case of error
#    2  if the underlying trap built-in command is misused
################################################################################
function trap
{
    # let trap built-in command handle every display options
    if [[ $# -eq 0 ]] || [[ "$1" == "-p" ]] || [[ "$1" == "-l" ]]
    then
        command trap "$@"
        return
    fi

    declare -i exit_status=0
    declare    command="-"

    # skip trap -- ...
    [[ "$1" == "--" ]] && shift

    if [[ $# -gt 1 ]]
    then
        command="$1"
        shift
    fi
    readonly command

    if [[ "${command}" == "-" ]] || [[ "${command}" == '\0' ]]
    then
        trap::signal::clear "$@"

        return
    fi

    trap::_ensure_boolean "TRAP_APPEND" || return

    if ! ${TRAP_APPEND}
    then
        trap::signal::clear "$@" || exit_status=$?
    fi

    trap::append "${command}" "$@" || exit_status=$?

    return "${exit_status}"
}

################################################################################
# Add command 'arg' to be executed when the shell receives signals.
# This differs from the trap command as it will keep existing code.
# Prevent command from failing to allow other commands to be executed.
#
# Globals:
#    TRAP_EDIT_PAUSED
# Arguments:
#    arg     Command to be executed when the shell receives signal(s) sigspec
#    sigspec Signal that will trigger 'arg' if the shell receives it.
#    [...]   More sigspec that will trigger 'arg' if the shell receives it.
# Returns:
#    0  if OK
#    1  if any sigspec is invalid or a trapped signal has been paused and
#       TRAP_EDIT_PAUSED is set to false
#    2  if the underlying trap built-in command is misused
################################################################################
function trap::append
{
    trap::_append_check_args "$@" || return

    declare -r code="$1"
    shift

    # space is important because command can already be surrounded with
    # parenthesis and "((" has different meaning than "( (" in bash
    trap::append_raw "( ${code} ) || exit_status=\$?" "$@"
}

################################################################################
# Same as trap::append but if command 'arg' fails and script is run with the
#  "set -e" option, commands added after this one will not be run.
#
# Globals:
#    TRAP_EDIT_PAUSED
# Arguments:
#    arg     Command to be executed when the shell receives signal(s) sigspec
#    sigspec Signal that will trigger 'arg' if the shell receives it.
#    [...]   More sigspec that will trigger 'arg' if the shell receives it.
# Returns:
#    0  if OK
#    1  if any sigspec is invalid or a trapped signal has been paused and
#       TRAP_EDIT_PAUSED is set to false
#    2  if the underlying trap built-in command is misused
################################################################################
function trap::append_raw
{
    trap::_append_check_args "$@" || return

    declare -r command="$1"
    shift

    declare -i exit_status=0
    declare -i command_id=-1

    trap::_ensure_boolean "TRAP_EDIT_PAUSED" || return

    trap::_init

    for signal_name in "$@"
    do
        trap::signal::_clean_name "signal_name" || {
            exit_status=$?
            continue
        }

        if ! ${TRAP_EDIT_PAUSED} && trap::signal::_is_paused "${signal_name}"
        then
            trap::_error "${signal_name}: signal is paused" || exit_status=$?
            continue
        fi

        if [[ "${command_id}" -eq -1 ]]
        then
            (( __trap__command_counter++ ))
            command_id="${__trap__command_counter}"
            __trap__command_list["${command_id}"]="${command}"
        fi

        if ! [[ -v __trap__signal_command_id_list["${signal_name}"] ]]
        then
            __trap__signal_command_id_list["${signal_name}"]="|"
        fi
        __trap__signal_command_id_list["${signal_name}"]="${__trap__signal_command_id_list["${signal_name}"]}${command_id}|"
        trap::signal::_flush "${signal_name}" || exit_status=$?
    done

    return "${exit_status}"
}

################################################################################
# Get unique identifier of the last command.
# When using trap, trap::append or trap::apprend_raw functions, added command is
# assigned a unique identifier. This id may be used to remove the command from
# every signals.
#
# Globals:
#    None
# Arguments:
#    [reference] if used, unique identifier will be assigned to the variable.
#                output otherwise.
#                ```
#                declare command_id
#                trap::command::last_inserted_id "command_id"
#                ```
# Returns:
#    None
################################################################################
function trap::command::last_inserted_id
{
    if [[ $# -eq 1 ]]
    then
        declare -n _reference="$1"
        _reference="${__trap__command_counter}"
        return
    fi

    echo -n "${__trap__command_counter}"
}

################################################################################
# Search for a command unique identifier in every trap signals and removes it.
#
# Globals:
#    None
# Arguments:
#    command_id    unique identifier provided by trap::command::last_inserted_id
#    [sigspec...]  limit the search for those signals.
# Returns:
#    None
################################################################################
function trap::command::remove_by_id
{
    declare command_id="$1"
    shift

    declare -a signals=("$@")

    if [[ $# -eq 0 ]]
    then
        signals=("${!__trap__signal_command_id_list[@]}")
    fi

    for signal_name in "${signals[@]}"
    do
        trap::signal::_clean_name "signal_name" || {
            exit_status=$?
            continue
        }

        declare before="${__trap__signal_command_id_list[${signal_name}]}"
        __trap__signal_command_id_list[${signal_name}]="${__trap__signal_command_id_list[${signal_name}]/|${command_id}/}"
        declare after="${__trap__signal_command_id_list[${signal_name}]}"

        if [[ "${before}" == "${after}" ]]
        then
            continue
        fi

        if [[ "${__trap__signal_command_id_list[${signal_name}]}" == "|" ]]
        then
            unset __trap__signal_command_id_list["${signal_name}"]
        fi
        trap::signal::_flush "${signal_name}"
    done
}

################################################################################
# Display trap content without all the glue generated by this lib.
#
# Globals:
#    None
# Arguments:
#    [sigspec ...] Signal to display. If none provided, every signal will be
#                  displayed.
# Returns:
# Returns:
#    0  if OK
#    1  if any sigspec is invalid
################################################################################
function trap::debug
{
    trap::_init

    declare -a signals=("$@")

    declare -i exit_status=0

    if [[ $# -eq 0 ]]
    then
        signals=("${!__trap__signal_command_id_list[@]}")
    fi

    for signal_name in "${signals[@]}"
    do
        trap::signal::_clean_name "signal_name" || {
            exit_status=$?
            continue
        }

        declare _signal
        printf -v "_signal" "%-12s" "${signal_name}"

        declare -a command_id_list=()

        IFS='|' read -ra command_id_list <<<"${__trap__signal_command_id_list[${signal_name}]}"

        for command_id_key in "${!command_id_list[@]}"
        do
            declare command_id="${command_id_list[${command_id_key}]}"
            [[ -z "${command_id}" ]] && continue

            echo "${__trap__command_list["${command_id}"]}" \
                | sed -E "s/^/${_signal}: /g"
        done
    done

    return "${exit_status}"
}

################################################################################
# Display full trap content, including glue code generated by this lib.
#
# Globals:
#    None
# Arguments:
#    [sigspec ...] Signal to display. If none provided, every signal will be
#                  displayed.
# Returns:
#    None
################################################################################
function trap::debug_raw
{
    trap::_init

    declare -a signals=("$@")

    declare -i exit_status=0

    if [[ $# -eq 0 ]]
    then
        signals=("${!__trap__signal_command_id_list[@]}")
    fi

    for signal_name in "${signals[@]}"
    do
        trap::signal::_clean_name "signal_name" || {
            exit_status=$?
            continue
        }

        declare _signal
        printf -v "_signal" "%-12s" "${signal_name}"

        command trap -p "${signal_name}" | sed -E "s/^/${_signal}: /g"
    done

    return "${exit_status}"
}


################################################################################
# Clear one or more signals
#
# Globals:
#    TRAP_EDIT_PAUSED
# Arguments:
#    [sigspec ...] Signal to clear. If none provided, every signal will be
#                  cleared.
# Returns:
#    None
################################################################################
function trap::signal::clear
{
    declare -a signals=("$@")

    declare -i exit_status=0

    trap::_ensure_boolean "TRAP_EDIT_PAUSED" || return

    trap::_init

    if [[ $# -eq 0 ]]
    then
        signals=("${!__trap__signal_command_id_list[@]}")
    fi

    for signal_name in "${signals[@]}"
    do
        trap::signal::_clean_name "signal_name" || {
            exit_status=$?
            continue
        }

        if ! ${TRAP_EDIT_PAUSED} && trap::signal::_is_paused "${signal_name}"
        then
            trap::_error "${signal_name}: signal is paused" || exit_status=$?
            continue
        fi

        unset __trap__signal_command_id_list["${signal_name}"]
        trap::signal::_flush "${signal_name}" || exit_status=$?
    done

    return "${exit_status}"
}

################################################################################
# Temporarily reset signal(s) 'sigspec'. If sigspec is absent, every signals
# will be paused.
#
# Every registered commands will not be executed if signal sigspec occurs.
# Use `trap::signal::restore` to restore previously defined commands
#
# Paused signal will not be editable during the period unless you set
# TRAP_EDIT_PAUSED to true.
# `trap::signal::pause SIGINT; trap 'echo "try me"' SIGINT` will fail
# `trap::signal::pause SIGINT; TRAP_EDIT_PAUSED=true trap 'echo "try me"' SIGINT`
# won't.
#
# If you edit a paused signal, it will automatically be restored.
#
# Globals:
#    None
# Arguments:
#    [sigspec ...] Signal(s) to reset to its original disposition (the value it
#                  had upon entrance to the shell)
# Returns:
#    0  if OK
#    1  if any sigspec is invalid
################################################################################
function trap::signal::pause
{
    trap::_init

    declare -a signals=("$@")

    declare -i exit_status=0

    if [[ $# -eq 0 ]]
    then
        signals=("${!__trap__signal_command_id_list[@]}")
    fi

    for signal in "${signals[@]}"
    do
        trap::signal::_clean_name "signal" || {
            exit_status=$?
            continue
        }

        __trap__paused_signal[${signal}]="${signal}"
        command trap - "${signal}" || {
            exit_status=$?
            continue
        }
    done

    return "${exit_status}"
}

################################################################################
# Restore paused signal(s) 'sigspec'. If sigspec is absent, every paused signals
# will be restored.
#
# Globals:
#    None
# Arguments:
#    [sigspec ...] Signal(s) to restore
# Returns:
#    0  if OK
#    1  if any sigspec is invalid or not paused
################################################################################
function trap::signal::restore
{
    trap::_init

    declare -a signals=("$@")

    declare -i exit_status=0
    declare    signal

    if [[ $# -eq 0 ]]
    then
        signals=("${__trap__paused_signal[@]}")
    fi

    for signal in "${signals[@]}"
    do
        trap::signal::_clean_name "signal" || {
            exit_status=$?
            continue
        }

        if ! trap::signal::_is_paused "${signal}"
        then
            trap::_error "${signal}: signal was not paused" || exit_status=$?
            continue
        fi

        trap::signal::_flush "${signal}" || exit_status=$?
    done

    return "${exit_status}"
}

#
#
# INTERNAL FUNCTIONS. not supposed to be called outside of this file
#
#


################################################################################
# Uniquely identify sigspec. According to trap man page, a signal may be defined
# in multiple ways: with a number, with or without the SIG prefix.
# This function will translate numbers and non SIG-prefixed sigspec to the right
# signal name.
#
# Globals:
#    None
# Arguments:
#    sigspec  value to be translated to the right signal name
# Returns:
#    0  if OK
#    1  if sigspec is invalid
################################################################################
function trap::signal::_clean_name
{
    declare -n _reference="$1"

    declare -r raw_value="${_reference}"
    declare    sanitized_value

    # dealing with signal number
    sanitized_value="__${raw_value}"
    if [[ -v "__trap__signal_list[${sanitized_value}]" ]]
    then
        _reference="${__trap__signal_list[${sanitized_value}]}"

        return
    fi

    # dealing with the right signal name (case shouldn't matter)
    sanitized_value="$(tr '[:lower:]' '[:upper:]' <<<"${raw_value}")"
    if [[ -v "__trap__signal_list[${sanitized_value}]" ]]
    then
        _reference="${sanitized_value}"

        return
    fi

    # dealing with signal name without the SIG prefix
    sanitized_value="SIG${sanitized_value}"
    if [[ -v "__trap__signal_list[${sanitized_value}]" ]]
    then
         # shellcheck disable=SC2034
        _reference="${sanitized_value}"

        return
    fi

    # signal does not exists
    trap::_error "${raw_value}: invalid signal specification"
}

function trap::signal::_flush
{
    if [[ $# -eq 0 ]]
    then
        if [[ "${#__trap__signal_command_id_list[@]}" -gt 0 ]]
        then
            trap::signal::_flush "${!__trap__signal_command_id_list[@]}"
        fi

        return
    fi

    if [[ $# -gt 1 ]]
    then
        declare exit_status=0

        while [[ $# -gt 0 ]]
        do
            declare signal_name="$1"
            shift

            trap::signal::_flush "${signal_name}" || exit_status=$?
        done

        return "${exit_status}"
    fi

    declare signal_name="$1"

    # signal is supposed to be already sanitized. Don't do the work twice.
    # trap::signal::_clean_name "signal" || return

    # since we modify the trap signal, it can no longer be paused
    unset __trap__paused_signal["${signal_name}"]

    # trap only contains this lib skeleton
    if ! [[ -v "__trap__signal_command_id_list[${signal_name}]" ]]
    then
        # remove trap signal
        command trap - "${signal_name}"

        return
    fi

    declare substring="${__TRAP__TEMPLATE_PLACEHOLDER}"
    declare replacement=""

    declare -a command_id_list=()
    IFS='|' read -ra command_id_list <<<"${__trap__signal_command_id_list[${signal_name}]}"
    for command_id_key in "${!command_id_list[@]}"
    do
        declare command_id="${command_id_list[${command_id_key}]}"
        [[ -z "${command_id}" ]] && continue

        replacement="${replacement}
${__trap__command_list["${command_id}"]}"
    done

    declare body="${__TRAP__TEMPLATE/${substring}/${replacement}}"

    command trap -- "${body}" "${signal_name}"
}

function trap::signal::_init_dictionary
{
    __trap__signal_list=(
        ["__0"]=EXIT
        ["EXIT"]=0
        ["ERR"]=ERR
    )

    while read -r number name
    do
        [[ -z "${number}" ]] && continue

        # number is "XX)"
        number="${number:0:-1}"
        __trap__signal_list["${name}"]=${number}
        __trap__signal_list["__${number}"]=${name}
    done < <(command trap -l | tr '\t' '\n')
}

function trap::signal::_is_paused
{
    declare -r signal_name="$1"

    [[ -v "__trap__paused_signal[${signal_name}]" ]]
}

function trap::signal::_sync
{
    declare current_signal=""
    declare body=""

    # reset the definition list
    __trap__signal_command_id_list=()

    while read -r line
    do
        [[ -z "${line}" ]] && continue
        if [[ -z "${current_signal}" ]]
        then
            current_signal="${line}"
            continue
        fi
        if [[ "${line}" == "${current_signal}" ]]
        then
            if [[ -z "${body}" ]]
            then
                continue
            fi
            (( __trap__command_counter++ ))
            __trap__command_list["${__trap__command_counter}"]="${body}"
            __trap__signal_command_id_list["${current_signal}"]="|${__trap__command_counter}|"

            current_signal=""
            body=""
            continue
        fi
        if [[ -z "${body}" ]]
        then
            body="${line}"
        else
            body="${body}
${line}"
        fi
    done <<<"$(
        command trap \
        | sed -E -e $'s/^trap -- \'/#> signal\\n/g' \
                 -e $'s/[[:space:]]*\' ([^\']+)$/\\n\\1\\n/g' \
        | awk 'BEGIN { RS="#> signal" } { print $NF,$0 }'
        )"
}

function trap::_append_check_args
{
    case $# in
        0)
            >&2 echo "${FUNCNAME[1]}: missing arg argument
Usage:
    ${FUNCNAME[1]} arg sigspec [sigspec...]"
            false

            return
        ;;
        1)
            >&2 echo "${FUNCNAME[1]}: missing signal argument
Usage:
    ${FUNCNAME[1]} arg sigspec [sigspec...]"
            false

            return
        ;;
        *)
            if [[ -z "$1" ]]
            then
                >&2 echo "${FUNCNAME[1]}: arg is empty
Use the trap function if you want to clear a signal trap
Usage:
    ${FUNCNAME[1]} arg sigspec [sigspec...]"
                false

                return
            fi
        ;;
    esac
}

function trap::_ensure_boolean
{
    declare    -r variable_name="$1"
    declare -n -r variable_value="$1"

    if ! [[ "${variable_value}" =~ (true|false) ]]
    then
        trap::_error "${variable_name} must be set to either true or false. \
Given: '${variable_value}'"
    fi
}

function trap::_error
{
    declare -r message="$1"

    declare -r    lib_prefix="trap::"
    declare -r -i lib_prefix_length="${#lib_prefix}"

    declare caller_filename="${BASH_SOURCE[0]}"
    declare caller_line="${BASH_LINENO[0]}"
    declare function_name="${FUNCNAME[0]}"

    # goal: show the line of developer's own code that fails, not the internal
    # recipe
    for history_line in "${!BASH_SOURCE[@]}"
    do
        caller_filename="${BASH_SOURCE[${history_line}]}"

        # case the lib lives in its own file
        [[ "${caller_filename}" != "${BASH_SOURCE[0]}" ]] && break

        declare _function_name="${FUNCNAME[${history_line}]}"

        # case the lib is copy/pasted or error happened during source
        # meaning _function_name is not a lib function
        if [[ "${_function_name:0:${lib_prefix_length}}" != "${lib_prefix}" ]] \
            && [[ "${_function_name}" != "trap" ]]
        then
            break
        fi

        function_name="${_function_name}"
        caller_line="${BASH_LINENO[${history_line}]}"
    done

    >&2 echo \
"${caller_filename}: line ${caller_line}: ${function_name}: ${message}"

    false
}

function trap::_init
{
    ${__trap__is_initialized} && return

    trap::signal::_init_dictionary
    trap::signal::_sync
    # rewrite trap signals to include our wrapper
    trap::signal::_flush

    __trap__is_initialized=true
}

#
#
# INTERNAL global variables. not supposed to be used outside of this file
#
#

# signals from system ([number|name|sig_name] => sanitized_name)
declare -g -A __trap__signal_list=()
# [signal_name] => list of command id (1|3|9)
declare -g -A __trap__signal_command_id_list=()
# list of known commands used by signals
declare -g -a __trap__command_list=()
# number of commands handled by signal. Used to uniquely identify a command
declare -g -i __trap__command_counter=-1

declare -g -A __trap__paused_signal=()
declare -g    __trap__is_initialized=false
declare -g -r __TRAP__TEMPLATE_WRAPPER='# your code is within this block'
declare -g -r __TRAP__TEMPLATE_PLACEHOLDER='
placeholder for body
'
declare -g -r __TRAP__TEMPLATE="
declare exit_status=\$?
${__TRAP__TEMPLATE_WRAPPER}
${__TRAP__TEMPLATE_PLACEHOLDER}

${__TRAP__TEMPLATE_WRAPPER}
( exit \${exit_status} )
"

trap::_ensure_boolean "TRAP_APPEND" || exit
trap::_ensure_boolean "TRAP_EDIT_PAUSED" || exit
