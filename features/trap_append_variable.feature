Feature: Handling TRAP_APPEND usage
    In order to add command to trap
    Customers should be able to specify if they want append the command
    to the signal list or to erase the list before adding the command

    Scenario: mimic the trap built-in command
        When I run the following script:
            """
            #!/usr/bin/env bash

            source __LIB_DIR__/trap.sh

            trap 'echo "not shown"' EXIT
            trap 'echo "only second trap call should be printed"' EXIT
            """
        Then stdout should be:
            """
            only second trap call should be printed
            """
        And script exit status should be 0

    Scenario: using TRAP_APPEND globally
        Users can put TRAP_APPEND=true in front of the "source trap.sh"
        file and this will impact every call to the trap function

        When I run the following script:
            """
            #!/usr/bin/env bash
            TRAP_APPEND=true source __LIB_DIR__/trap.sh

            trap 'echo "both first"' EXIT
            trap 'echo "and second trap call should be printed"' EXIT

            """
        Then stdout should be:
            """
            both first
            and second trap call should be printed
            """
        And script exit status should be 0

    Scenario: using TRAP_APPEND on a single trap call
        Users can put TRAP_APPEND=true in front of a trap function call
        to only impact this call

        When I run the following script:
            """
            #!/usr/bin/env bash
            source __LIB_DIR__/trap.sh

            trap 'echo "both first"' EXIT
            TRAP_APPEND=true trap 'echo "and second trap call should be printed"' EXIT

            trap 'echo "I will be overwritten"' SIGINT
            trap 'echo "I replace every previous call"' SIGINT

            echo "\
            >>> trap -p SIGINT"
            command trap -p SIGINT
            echo "<<< trap -p SIGINT"
            """
        Then stdout should be:
            """
            >>> trap -p SIGINT
            trap -- '
            declare exit_status=$?
            # your code is within this block

            ( echo "I replace every previous call" ) || exit_status=$?

            # your code is within this block
            ( exit ${exit_status} )
            ' SIGINT
            <<< trap -p SIGINT
            both first
            and second trap call should be printed
            """
        And script exit status should be 0
